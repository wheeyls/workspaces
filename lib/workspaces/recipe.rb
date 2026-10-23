require 'yaml'
require 'json'
require 'digest'
require_relative 'config'
require_relative 'environment_overrides'

module Workspaces
  class Recipe
    class Invalid < ArgumentError; end
    RESERVED_ENV = %w(WORKSPACE_ID WORKSPACE_PATH WORKSPACE_REPO_ROOT WORKSPACE_PORT WORKSPACE_URL
                      WORKSPACE_HOST WORKSPACE_CACHE_DIR WORKSPACE_RUN_ID).freeze
    LFS_STEP_ID = 'lfs'.freeze
    LFS_STEP_NAME = 'Fetch Git LFS files'.freeze
    attr_reader :steps, :environment, :default_editable_env, :environment_presets, :lfs_fetch, :sleep_ignore_paths

    def initialize(root: Config.repo_root)
      @root = root
      document = YAML.safe_load(root.join('.workspaces.yml').read, aliases: false)
      validate_document!(document)
      @default_editable_env = validate_editable_env!(document.fetch('default_editable_env', {}))
      @environment_presets = validate_environment_presets!(document.fetch('environment_presets', {}))
      @environment = validate_env!(document.fetch('env', {}))
      @lfs_fetch = validate_lfs!(document.fetch('lfs', {}))
      @sleep_ignore_paths = validate_sleep!(document.fetch('sleep', {}))
      @steps = document.fetch('steps').map { |step| validate_step!(step) }
      @steps = [lfs_step] + @steps unless lfs_fetch.empty?
      validate_editable_overlap!
      validate_sequence!
    rescue Errno::ENOENT
      raise Invalid, 'Add .workspaces.yml to the source repository before starting a workspace'
    rescue Psych::Exception => e
      raise Invalid, "Invalid .workspaces.yml: #{e.message}"
    end

    def for_operation(restart: false)
      restart ? steps.drop(steps.index { |step| step['background'] }) : steps
    end

    # Changes when a step that runs before the server changes. A sleeping workspace wakes by running
    # only the server and readiness steps, unless this no longer matches what it was prepared with.
    def preparation_digest
      server = steps.index { |step| step['background'] }
      material = { 'env' => environment, 'steps' => steps.first(server).map { |step| step.slice('id', 'run', 'env', 'timeout') } }
      Digest::SHA256.hexdigest(JSON.generate(material))
    end

    # Files fetched into the workspace come from the LFS objects the source repository already
    # has, then are linked in by `git lfs pull`; the source's store is shared by every workspace.
    def lfs_step
      { 'id' => LFS_STEP_ID, 'name' => LFS_STEP_NAME, 'timeout' => 600, 'env' => {}, 'background' => false,
        'run' => ['git', 'lfs', 'pull', "--include=#{lfs_fetch.join(',')}"] }
    end

    def command(step, context)
      command = step.fetch('run')
      return ['sh', '-c', command] if command.is_a?(String)

      command.map { |argument| expand(argument, context) }
    end

    def env(step, context, overrides: {})
      expanded = environment.merge(step.fetch('env', {})).merge(default_editable_env).transform_values do |value|
        value.nil? ? nil : expand(value, context)
      end
      expanded.merge(overrides).merge(context)
    end

    private

    def validate_document!(document)
      unless document.is_a?(Hash) && document['version'] == 1
        raise Invalid,
              'Configuration must be a mapping with version: 1'
      end
      unknown_keys!(document, %w(version env default_editable_env environment_presets lfs sleep steps))
      raise Invalid, 'steps must be a nonempty array' unless document['steps'].is_a?(Array) && !document['steps'].empty?
    end

    def validate_step!(step)
      raise Invalid, 'Each step must be a mapping' unless step.is_a?(Hash)
      unknown_keys!(step, %w(id name run env timeout background))
      validate_step_identity!(step)
      validate_command!(step['run'])
      validate_background!(step)
      timeout = step.fetch('timeout', 600)
      unless timeout.is_a?(Integer) && timeout.positive?
        raise Invalid,
              'Step timeout must be a positive integer (seconds)'
      end

      step.merge('timeout' => timeout, 'env' => validate_env!(step.fetch('env', {})))
    end

    def validate_step_identity!(step)
      unless step['id'].is_a?(String) && step['id'].match?(/\A[a-z][a-z0-9_-]*\z/)
        raise Invalid,
              'Step id must be a lowercase slug'
      end
      return if step['name'].is_a?(String) && !step['name'].strip.empty?
      raise Invalid,
            'Step name must be a nonempty string'
    end

    def validate_command!(command)
      valid = command.is_a?(String) ? (!command.strip.empty? && valid_argument?(command)) : valid_argv?(command)
      raise Invalid, 'run must be a nonempty shell string or an array of string arguments' unless valid
    end

    def valid_argv?(command)
      command.is_a?(Array) && !command.empty? && command.first != '' && command.all? { |arg| valid_argument?(arg) }
    end

    def valid_argument?(argument)
      argument.is_a?(String) && argument.index("\0").nil?
    end

    def validate_background!(step)
      return unless step.key?('background')
      raise Invalid, 'background must be true or false' unless [true, false].include?(step['background'])
      return unless step['background'] && step.key?('timeout')
      raise Invalid,
            'timeout applies to foreground steps, not the server lifetime'
    end

    # `lfs: { fetch: [path, ...] }` names the Git LFS files a workspace needs. Everything else
    # stays a pointer. Paths are repository-relative globs handed to `git lfs pull --include`, so
    # they are checked for the things that would make that unsafe or surprising.
    def validate_lfs!(value)
      raise Invalid, 'lfs must be a mapping' unless value.is_a?(Hash)

      unknown_keys!(value, %w(fetch))
      paths = value.fetch('fetch', [])
      raise Invalid, 'lfs.fetch must be an array of paths' unless paths.is_a?(Array)

      paths.each do |path|
        unless path.is_a?(String) && !path.strip.empty? && path == path.strip
          raise Invalid, 'lfs.fetch paths must be nonempty trimmed strings'
        end
        raise Invalid, 'lfs.fetch paths cannot contain commas or control characters' if path.match?(/[,[:cntrl:]]/)
        raise Invalid, 'lfs.fetch paths must be relative to the repository' if path.start_with?('/', '-') || path.split('/').include?('..')
      end
      paths.uniq
    end

    # `sleep: { ignore_paths: [glob, ...] }` names preview paths that are background polling, so they
    # do not keep an otherwise idle workspace awake. Globs match the request path (without the query).
    def validate_sleep!(value)
      raise Invalid, 'sleep must be a mapping' unless value.is_a?(Hash)

      unknown_keys!(value, %w(ignore_paths))
      paths = value.fetch('ignore_paths', [])
      raise Invalid, 'sleep.ignore_paths must be an array of paths' unless paths.is_a?(Array)

      paths.each do |path|
        unless path.is_a?(String) && path.start_with?('/') && path == path.strip && !path.match?(/[[:cntrl:]]/)
          raise Invalid, 'sleep.ignore_paths entries must be trimmed strings starting with /'
        end
      end
      paths.uniq
    end

    def validate_env!(values)
      raise Invalid, 'env must be a mapping' unless values.is_a?(Hash)
      values.each do |key, value|
        validate_env_name!(key)
        raise Invalid, "#{key} is supplied by the workspace runner" if RESERVED_ENV.include?(key)
        raise Invalid, 'Environment values must be strings or null' unless value.nil? || value.is_a?(String)
      end
      values
    end

    def validate_editable_env!(values, setting: 'default_editable_env')
      raise Invalid, "#{setting} must be a mapping" unless values.is_a?(Hash)

      EnvironmentOverrides.validate_entries!(values)
      values.each do |key, value|
        raise Invalid, "#{key} is supplied by the workspace runner" if RESERVED_ENV.include?(key)
        if key.match?(/(?:SECRET|TOKEN|PASSWORD|API_KEY|PRIVATE_KEY|CREDENTIAL)/i)
          raise Invalid, "Secret-like names cannot be declared in #{setting}"
        end
        raise Invalid, 'Editable environment values must be single-line strings' if value.match?(/[\r\n]/)
      end
      values
    rescue EnvironmentOverrides::Invalid => e
      raise Invalid, e.message
    end

    def validate_environment_presets!(presets)
      raise Invalid, 'environment_presets must be a mapping' unless presets.is_a?(Hash)

      presets.each do |name, values|
        unless name.is_a?(String) && !name.empty? && name == name.strip && !name.match?(/[[:cntrl:]]/)
          raise Invalid, 'Preset names must be nonempty trimmed strings without control characters'
        end
        validate_editable_env!(values, setting: 'Each environment preset')
        unless (values.keys - default_editable_env.keys).empty?
          raise Invalid, 'Preset environment names must be declared in default_editable_env'
        end
      end
      presets
    end

    def validate_editable_overlap!
      names = default_editable_env.keys
      return unless environment.keys.intersect?(names) || steps.any? { |step| step['env'].keys.intersect?(names) }

      raise Invalid, 'default_editable_env names cannot also appear in env or step env'
    end

    def validate_env_name!(key)
      return if key.is_a?(String) && key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

      raise Invalid, 'Environment names must be strings'
    end

    def validate_sequence!
      raise Invalid, 'Step IDs must be unique' unless steps.uniq { |step| step['id'] }.length == steps.length
      unless steps.one? { |step| step['background'] }
        raise Invalid, 'Configure exactly one background run step for the application'
      end
      raise Invalid, 'Add a foreground readiness command after the background step' if steps.last['background']
    end

    def unknown_keys!(mapping, allowed)
      unknown = mapping.keys - allowed
      raise Invalid, "Unknown configuration keys: #{unknown.join(', ')}" unless unknown.empty?
    end

    def expand(value, context)
      value.gsub(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/) do
        name = Regexp.last_match(1)
        context.fetch(name) { ENV.fetch(name) { raise Invalid, "Missing environment variable: #{name}" } }
      end
    end
  end
end
