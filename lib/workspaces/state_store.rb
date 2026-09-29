# frozen_string_literal: true

require 'json'
require 'fileutils'

module Workspaces
  # Tiny JSON-file-backed key/value store, keyed by PR number (as a string), guarded by an
  # exclusive flock so the front door and CLI commands can safely read/modify it concurrently.
  class StateStore
    def initialize(path)
      @path = path
    end

    # Yields the full state hash (String pr_number => attrs Hash) inside an exclusive lock and
    # persists whatever the block leaves it as. Returns the block's return value.
    def transaction
      with_lock(File::LOCK_EX, create: true) do |file|
        data = read_data(file)
        result = yield(data)
        write_data(file, data)
        result
      end
    end

    def all
      with_lock(File::LOCK_SH, default: {}) { |file| deep_copy(read_data(file)) }
    end

    def get(pr_number)
      with_lock(File::LOCK_SH, default: nil) { |file| deep_copy(read_data(file)[pr_number.to_s]) }
    end

    def set(pr_number, attrs)
      transaction { |data| data[pr_number.to_s] = (data[pr_number.to_s] || {}).merge(attrs) }
    end

    def delete(pr_number)
      transaction { |data| data.delete(pr_number.to_s) }
    end

    private

    attr_reader :path

    def with_lock(lock_type, create: false, default: nil)
      ensure_parent_dir! if create
      mode = create ? (File::RDWR | File::CREAT) : File::RDONLY
      File.open(path, mode) do |file|
        file.flock(lock_type)
        yield(file)
      end
    rescue Errno::ENOENT
      default
    end

    def ensure_parent_dir!
      FileUtils.mkdir_p(File.dirname(path))
    end

    def read_data(file)
      file.rewind
      raw = file.read
      return {} if raw.to_s.strip.empty?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def write_data(file, data)
      file.rewind
      file.truncate(0)
      file.write(JSON.pretty_generate(data))
      file.flush
    end

    def deep_copy(value)
      return nil if value.nil?

      JSON.parse(JSON.generate(value))
    end
  end
end
