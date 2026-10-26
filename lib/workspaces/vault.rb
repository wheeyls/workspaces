# frozen_string_literal: true

module Workspaces
  # Where write-only secrets live. The dashboard can put a secret in and a workspace's steps can read it
  # back out, but nothing here ever hands a value to the interface.
  #
  # A provider stores one set of name => value strings per scope (a workspace id) and is chosen with
  # WORKSPACES_VAULT (default "file"). Register another with Vault.register(name, ProviderClass). The
  # contract is small on purpose so that a remote store fits behind it:
  #
  #   available?  / problem   whether it can be used, and if not, a plain-language reason that never
  #                           contains key material
  #   read(scope)             the whole set, {} when there is none; raises Unavailable when a set exists
  #                           but cannot be read
  #   write(scope, entries)   replaces the whole set; an empty hash removes it
  #   purge(scope)            removes the set (used when a workspace is removed)
  module Vault
    class Error < StandardError; end
    class Unavailable < Error; end

    DEFAULT_PROVIDER = 'file'

    # The shape every provider follows. Providers inherit it so a missing method fails loudly.
    class Provider
      def name
        raise NotImplementedError, "#{self.class} must name itself"
      end

      def problem
        nil
      end

      def available?
        problem.nil?
      end

      def read(_scope)
        raise NotImplementedError, "#{self.class} must implement read"
      end

      def write(_scope, _entries)
        raise NotImplementedError, "#{self.class} must implement write"
      end

      def purge(_scope)
        raise NotImplementedError, "#{self.class} must implement purge"
      end

      def status
        { 'provider' => name, 'available' => available?, 'problem' => problem }
      end
    end

    # Stands in for a provider name nobody registered, so a typo shows up as a clear message in the
    # dashboard rather than an exception while rendering it.
    class Unknown < Provider
      def initialize(requested)
        super()
        @requested = requested.to_s[0, 40]
      end

      def name
        @requested
      end

      def problem
        "Unknown secret vault provider #{@requested.inspect}"
      end

      # Nothing can be stored under an unknown provider, so there is nothing to read or remove; a typo
      # in WORKSPACES_VAULT must not stop workspaces that have no secrets from running.
      def read(_scope)
        {}
      end

      def write(_scope, _entries)
        raise Unavailable, problem
      end

      def purge(_scope)
        nil
      end
    end

    @providers = {}

    class << self
      def register(name, provider_class)
        @providers[name.to_s] = provider_class
      end

      def provider(name = ENV.fetch('WORKSPACES_VAULT', nil))
        requested = name.to_s.strip
        requested = DEFAULT_PROVIDER if requested.empty?
        klass = @providers[requested]
        klass ? klass.new : Unknown.new(requested)
      end

      def status
        provider.status
      end
    end
  end
end

require_relative 'vault/file_vault'
