require_relative 'spec_helper'

RSpec.describe Workspaces::CommandRunner do
  let(:log) { StringIO.new }
  let(:runner) { described_class.new(Workspaces::Config.home.tap(&:mkpath), log) }

  it 'streams output and reports nonzero exit status' do
    expect { runner.run!(['ruby', '-e', 'puts "failure detail"; exit 4'], env: {}, timeout: 5) }
      .to raise_error(described_class::Failed, /status 4/)
    expect(log.string).to include('failure detail')
  end

  it 'bounds the whole process lifetime even after stdout is closed' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { runner.run!(['ruby', '-e', 'STDOUT.close; STDERR.close; sleep 30'], env: {}, timeout: 1) }
      .to raise_error(described_class::Failed, /timeout/)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be < 5
  end

  it 'streams scrubbed output through the tee log' do
    workspace_id = 'fixture-1234'
    file = StringIO.new
    log = Workspaces::TeeLog.new(workspace_id, file)
    Workspaces::EnvironmentOverrides.new(workspace_id).apply_patch(set: { 'APP_VARIANT' => 'top-secret-token' }, remove: [])

    described_class.new(Workspaces::Config.home.tap(&:mkpath), log)
      .run!(['ruby', '-e', 'puts "token=top-secret-token"'], env: {}, timeout: 5)

    expect(file.string).to include('[FILTERED]')
    expect(file.string).not_to include('top-secret-token')
  end

  it 'resolves path gems from the managed workspace under inherited Bundler env' do
    source_root = Workspaces::Config.home.join('source-bundle')
    workspace_root = Workspaces::Config.home.join('workspace-bundle')
    write_path_marker_bundle(root: source_root, marker: 'source')
    write_path_marker_bundle(root: workspace_root, marker: 'workspace')

    source_gemfile = source_root.join('Gemfile').to_s
    source_lockfile = source_root.join('Gemfile.lock').to_s
    workspace_gemfile = workspace_root.join('Gemfile').to_s
    workspace_lockfile = workspace_root.join('Gemfile.lock').to_s

    runner = described_class.new(workspace_root, log)
    command = bundled_path_marker_command
    env = {
      'BUNDLE_GEMFILE' => source_gemfile,
      'BUNDLE_LOCKFILE' => source_lockfile,
      'BUNDLER_ORIG_BUNDLE_GEMFILE' => source_gemfile,
      'BUNDLER_ORIG_BUNDLE_LOCKFILE' => source_lockfile,
      'BUNDLER_ORIG_GEM_PATH' => '/tmp/orig-gem-path',
      'BUNDLE_RUBYGEMS__PKG__GITHUB__COM' => 'fixture-credential',
      'APP_KEEP' => 'yes',
      'APP_DELETE' => nil
    }

    ClimateControl.modify(env) do
      runner.run!(command, env: { 'APP_KEEP' => 'yes', 'APP_DELETE' => nil }, timeout: 20)
    end

    expect(log.string).to include('marker=workspace')
    expect(log.string).to include('nested=workspace')
    expect(log.string).to include("gemfile=#{workspace_gemfile}")
    expect(log.string).to include("lockfile=#{workspace_lockfile}")
    expect(log.string).to include('app_keep=yes')
    expect(log.string).to include('bundle_credential=fixture-credential')
    expect(log.string).to include('app_delete=<unset>')
    expect(log.string).not_to include('marker=source')
    expect(log.string).not_to include("gemfile=#{source_gemfile}")
    expect(log.string).not_to include("lockfile=#{source_lockfile}")
    expect(log.string).not_to include('BUNDLER_ORIG_')
  end
end
