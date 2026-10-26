# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'vault'

module Workspaces
  class EnvironmentOverrides
    class Invalid < ArgumentError; end

    NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    BLOCKED_PREFIXES = %w(WORKSPACE_ WORKSPACES_).freeze
    BLOCKED_NAMES = %w(PORT WWW_HOST CANONICAL_HOST WEBPACK_ASSET_HOST).freeze
    MAX_ENTRIES = 100
    MAX_VALUE_BYTES = 8192
    MAX_BODY_BYTES = 128 * 1024
    MAX_ROWS = 200

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

    # Everything a step should see: saved variables and secrets. Raises Vault::Error when secrets
    # exist but cannot be read, so a run fails with a reason instead of starting without them.
    def load
      load_plain.merge(secret_values)
    end

    # The variables that are safe to show. No secrets, and no vault access.
    def load_plain
      load_file(file_path).merge(load_file(editable_file_path))
    end

    def keys
      (load_plain.keys + secret_names).uniq.sort
    end

    # Names only, never values. Empty when the vault cannot be opened.
    def secret_names
      secret_values.keys.sort
    rescue Vault::Error
      []
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
      load_plain
    end

    # Saves the settings form: a list of rows, each { 'name', 'value', 'secret' }. Plain rows are
    # stored as editable settings. Secret rows go to the vault and are write-only: a secret row
    # with no value keeps the value already stored, and a secret that is no longer listed is removed.
    #
    # Nothing is changed unless every row is valid and the vault can be used. Messages name
    # variables, never values.
    def replace_rows(rows, defaults:)
      raise Invalid, 'Environment rows must be a list' unless rows.is_a?(Array)
      raise Invalid, "Environment rows are limited to #{MAX_ROWS}" if rows.length > MAX_ROWS

      self.class.validate_entries!(defaults)
      plain, secrets = split_rows(rows)
      self.class.validate_entries!(plain)
      self.class.validate_entries!(secrets.compact)
      raise Invalid, 'Environment overrides are limited to 100 entries' if plain.length + secrets.length > MAX_ENTRIES

      write_secrets(secrets)
      persist_editable(plain, plain.reject { |name, value| defaults[name] == value }, defaults)
      load_plain
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
      Vault.provider.purge(workspace_id)
    rescue Vault::Error
      nil
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

    # Filtering still hides every secret that can be read, even when something else is wrong.
    def scrub_values
      values = [safely { load_plain.values }, safely { secret_values.values }].flatten
      values.reject(&:empty?).uniq.sort_by { |value| -value.bytesize }
    end

    def safely
      yield
    rescue Invalid, Vault::Error
      []
    end

    def secret_values
      Vault.provider.read(workspace_id)
    end

    def split_rows(rows)
      plain = {}
      secrets = {}
      rows.each do |row|
        raise Invalid, 'Each environment row needs a name and a value' unless row.is_a?(Hash)

        name = row['name'].to_s.strip
        value = row['value'].to_s
        next if name.empty? && value.empty?

        raise Invalid, 'Every variable needs a name' if name.empty?
        raise Invalid, "#{name} is listed more than once" if plain.key?(name) || secrets.key?(name)

        if [true, '1', 'true', 'on'].include?(row['secret'])
          validate_name!(name)
          secrets[name] = value.empty? ? nil : value
        else
          validate_plain_row!(name, value)
          plain[name] = value
        end
      end
      [plain, secrets]
    end

    def validate_plain_row!(name, value)
      validate_name!(name)
      validate_value!(value)
      raise Invalid, "#{name} looks like a secret: tick Secret so it is stored write-only" if sensitive_name?(name)
      raise Invalid, "#{name}: values must be a single line" if value.match?(/[\r\n]/)
    end

    # `submitted` maps each secret's name to its new value, or nil when the row was left blank. A blank
    # row keeps the stored value. Existing secrets are never replaced blindly: if the vault cannot be
    # read (wrong or missing key) an edit is refused rather than overwriting what is stored.
    def write_secrets(submitted)
      vault = Vault.provider
      unless vault.available?
        raise Vault::Unavailable, vault.problem unless submitted.empty?

        return
      end

      stored = vault.read(workspace_id)
      result = submitted.to_h do |name, value|
        [name, value || stored.fetch(name) { raise Invalid, "#{name} is a new secret and needs a value" }]
      end
      vault.write(workspace_id, result) unless result == stored
    end
  end
end
