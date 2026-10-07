require_relative 'spec_helper'
require 'cgi'
require 'uri'

RSpec.describe Workspaces::Cli do
  def capture_streams
    original_stdout = $stdout
    original_stderr = $stderr
    stdout = StringIO.new
    stderr = StringIO.new
    $stdout = stdout
    $stderr = stderr
    yield
    [stdout.string, stderr.string]
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end

  it 'does not load Rails Puma configuration for the workspace front door' do
    Dir.mktmpdir do |directory|
      FileUtils.mkdir_p(File.join(directory, 'config'))
      File.write(File.join(directory, 'config/puma.rb'), "raise 'must not load Rails config'\n")
      allow(Rackup::Handler::Puma).to receive(:run) do |app, **options|
        configuration = Rackup::Handler::Puma.config(app, options)
        configuration.load
        expect(configuration.config_files).to eq([])
        configuration.clamp
        expect(configuration.options[:workers]).to eq(0)
      end
      Dir.chdir(directory) { expect(described_class.run(['serve'])).to eq(0) }
    end
  end

  it 'keeps the default HTTP listener even when the public origin is HTTPS' do
      ClimateControl.modify('WORKSPACES_PUBLIC_ORIGIN' => 'https://previews.example.test',
                            'WORKSPACES_BASE_DOMAIN' => 'example.test') do
      allow(Rackup::Handler::Puma).to receive(:run) do |_, **options|
        expect(options[:Host]).to eq('127.0.0.1')
        expect(options[:Port]).to eq(4747)
        expect(options[:config_files]).to eq(['-'])
        expect(options[:workers]).to eq(0)
      end

      expect(described_class.run(['serve'])).to eq(0)
    end
  end

  it 'uses an SSL bind when serve receives an explicit TLS cert/key pair' do
    Dir.mktmpdir do |directory|
      cert_path, key_path = write_tls_pair(directory)

      ClimateControl.modify('WORKSPACES_PUBLIC_ORIGIN' => nil, 'WORKSPACES_BASE_DOMAIN' => nil) do
        allow(Rackup::Handler::Puma).to receive(:run) do |_, **options|
          uri = URI.parse(options[:Host])
          query = CGI.parse(uri.query)

          expect(options[:Host]).to start_with('ssl://127.0.0.1:4747?')
          expect(query).to include('cert' => [cert_path], 'key' => [key_path], 'verify_mode' => ['none'])
          expect(options).not_to have_key(:Port)
        end

        expect(described_class.run(['serve', '--tls-cert', cert_path, '--tls-key', key_path])).to eq(0)
      end
    end
  end

  it 'prints actionable environment exports when --secure applies local defaults' do
    Dir.mktmpdir do |directory|
      certs_dir = File.join(directory, '.workspaces', 'certs')
      FileUtils.mkdir_p(certs_dir)
      cert_path = File.join(certs_dir, 'workspaces.pem')
      key_path = File.join(certs_dir, 'workspaces-key.pem')
      write_tls_pair(certs_dir, cert_path:, key_path:)

      ClimateControl.modify('HOME' => directory, 'WORKSPACES_PUBLIC_ORIGIN' => nil, 'WORKSPACES_BASE_DOMAIN' => nil) do
        allow(Rackup::Handler::Puma).to receive(:run)

        stdout, = capture_streams do
          expect(described_class.run(['serve', '--secure'])).to eq(0)
        end

        expect(stdout).to include('Dashboard: https://workspaces.localhost:4747/workspaces')
        expect(stdout).to include('export WORKSPACES_PUBLIC_ORIGIN=https://workspaces.localhost:4747')
        expect(stdout).to include('export WORKSPACES_BASE_DOMAIN=workspaces.localhost')
      end
    end
  end

  it 'rejects a partial explicit TLS flag pair' do
    _, stderr = capture_streams do
      expect(described_class.run(['serve', '--tls-cert', '/tmp/workspaces.pem'])).to eq(1)
    end

    expect(stderr).to include('--tls-cert and --tls-key must be provided together')
  end

  it 'fails loudly when --secure cannot find the default TLS files' do
    Dir.mktmpdir do |directory|
      ClimateControl.modify('HOME' => directory, 'WORKSPACES_PUBLIC_ORIGIN' => nil, 'WORKSPACES_BASE_DOMAIN' => nil) do
        _, stderr = capture_streams do
          expect(described_class.run(['serve', '--secure'])).to eq(1)
        end

        certificate = File.join(directory, '.workspaces/certs/workspaces.pem')
        expect(stderr).to include("TLS certificate file does not exist: #{certificate}")
      end
    end
  end

  it 'rejects serve-only TLS flags on unrelated commands' do
    _, stderr = capture_streams do
      expect(described_class.run(['list', '--secure'])).to eq(1)
    end

    expect(stderr).to include('invalid option: --secure')
  end

  it 'loads the actual executable and returns JSON without loading Rails' do
    executable = File.expand_path('../../exe/workspaces', __dir__)
    stdout, stderr, status = Open3.capture3('ruby', executable, 'list', '--json')
    expect(status.exitstatus).to eq(0)
    expect(stderr).to eq('')
    expect(JSON.parse(stdout)).to eq([])
  end

  it 'creates with a preset without starting and rejects unknown presets before creating a worktree' do
    repository
    root = Workspaces::Config.repo_root
    config = YAML.safe_load(root.join('.workspaces.yml').read)
    config['default_editable_env'] = { 'APP_VARIANT' => 'www' }
    config['environment_presets'] = { 'Admin' => { 'APP_VARIANT' => 'admin' } }
    root.join('.workspaces.yml').write(YAML.dump(config))

    stdout, = capture_streams do
      expect(described_class.run(['create', '--branch', 'main', '--preset', 'Admin', '--json'])).to eq(0)
    end
    id = JSON.parse(stdout).fetch('id')
    expect(Workspaces::EnvironmentOverrides.new(id).editable_values(config['default_editable_env']))
      .to eq('APP_VARIANT' => 'admin')
    expect(Workspaces::StateStore.new(Workspaces::Config.state_file).get(id)['status']).to eq('idle')
    before = Workspaces::Registry.new.list.length
    _, stderr = capture_streams do
      expect(described_class.run(['create', '--branch', 'main', '--preset', 'Missing'])).to eq(1)
    end
    expect(stderr).to include('Unknown environment preset')
    expect(Workspaces::Registry.new.list.length).to eq(before)
  end

  it 'passes named presets to start, prepare, and restart without changing other options' do
    coordinator = instance_double(Workspaces::Coordinator)
    allow(coordinator).to receive(:start).and_return(true)
    allow(coordinator).to receive(:restart).and_return(true)
    allow(coordinator).to receive(:wait).with('fixture-123').and_return('status' => 'ready')
    cli = described_class.new
    allow(cli).to receive(:coordinator).and_return(coordinator)

    stdout, stderr = capture_streams do
      expect(cli.run(['start', 'fixture-123', '--preset', 'Admin'])).to eq(0)
      expect(cli.run(['prepare', 'fixture-123', '--preset', 'Vendor'])).to eq(0)
      expect(cli.run(['restart', 'fixture-123', '--preset', 'Admin'])).to eq(0)
    end

    expect(stdout).to include('"status": "ready"')
    expect(stderr).to eq('')
    expect(coordinator).to have_received(:start).with('fixture-123', force: false, preset: 'Admin', set: {}, unset: [])
    expect(coordinator).to have_received(:start).with('fixture-123', force: true, preset: 'Vendor', set: {}, unset: [])
    expect(coordinator).to have_received(:restart).with('fixture-123', preset: 'Admin', set: {}, unset: [])
  end

  it 'creates with repeated sets, unsets, and a preset while rejecting invalid input before creation' do
    repository
    root = Workspaces::Config.repo_root
    config = YAML.safe_load(root.join('.workspaces.yml').read)
    config['default_editable_env'] = { 'APP_VARIANT' => 'www', 'APP_CHANNEL' => 'www' }
    config['environment_presets'] = { 'Admin' => { 'APP_VARIANT' => 'admin' } }
    root.join('.workspaces.yml').write(YAML.dump(config))

    stdout, = capture_streams do
      expect(described_class.run(['create', '--branch', 'main', '--preset', 'Admin',
                                  '--set', 'APP_CHANNEL=my=portal', '--set', 'EXTRA=yes',
                                  '--unset', 'APP_VARIANT', '--json'])).to eq(0)
    end
    id = JSON.parse(stdout).fetch('id')
    expect(Workspaces::EnvironmentOverrides.new(id).editable_values(config['default_editable_env']))
      .to eq('APP_VARIANT' => 'www', 'APP_CHANNEL' => 'my=portal', 'EXTRA' => 'yes')

    before = Workspaces::Registry.new.list.length
    [['--set', 'BAD'], ['--set', 'SECRET_TOKEN=bad'], ['--unset', 'WORKSPACE_PORT'],
     ['--set', 'APP_VARIANT=one', '--set', 'APP_VARIANT=two']].each do |flags|
      _, stderr = capture_streams do
        expect(described_class.run(['create', '--branch', 'main', *flags])).to eq(1)
      end
      expect(stderr).not_to be_empty
      expect(Workspaces::Registry.new.list.length).to eq(before)
    end
  end

  it 'exec runs command with workspace Bundler env even under source Bundler env' do
    source_root = Workspaces::Config.home.join('source-bundle')
    write_path_marker_bundle(root: source_root, marker: 'source', include_workspaces: true)

    repository
    workspace_root = Workspaces::Config.worktrees_dir.join('bundle-fixture-1234')
    FileUtils.mkdir_p(workspace_root)
    write_path_marker_bundle(root: workspace_root, marker: 'workspace')

    File.write(workspace_root.join('.git'), "gitdir: #{Workspaces::Config.repo_root.join('.git')}\n")
    output_file = workspace_root.join('cli-marker.txt')
    metadata = {
      'version' => 1,
      'id' => 'bundle-fixture-1234',
      'branch' => 'workspaces/bundle-fixture-1234',
      'source' => { 'kind' => 'branch', 'ref' => 'main' },
      'created_at' => Time.now.utc.iso8601,
      'repository_path' => Workspaces::Config.repo_root.realpath.to_s
    }
    File.write(workspace_root.join('.workspace.json'), JSON.pretty_generate(metadata), perm: 0o600)

    source_env = {
      'BUNDLE_GEMFILE' => source_root.join('Gemfile').to_s,
      'BUNDLE_LOCKFILE' => source_root.join('Gemfile.lock').to_s,
      'BUNDLER_ORIG_BUNDLE_GEMFILE' => source_root.join('Gemfile').to_s,
      'BUNDLER_ORIG_BUNDLE_LOCKFILE' => source_root.join('Gemfile.lock').to_s,
      'BUNDLER_ORIG_GEM_PATH' => '/tmp/orig-gem-path',
      'APP_KEEP' => 'yes',
      'APP_DELETE' => 'remove-me'
    }
    stdout, stderr, status = Open3.capture3(
      source_env, 'bundle', 'exec', 'ruby', '-e', "require 'workspaces'; exit Workspaces::Cli.run(ARGV)",
      'exec', 'bundle-fixture-1234', '--', *bundled_path_marker_command(output_path: output_file),
      chdir: source_root.to_s
    )

    expect(status).to be_success, stderr
    expect(output_file).to exist
    cli_output = output_file.read
    expect(stdout).to include('marker=workspace')
    expect(cli_output).to include('marker=workspace')
    expect(cli_output).to include('nested=workspace')
    expect(cli_output).to include("gemfile=#{workspace_root.join('Gemfile')}")
    expect(cli_output).to include("lockfile=#{workspace_root.join('Gemfile.lock')}")
    expect(cli_output).to include('app_keep=yes')
    expect(cli_output).to include('app_delete=remove-me')
    expect(cli_output).not_to include('marker=source')
    expect(cli_output).not_to include(source_root.join('Gemfile').to_s)
    expect(cli_output).not_to include(source_root.join('Gemfile.lock').to_s)
  end

  def write_tls_pair(directory, cert_path: File.join(directory, 'cert.pem'), key_path: File.join(directory, 'key.pem'))
    generate_tls_pair(cert_path: cert_path, key_path: key_path)
    [cert_path, key_path]
  end
end
