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

    def initialize(workspace_id, home: Config.home)
      @workspace_id = Config.validate_id!(workspace_id.to_s)
      @home = home
    end

    def load
      reject_symlink!(directory_path)
      reject_symlink!(file_path)
      return {} unless file_path.exist?

      parsed = JSON.parse(file_path.read)
      raise Invalid, 'Stored environment overrides are invalid' unless parsed.is_a?(Hash)

      validate_entries!(parsed)
    rescue JSON::ParserError
      raise Invalid, 'Stored environment overrides are invalid'
    end

    def keys
      load.keys.sort
    end

    def apply_patch(set:, remove:)
      validate_patch!(set, remove)
      updated = load.merge(set)
      remove.each { |name| updated.delete(name) }
      validate_entries!(updated)
      persist(updated)
      updated
    end

    def clear!
      delete_file!
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

    def directory_path
      home.join('environment')
    end

    def file_path
      directory_path.join("#{workspace_id}.json")
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
      raise Invalid, 'Stored environment overrides are invalid' unless entries.is_a?(Hash)
      raise Invalid, 'Environment overrides are limited to 100 entries' if entries.length > MAX_ENTRIES

      entries.each_with_object({}) do |(name, value), normalized|
        validate_name!(name)
        validate_value!(value)
        normalized[name] = value
      end
    end

    def validate_name!(name)
      unless name.is_a?(String) && name.match?(NAME_PATTERN)
        raise Invalid, 'Environment names must match /^[A-Za-z_][A-Za-z0-9_]*$/'
      end
      raise Invalid, 'Environment name is reserved for the workspace runner' if reserved_name?(name)
    end

    def validate_value!(value)
      raise Invalid, 'Environment values must be strings' unless value.is_a?(String)
      raise Invalid, 'Environment values must not contain NUL bytes' if value.include?("\0")
      return if value.bytesize <= MAX_VALUE_BYTES

      raise Invalid, 'Environment values must be 8192 bytes or smaller'
    end

    def reserved_name?(name)
      BLOCKED_NAMES.include?(name) || BLOCKED_PREFIXES.any? { |prefix| name.start_with?(prefix) }
    end

    def persist(entries)
      ensure_directory!
      reject_symlink!(file_path)
      return delete_file! if entries.empty?

      temp_path = directory_path.join(".#{workspace_id}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp")
      begin
        write_temp_file(temp_path, entries)
        File.rename(temp_path, file_path)
        File.chmod(0o600, file_path)
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

    def delete_file!
      return unless file_path.exist?

      reject_symlink!(file_path)
      File.unlink(file_path)
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
