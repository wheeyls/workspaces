# frozen_string_literal: true

require 'json'
require 'securerandom'

module Workspaces
  class EnvironmentOverrides
    class Invalid < ArgumentError; end

    NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    BLOCKED_PREFIXES = %w(WORKSPACE_ WORKSPACES_).freeze
    BLOCKED_NAMES = %w(PORT WWW_HOST CANONICAL_HOST WEBPACK_ASSET_HOST).freeze
    MAX_ENTRIES = 100
    MAX_VALUE_BYTES = 8192
    MAX_BODY_BYTES = 128 * 1024

    def self.validate_entries!(entries)
      raise Invalid, 'Environment overrides must be a mapping' unless entries.is_a?(Hash)
      raise Invalid, 'Environment overrides are limited to 100 entries' if entries.length > MAX_ENTRIES

      entries.each_with_object({}) do |(name, value), normalized|
        validate_name!(name)
        validate_value!(value)
        normalized[name] = value
      end
    end

    def self.validate_name!(name)
      unless name.is_a?(String) && name.match?(NAME_PATTERN)
        raise Invalid, 'Environment names must match /^[A-Za-z_][A-Za-z0-9_]*$/'
      end
      return unless BLOCKED_NAMES.include?(name) || BLOCKED_PREFIXES.any? { |prefix| name.start_with?(prefix) }

      raise Invalid, 'Environment name is reserved for the workspace runner'
    end

    def self.validate_value!(value)
      raise Invalid, 'Environment values must be strings' unless value.is_a?(String)
      raise Invalid, 'Environment values must not contain NUL bytes' if value.include?("\0")
      raise Invalid, 'Environment values must be 8192 bytes or smaller' if value.bytesize > MAX_VALUE_BYTES
    end

    def initialize(workspace_id, home: Config.home)
      @workspace_id = Config.validate_id!(workspace_id.to_s)
      @home = home
    end

    def load
      load_file(file_path).merge(load_file(editable_file_path))
    end

    def keys
      load.keys.sort
    end

    def editable_values(defaults)
      legacy = load_file(file_path).slice(*defaults.keys)
      editable = load_file(editable_file_path).reject { |name, _| sensitive_name?(name) }
      defaults.merge(legacy).merge(editable)
    end

    def replace_editable(text, defaults:)
      raise Invalid, 'Environment editor must contain text' unless text.is_a?(String)
      raise Invalid, 'Environment update payload is too large' if text.bytesize > MAX_BODY_BYTES
      self.class.validate_entries!(defaults)

      entries = parse_lines(text)
      self.class.validate_entries!(entries)

      updated = entries.reject { |name, value| defaults[name] == value }
      if updated.keys.any? { |name| sensitive_name?(name) }
        raise Invalid, 'Secret-like environment names cannot be stored in the visible editor'
      end
      persist_editable(entries, updated, defaults)
      load
    end

    def apply_preset(name, recipe: Recipe.new)
      apply_settings(preset: name, recipe: recipe)
    end

    def self.settings_for(recipe:, preset: nil, set: {}, unset: [], current: nil)
      defaults = recipe.default_editable_env
      preset_values = recipe.environment_presets.fetch(preset) { raise Invalid, "Unknown environment preset: #{preset}" } if preset
      values = preset ? defaults.merge(preset_values) : (current || defaults).dup
      validate_entries!(set)
      unset.each { |name| validate_name!(name) }
      raise Invalid, 'Cannot set and unset the same name' unless (set.keys & unset).empty?
      names = set.keys + unset
      if names.any? { |name| name.match?(/(?:SECRET|TOKEN|PASSWORD|API_KEY|PRIVATE_KEY|CREDENTIAL)/i) }
        raise Invalid, 'Secret-like environment names cannot be stored in the visible editor'
      end
      values.merge!(set)
      unset.each { |name| values.delete(name) }
      validate_entries!(values)
      values
    end

    def apply_settings(preset: nil, set: {}, unset: [], recipe: Recipe.new)
      current = preset ? nil : editable_values(recipe.default_editable_env)
      values = self.class.settings_for(recipe: recipe, preset: preset, set: set, unset: unset, current: current)
      replace_editable(values.sort.map { |key, value| "#{key}=#{value}" }.join("\n"), defaults: recipe.default_editable_env)
    end

    def apply_patch(set:, remove:)
      validate_patch!(set, remove)
      updated = load_file(file_path).merge(set)
      remove.each { |name| updated.delete(name) }
      validate_entries!(updated)
      persist(updated)
      updated
    end

    def clear!
      delete_file!
      delete_file!(editable_file_path)
    end

    def scrub(value)
      text = value.to_s.encode('UTF-8', invalid: :replace, undef: :replace)
      scrub_values.each do |secret|
        text = text.gsub(secret, '[FILTERED]')
      end
      text
    end

    private

    attr_reader :workspace_id, :home

    def sensitive_name?(name)
      name.match?(/(?:SECRET|TOKEN|PASSWORD|API_KEY|PRIVATE_KEY|CREDENTIAL)/i)
    end

    def parse_lines(text)
      entries = {}
      text.each_line.with_index(1) do |line, number|
        line = line.delete_suffix("\n").delete_suffix("\r")
        next if line.strip.empty?

        name, separator, value = line.partition('=')
        raise Invalid, "Line #{number} must be NAME=value" if separator.empty? || name != name.strip
        raise Invalid, "Line #{number} repeats #{name}" if entries.key?(name)
        raise Invalid, "Line #{number}: values must not contain carriage returns" if value.include?("\r")

        entries[name] = value
      end
      entries
    end

    def persist_editable(entries, updated, defaults)
      legacy = load_file(file_path)
      load_file(editable_file_path)
      kept = legacy.reject { |name, _| defaults.key?(name) || entries.key?(name) }
      validate_entries!(kept.merge(updated))
      persist(kept)
      persist(updated, path: editable_file_path)
    end

    def directory_path
      home.join('environment')
    end

    def file_path
      directory_path.join("#{workspace_id}.json")
    end

    def editable_file_path
      directory_path.join("#{workspace_id}.editable.json")
    end

    def load_file(path)
      reject_symlink!(directory_path)
      reject_symlink!(path)
      return {} unless path.exist?

      parsed = JSON.parse(path.read)
      validate_entries!(parsed)
    rescue JSON::ParserError
      raise Invalid, 'Stored environment overrides are invalid'
    end

    def validate_patch!(set, remove)
      set_names = validate_set!(set)
      remove_names = validate_remove!(remove)
      return unless set_names.intersect?(remove_names)

      raise Invalid, 'Environment changes cannot set and remove the same name'
    end

    def validate_set!(set)
      raise Invalid, 'Environment updates must be a mapping of names to string values' unless set.is_a?(Hash)

      set.each do |name, value|
        validate_name!(name)
        validate_value!(value)
      end
      set.keys
    end

    def validate_remove!(remove)
      raise Invalid, 'Environment removals must be an array of names' unless remove.is_a?(Array)

      remove.each { |name| validate_name!(name) }
      remove
    end

    def validate_entries!(entries)
      self.class.validate_entries!(entries)
    end

    def validate_name!(name)
      self.class.validate_name!(name)
    end

    def validate_value!(value)
      self.class.validate_value!(value)
    end

    def persist(entries, path: file_path)
      ensure_directory!
      reject_symlink!(path)
      return delete_file!(path) if entries.empty?

      temp_path = directory_path.join(".#{workspace_id}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp")
      begin
        write_temp_file(temp_path, entries)
        File.rename(temp_path, path)
        File.chmod(0o600, path)
      ensure
        File.unlink(temp_path) if temp_path.exist?
      end
    end

    def write_temp_file(path, entries)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(entries))
        file.flush
        file.fsync
      end
    end

    def delete_file!(path = file_path)
      return unless path.exist? || path.symlink?

      reject_symlink!(path)
      File.unlink(path)
    end

    def ensure_directory!
      if directory_path.exist?
        reject_symlink!(directory_path)
        raise Invalid, 'Environment storage path is invalid' unless directory_path.directory?
      else
        directory_path.mkpath
      end
      File.chmod(0o700, directory_path)
    end

    def reject_symlink!(path)
      raise Invalid, 'Environment storage does not allow symlinks' if path.symlink?
    end

    def scrub_values
      load.values.reject(&:empty?).uniq.sort_by { |value| -value.bytesize }
    rescue Invalid
      []
    end
  end
end
