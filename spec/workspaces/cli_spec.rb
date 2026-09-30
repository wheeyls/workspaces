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

  def write_tls_pair(directory, cert_path: File.join(directory, 'cert.pem'), key_path: File.join(directory, 'key.pem'))
    generate_tls_pair(cert_path: cert_path, key_path: key_path)
    [cert_path, key_path]
  end
end
