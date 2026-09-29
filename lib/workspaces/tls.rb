# frozen_string_literal: true

require 'openssl'
require 'uri'
require_relative 'config'

module Workspaces
  class Tls
    DEFAULT_CERT_PATH = '~/.workspaces/certs/workspaces.pem'
    DEFAULT_KEY_PATH = '~/.workspaces/certs/workspaces-key.pem'
    DEFAULT_PUBLIC_ORIGIN_HOST = 'workspaces.localhost'

    attr_reader :cert_path, :key_path, :shortcut

    def self.from_serve_options(options)
      cert = options[:tls_cert]
      key = options[:tls_key]
      raise ArgumentError, '--tls-cert and --tls-key must be provided together' if cert.nil? ^ key.nil?
      return nil unless options[:secure] || cert

      new(tls_cert: cert || default_cert_path, tls_key: key || default_key_path,
          shortcut: cert.nil?)
    end

    def self.default_cert_path
      File.expand_path(DEFAULT_CERT_PATH)
    end

    def self.default_key_path
      File.expand_path(DEFAULT_KEY_PATH)
    end

    def initialize(tls_cert:, tls_key:, shortcut: false)
      @cert_path = File.expand_path(tls_cert.to_s)
      @key_path = File.expand_path(tls_key.to_s)
      @shortcut = shortcut
    end

    def validate!
      validate_public_origin!
      validate_file!(:certificate, cert_path)
      validate_file!(:private_key, key_path)

      certificate = OpenSSL::X509::Certificate.new(File.read(cert_path))
      private_key = OpenSSL::PKey.read(File.read(key_path))

      unless certificate.check_private_key(private_key)
        raise ArgumentError, 'TLS certificate does not match the TLS private key'
      end

      self
    rescue OpenSSL::OpenSSLError, ArgumentError => e
      raise e if e.is_a?(ArgumentError)

      raise ArgumentError, 'TLS certificate or private key is invalid'
    end

    def bind_uri(host:, port:)
      query = URI.encode_www_form(cert: cert_path, key: key_path, verify_mode: 'none')
      "ssl://#{host}:#{port}?#{query}"
    end

    def env_exports
      origin = default_public_origin
      domain = default_base_domain
      [
        "export WORKSPACES_PUBLIC_ORIGIN=#{origin}",
        "export WORKSPACES_BASE_DOMAIN=#{domain}"
      ]
    end

    def apply_env_defaults
      defaults = { 'WORKSPACES_PUBLIC_ORIGIN' => default_public_origin,
                   'WORKSPACES_BASE_DOMAIN' => default_base_domain }
      temporary = defaults.select { |name, _| ENV.fetch(name, '').empty? }
      previous = temporary.keys.to_h { |name| [name, ENV.fetch(name, nil)] }
      temporary.each { |name, value| ENV[name] = value }
      yield
    ensure
      previous&.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    end

    private

    def effective_public_origin
      return default_public_origin if ENV['WORKSPACES_PUBLIC_ORIGIN'].to_s.empty?

      Config.public_origin
    end

    def default_public_origin
      "https://#{DEFAULT_PUBLIC_ORIGIN_HOST}:#{Config.front_door_port}"
    end

    def default_base_domain
      DEFAULT_PUBLIC_ORIGIN_HOST
    end

    def validate_public_origin!
      return if URI.parse(effective_public_origin).scheme == 'https'

      raise ArgumentError, 'TLS requires an HTTPS WORKSPACES_PUBLIC_ORIGIN'
    rescue URI::InvalidURIError
      raise ArgumentError, 'Invalid WORKSPACES_PUBLIC_ORIGIN'
    end

    def validate_file!(label, path)
      raise ArgumentError, "TLS #{label} file does not exist: #{path}" unless File.file?(path)
      raise ArgumentError, "TLS #{label} file is not readable: #{path}" unless File.readable?(path)
    end
  end
end
