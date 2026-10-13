require 'rack'

module Workspaces
  # Adds a Rack middleware stack around workspace preview traffic.
  #
  # The gem stays unaware of what any middleware does: the process hosting the front
  # door registers its own, for example from a file named by WORKSPACES_REQUIRE:
  #
  #   Workspaces.configure_proxy do
  #     use MyMiddleware, option: 'value'
  #   end
  #
  # Blocks are replayed in registration order into a Rack::Builder, so the first
  # `use` is the outermost middleware. The stack wraps only the step that forwards a
  # request to a ready workspace backend. The dashboard, redirects for workspaces that
  # are not ready, and error responses never pass through it.
  module ProxyMiddleware
    ENV_VAR = 'WORKSPACES_REQUIRE'

    # Raised for unusable configuration; the CLI reports it and exits non-zero.
    class ConfigurationError < ArgumentError; end

    @blocks = []

    def self.register(&block)
      raise ConfigurationError, 'Workspaces.configure_proxy requires a block' unless block

      @blocks << block
      self
    end

    def self.any?
      !@blocks.empty?
    end

    def self.reset!
      @blocks.clear
    end

    # Returns the endpoint untouched when nothing is registered, so an unconfigured
    # front door behaves exactly as it did before this seam existed.
    def self.build(endpoint)
      blocks = @blocks.dup
      return endpoint if blocks.empty?

      Rack::Builder.new do
        blocks.each { |block| instance_exec(&block) }
        run endpoint
      end.to_app
    end

    # Paths from WORKSPACES_REQUIRE, separated like PATH entries.
    def self.env_paths
      ENV.fetch(ENV_VAR, '').split(File::PATH_SEPARATOR).map(&:strip).reject(&:empty?)
    end

    # Executes the given Ruby files so they can register middleware. These files run
    # with the privileges of the front door; only name files the operator controls.
    def self.load_files(paths)
      paths.each do |path|
        full_path = File.expand_path(path)
        raise ConfigurationError, "Proxy middleware file not found: #{path}" unless File.file?(full_path)

        begin
          require full_path
        rescue ScriptError, StandardError => e
          raise ConfigurationError, "Could not load proxy middleware #{path}: #{e.class}: #{e.message}"
        end
      end
      paths
    end
  end

  def self.configure_proxy(&block)
    ProxyMiddleware.register(&block)
  end
end
