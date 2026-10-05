require 'yaml'
require_relative 'config'
require_relative 'environment_overrides'

module Workspaces
  class Recipe
    class Invalid < ArgumentError; end
    RESERVED_ENV = %w(WORKSPACE_ID WORKSPACE_PATH WORKSPACE_REPO_ROOT WORKSPACE_PORT WORKSPACE_URL
                      WORKSPACE_HOST WORKSPACE_CACHE_DIR WORKSPACE_RUN_ID).freeze
    attr_reader :steps, :environment, :default_editable_env, :environment_presets

    def initialize(root: Config.repo_root)
      @root = root
      document = YAML.safe_load(root.join('.workspaces.yml').read, aliases: false)
      validate_document!(document)
      @default_editable_env = validate_editable_env!(document.fetch('default_editable_env', {}))
      @environment_presets = validate_environment_presets!(document.fetch('environment_presets', {}))
      @environment = validate_env!(document.fetch('env', {}))
      @steps = document.fetch('steps').map { |step| validate_step!(step) }
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
      unknown_keys!(document, %w(version env default_editable_env environment_presets steps))
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
