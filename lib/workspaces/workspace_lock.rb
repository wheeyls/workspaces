# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'config'
require_relative 'duration_format'

module Workspaces
  # The per-workspace lock that serializes preparing, restarting, stopping, removing, updating and
  # running commands, plus a record of who holds it.
  #
  # The lock is a non-blocking exclusive flock, so the kernel releases it when the holder exits for
  # any reason, including SIGKILL. A holder that died therefore never leaves the lock stuck; only a
  # holder that is alive and not finishing does. The record in the file is written by the holder and
  # emptied when it lets go. It is only meaningful while the lock is held, so a record left behind by
  # a holder that died is ignored.
  class WorkspaceLock
    GENERIC_BUSY = 'Workspace is busy preparing, restarting, or running a command'

    OPERATIONS = {
      'prepare' => 'preparing', 'restart' => 'restarting', 'resume' => 're-running setup steps',
      'sleep' => 'putting the workspace to sleep', 'wake' => 'waking the workspace',
      'stop' => 'stopping the server', 'remove' => 'removing the workspace',
      'update-pr' => 'updating the PR checkout'
    }.freeze

    # Takes the lock, or returns nil when someone else holds it.
    def self.acquire(id, operation:, detail: nil)
      Config.locks_dir.mkpath
      file = File.open(Config.prepare_lock_path(id), File::RDWR | File::CREAT, 0o600)
      unless file.flock(File::LOCK_EX | File::LOCK_NB)
        file.close
        return nil
      end

      lock = new(file)
      lock.update('operation' => operation, 'pid' => Process.pid, 'started_at' => Time.now.utc.iso8601,
                  'detail' => detail)
      lock
    rescue StandardError
      file&.close unless file&.closed?
      raise
    end

    # True while some process holds the lock.
    def self.held?(id)
      path = Config.prepare_lock_path(id)
      return false unless path.file?

      File.open(path, File::RDWR) { |file| !file.flock(File::LOCK_EX | File::LOCK_NB) }
    end

    # What the current holder wrote, or nil when nothing holds the lock or the record cannot be read.
    def self.holder(id)
      return nil unless held?(id)

      record = JSON.parse(Config.prepare_lock_path(id).read)
      record.is_a?(Hash) ? record : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def self.busy_message(id)
      record = holder(id)
      return GENERIC_BUSY unless record

      "Workspace is busy: #{describe(record)}"
    end

    def self.describe(record)
      operation = record['operation'].to_s
      return describe_command(record) if operation == 'exec'

      OPERATIONS.fetch(operation, operation)
    end

    def self.describe_command(record)
      text = +'running a command'
      text << " (#{record['detail']})" if record['detail']
      pids = [record['child_pid'] && "pid #{record['child_pid']}"].compact
      text << ", #{pids.join(', ')}" unless pids.empty?
      elapsed = elapsed_text(record['started_at'])
      text << ", for #{elapsed}" if elapsed
      limit = DurationFormat.call(record['timeout_seconds'])
      text << ". It will be stopped automatically after #{limit}" if limit
      text
    end
    private_class_method :describe_command

    def self.elapsed_text(started_at)
      DurationFormat.call(Time.now - Time.iso8601(started_at.to_s))
    rescue ArgumentError
      nil
    end
    private_class_method :elapsed_text

    def initialize(file)
      @file = file
      @record = {}
    end

    # Adds to what the holder has told the world, keeping what it already said.
    def update(fields)
      @record = @record.merge(fields.compact)
      @file.rewind
      @file.truncate(0)
      @file.write(JSON.generate(@record))
      @file.flush
    end

    # A descriptor the background worker owns, so the request that took the lock can close its own
    # without releasing it.
    def dup
      self.class.allocate.tap { |copy| copy.send(:adopt, @file.dup, @record) }
    end

    def close
      return if @file.closed?

      @file.truncate(0)
      @file.close
    rescue IOError, SystemCallError
      @file.close unless @file.closed?
    end

    def closed?
      @file.closed?
    end

    private

    def adopt(file, record)
      @file = file
      @record = record
    end
  end
end
