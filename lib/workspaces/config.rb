# frozen_string_literal: true

require 'pathname'
require 'uri'
require_relative 'paths'

module Workspaces
  module Config
    extend Paths

    SAFE_LOG_BYTES = 8 * 1024
    SAFE_LOG_LINES = 100
    # Each step shows its own tail, so the per-step bounds are smaller than the combined log's.
    STEP_LOG_BYTES = 6 * 1024
    STEP_LOG_LINES = 80
    DEFAULT_HOME = File.expand_path('~/.workspaces')
    DEFAULT_SUBDOMAIN_PREFIX = 'ws-'
    DEFAULT_FRONT_DOOR_PORT = 4747
    BACKEND_PORT_RANGE = (30_000..30_999)
    DEFAULT_SLEEP_AFTER_MINUTES = 30
    DEFAULT_WAKE_TIMEOUT_SECONDS = 90
    DEFAULT_SLEEP_SWEEP_SECONDS = 30

    # Seconds a ready workspace may go without preview traffic before it is put to sleep, or nil when
    # sleeping is switched off (WORKSPACES_SLEEP_AFTER_MINUTES=0). Fractions of a minute are allowed.
    def self.sleep_after_seconds
      minutes = positive_number('WORKSPACES_SLEEP_AFTER_MINUTES', DEFAULT_SLEEP_AFTER_MINUTES, allow_zero: true)
      minutes.zero? ? nil : minutes * 60
    end

    # How long the first request to a sleeping preview waits for the server to be ready.
    def self.wake_timeout_seconds
      positive_number('WORKSPACES_WAKE_TIMEOUT_SECONDS', DEFAULT_WAKE_TIMEOUT_SECONDS)
    end

    def self.sleep_sweep_seconds
      positive_number('WORKSPACES_SLEEP_SWEEP_SECONDS', DEFAULT_SLEEP_SWEEP_SECONDS)
    end

    def self.positive_number(name, default, allow_zero: false)
      value = Float(ENV.fetch(name, default.to_s))
      return value if value.finite? && (value.positive? || (allow_zero && value.zero?))

      raise ArgumentError, "#{name} must be a#{allow_zero ? ' non-negative' : ' positive'} number"
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be a#{allow_zero ? ' non-negative' : ' positive'} number"
    end
    private_class_method :positive_number

    def self.front_door_port
      Integer(ENV.fetch('WORKSPACES_PORT', DEFAULT_FRONT_DOOR_PORT))
    end

    def self.front_door_host
      public_uri.authority
    end

    def self.bind_address
      ENV.fetch('WORKSPACES_BIND', '127.0.0.1')
    end

    def self.public_origin
      uri = public_uri
      "#{uri.scheme}://#{uri.authority}"
    end

    def self.public_uri
      value = ENV.fetch('WORKSPACES_PUBLIC_ORIGIN', "http://localhost:#{front_door_port}")
      uri = URI.parse(value)
      unless valid_origin?(uri)
        raise ArgumentError,
              'WORKSPACES_PUBLIC_ORIGIN must be an HTTP(S) origin without credentials or a path'
      end

      uri
    rescue URI::InvalidURIError
      raise ArgumentError, 'Invalid WORKSPACES_PUBLIC_ORIGIN'
    end

    def self.valid_origin?(uri)
      uri.is_a?(URI::HTTP) && uri.host && ['', '/'].include?(uri.path) &&
        [uri.userinfo, uri.query, uri.fragment].all?(&:nil?)
    end

    def self.preview_base_domain
      domain = ENV.fetch('WORKSPACES_BASE_DOMAIN', 'localhost').downcase
      labels = domain.split('.', -1)
      valid = domain.length <= 253 && labels.all? do |label|
        label.length <= 63 && label.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/)
      end
      raise ArgumentError, 'Invalid WORKSPACES_BASE_DOMAIN' unless valid

      domain
    end

    def self.preview_subdomain_prefix
      prefix = ENV.fetch('WORKSPACES_SUBDOMAIN_PREFIX', DEFAULT_SUBDOMAIN_PREFIX)
      validate_preview_subdomain_prefix!(prefix)
      prefix
    end

    def self.preview_host(workspace_id)
      validate_id!(workspace_id)
      hostname = "#{preview_subdomain_prefix}#{workspace_id}.#{preview_base_domain}"
      raise ArgumentError, 'Workspace hostname exceeds DNS label limits' if hostname.split('.').any? do |label|
        label.length > 63
      end
      uri = public_uri
      uri.port == uri.default_port ? hostname : "#{hostname}:#{uri.port}"
    end

    def self.preview_url(workspace_id)
      "#{public_uri.scheme}://#{preview_host(workspace_id)}/"
    end

    def self.preview_workspace_id(host)
      pattern = "#{Regexp.escape(preview_subdomain_prefix)}(?<workspace_id>[a-z0-9]+(?:-[a-z0-9]+)*)\\." \
                "#{Regexp.escape(preview_base_domain)}"
      match = /\A#{pattern}\z/i.match(host.to_s)
      match && match[:workspace_id].downcase
    end

    def self.validate_id!(id)
      return id if id.is_a?(String) && id.length <= 48 && id.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)

      raise ArgumentError, 'Invalid workspace ID'
    end

    def self.dashboard_url(id)
      "#{public_origin}/workspaces/#{validate_id!(id)}"
    end

    def self.validate_preview_subdomain_prefix!(prefix)
      parts = prefix.to_s.split('.', -1)
      raise ArgumentError, 'WORKSPACES_SUBDOMAIN_PREFIX must not be empty' if parts.empty? || parts.any?(&:empty?)

      parts[0...-1].each do |part|
        next if part.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/)

        raise ArgumentError, "Unsafe WORKSPACES_SUBDOMAIN_PREFIX: #{prefix.inspect}"
      end

      return prefix if parts.last.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9-])?\z/)

      raise ArgumentError, "Unsafe WORKSPACES_SUBDOMAIN_PREFIX: #{prefix.inspect}"
    end
  end
end
