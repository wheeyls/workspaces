# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require_relative 'version'

module Workspaces
  # A quiet, append-only record of every finished run, plus the per-step averages derived from it.
  #
  # One JSON object per line in `build-history.jsonl` under the Workspaces home, shared by every
  # workspace of the project, so it can be read with jq or loaded into a spreadsheet to see how
  # setup times trend. Only successful runs feed the progress estimates; failed runs are recorded
  # for the trend but never skew what "usual" means.
  #
  # Nothing here may break a build: recording failures are swallowed with a one-line warning.
  module BuildHistory
    SAMPLE_SIZE = 10
    # The estimates only need recent runs, so a long history is read from its tail.
    READ_BYTES = 512 * 1024

    module_function

    def record(workspace_id:, operation:, result:, total_seconds:, steps:, now: Time.now.utc)
      line = JSON.generate(
        'at' => now.iso8601, 'workspace_id' => workspace_id, 'operation' => operation, 'result' => result,
        'total_seconds' => total_seconds, 'workspaces_version' => VERSION,
        'steps' => Array(steps).map { |step| { 'id' => step['key'], 'state' => step['state'], 'seconds' => step['duration_seconds'] } }
      )
      path = Config.build_history_path
      FileUtils.mkdir_p(path.dirname)
      File.open(path, 'a') do |file|
        file.flock(File::LOCK_EX)
        file.puts(line)
      end
      true
    rescue StandardError => e
      warn "[Workspaces] build history not recorded: #{e.class}"
      false
    end

    # Mean seconds for each requested step id, over its last SAMPLE_SIZE completions in
    # successful runs. Steps never seen succeed are omitted.
    def estimates(step_ids)
      wanted = step_ids.to_a
      samples = Hash.new { |hash, key| hash[key] = [] }
      records.reverse_each do |record|
        next unless record['result'] == 'complete'

        Array(record['steps']).each do |step|
          id = step['id']
          seconds = step['seconds']
          next unless wanted.include?(id) && step['state'] == 'complete' && seconds.is_a?(Numeric) && seconds >= 0
          next if samples[id].length >= SAMPLE_SIZE

          samples[id] << seconds
        end
      end
      samples.transform_values { |values| (values.sum / values.length).round(3) }
    rescue StandardError
      {}
    end

    # Newest last. Unreadable or half-written lines are skipped.
    def records
      path = Config.build_history_path
      return [] unless path.file?

      text = File.open(path, 'rb') do |file|
        size = file.size
        file.seek(-READ_BYTES, IO::SEEK_END) if size > READ_BYTES
        data = file.read.force_encoding('UTF-8')
        size > READ_BYTES ? data.sub(/\A[^\n]*\n/, '') : data
      end
      text.each_line.filter_map do |line|
        parsed = JSON.parse(line)
        parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
