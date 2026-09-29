require_relative 'spec_helper'
require 'net/http'
require 'openssl'
require 'timeout'
require 'workspaces/tls'

RSpec.describe Workspaces::Tls do
  def generate_pair(_directory, key:, cert:, subject_alt_name: 'IP:127.0.0.1')
    raise ArgumentError, 'Unsupported certificate subject' unless subject_alt_name == 'IP:127.0.0.1'

    generate_tls_pair(cert_path: cert, key_path: key)
  end

  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end

  it 'rejects TLS when the effective public origin is HTTP' do
    Dir.mktmpdir do |directory|
      cert_path = File.join(directory, 'cert.pem')
      key_path = File.join(directory, 'key.pem')
      generate_pair(directory, cert: cert_path, key: key_path)

      ClimateControl.modify('WORKSPACES_PUBLIC_ORIGIN' => 'http://localhost:4747') do
        expect do
          described_class.new(tls_cert: cert_path, tls_key: key_path).validate!
        end.to raise_error(ArgumentError, 'TLS requires an HTTPS WORKSPACES_PUBLIC_ORIGIN')
      end
    end
  end

  it 'rejects a certificate and key that do not match' do
    Dir.mktmpdir do |directory|
      cert_path = File.join(directory, 'cert.pem')
      key_path = File.join(directory, 'key.pem')
      generate_pair(directory, cert: cert_path, key: File.join(directory, 'other-key.pem'))
      File.write(key_path, OpenSSL::PKey::RSA.new(2048).to_pem)

      ClimateControl.modify('WORKSPACES_PUBLIC_ORIGIN' => 'https://localhost:4747') do
        expect do
          described_class.new(tls_cert: cert_path, tls_key: key_path).validate!
        end.to raise_error(ArgumentError, 'TLS certificate does not match the TLS private key')
      end
    end
  end

  it 'serves the front door over HTTPS with a trusted client' do
    repository
    Dir.mktmpdir do |directory|
      cert_path = File.join(directory, 'cert.pem')
      key_path = File.join(directory, 'key.pem')
      certificate, = generate_pair(directory, cert: cert_path, key: key_path)
      port = free_port
      tls = nil
      launcher = nil
      server = nil

      ClimateControl.modify('WORKSPACES_BIND' => '127.0.0.1',
                            'WORKSPACES_PORT' => port.to_s,
                            'WORKSPACES_PUBLIC_ORIGIN' => "https://127.0.0.1:#{port}") do
        tls = described_class.new(tls_cert: cert_path, tls_key: key_path).validate!
        app = Workspaces::FrontDoor.new
        server = Thread.new do
          Rackup::Handler::Puma.run(app, Host: tls.bind_uri(host: Workspaces::Config.bind_address,
                                                            port: Workspaces::Config.front_door_port),
                                         config_files: ['-'], workers: 0, Silent: true) do |running_launcher|
            launcher = running_launcher
          end
        end

        Timeout.timeout(10) do
          sleep 0.05 until launcher&.connected_ports&.include?(port)
        end

        store = OpenSSL::X509::Store.new
        store.add_cert(certificate)
        response = nil
        Timeout.timeout(10) do
          loop do
            http = Net::HTTP.new('127.0.0.1', port)
            http.use_ssl = true
            http.verify_mode = OpenSSL::SSL::VERIFY_PEER
            http.cert_store = store
            response = http.get('/workspaces')
            break
          rescue Errno::ECONNREFUSED, OpenSSL::SSL::SSLError, Net::OpenTimeout, Net::ReadTimeout
            sleep 0.05
          end
        end

        expect(response.code).to eq('200')
        expect(response.body).to include('Create workspace')
      ensure
        launcher&.stop
        server&.join(10)
      end
    end
  end
end
