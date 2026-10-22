# frozen_string_literal: true

module Workspaces
  # Splits a run's output by recipe step.
  #
  # Wraps the combined log (a TeeLog, or anything with puts/print). Everything still goes to
  # the combined log exactly as before; while a step is current, the same text is also written
  # to that step's own file so the dashboard can show each step under its own heading.
  #
  # Text arriving through this object has already been scrubbed by the wrapped log, so we hand
  # it the raw text and copy what it actually wrote, rather than scrubbing twice.
  class StepLog
    def initialize(log, workspace_id)
      @log = log
      @workspace_id = workspace_id
      @file = nil
    end

    # Begins a step's file, truncating any output from an earlier run of the same step.
    def begin_step(step_id)
      finish_step
      @file = File.open(Config.step_log_path(@workspace_id, step_id), 'w')
      @file.sync = true
    end

    def finish_step
      @file&.close
      @file = nil
    end

    def puts(message = '')
      text = scrubbed(message)
      @log.puts(message)
      @file&.puts(text)
    end

    def print(message)
      text = scrubbed(message)
      @log.print(message)
      @file&.print(text)
    end

    # Clears every step file; called when a run begins so a restart never shows stale steps.
    def self.reset(workspace_id, keys: nil)
      dir = Config.step_logs_dir(workspace_id, create: false)
      return unless dir.directory?

      Dir.glob(dir.join('*.log')).each do |path|
        File.delete(path) if keys.nil? || keys.include?(File.basename(path, '.log'))
      end
    end

    private

    def scrubbed(message)
      @log.respond_to?(:scrub_text) ? @log.scrub_text(message) : message.to_s
    end
  end
end
