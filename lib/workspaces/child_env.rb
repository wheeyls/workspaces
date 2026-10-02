module Workspaces
  module ChildEnv
    module_function

    def for_workspace(workspace_path:, extra_env: {}, parent_env: ENV.to_h)
      env = parent_env.to_h.transform_keys(&:to_s).dup
      if defined?(::Bundler)
        clean = Bundler.unbundled_env
        %w(PATH GEM_HOME GEM_PATH MANPATH RUBYOPT RUBYLIB RB_USER_INSTALL).each do |name|
          clean.key?(name) ? env[name] = clean[name] : env.delete(name)
        end
      end
      env.delete_if { |key, _| bundler_key?(key) }

      gemfile = File.join(workspace_path.to_s, 'Gemfile')
      env['BUNDLE_GEMFILE'] = gemfile
      env['BUNDLE_LOCKFILE'] = File.join(workspace_path.to_s, 'Gemfile.lock')

      extra_env.to_h.each do |name, value|
        key = name.to_s
        next if bundler_key?(key)

        if value.nil?
          env.delete(key)
        else
          env[key] = value
        end
      end

      env
    end

    def bundler_key?(key)
      %w(BUNDLE_GEMFILE BUNDLE_LOCKFILE BUNDLER_SETUP BUNDLER_VERSION).include?(key) ||
        key.start_with?('BUNDLER_ORIG_')
    end
  end
end
