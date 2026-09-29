require 'openssl'

module Workspaces
  module TlsPairFixture
    def generate_tls_pair(cert_path:, key_path:)
      key = OpenSSL::PKey::RSA.new(2048)
      certificate = build_tls_certificate(key)
      File.write(cert_path, certificate.to_pem)
      File.write(key_path, key.to_pem)
      [certificate, key]
    end

    def build_tls_certificate(key)
      certificate = OpenSSL::X509::Certificate.new
      certificate.version = 2
      certificate.serial = 1
      certificate.subject = OpenSSL::X509::Name.parse('/CN=127.0.0.1')
      certificate.issuer = certificate.subject
      certificate.public_key = key.public_key
      certificate.not_before = Time.now.utc - 60
      certificate.not_after = Time.now.utc + 3600
      sign_tls_certificate(certificate, key)
    end

    def sign_tls_certificate(certificate, key)
      extensions = OpenSSL::X509::ExtensionFactory.new
      extensions.subject_certificate = certificate
      extensions.issuer_certificate = certificate
      add_tls_extensions(certificate, extensions)
      certificate.sign(key, OpenSSL::Digest.new('SHA256'))
      certificate
    end

    def add_tls_extensions(certificate, extensions)
      certificate.add_extension(extensions.create_extension('basicConstraints', 'CA:TRUE', true))
      certificate.add_extension(extensions.create_extension('keyUsage',
                                                            'digitalSignature,keyEncipherment,keyCertSign', true))
      certificate.add_extension(extensions.create_extension('subjectKeyIdentifier', 'hash'))
      certificate.add_extension(extensions.create_extension('subjectAltName', 'IP:127.0.0.1', false))
    end
  end
end
