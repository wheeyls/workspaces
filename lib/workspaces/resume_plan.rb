# frozen_string_literal: true

module Workspaces
  # Decides which steps a re-run covers, from what a workspace last recorded and what the recipe
  # says now. Pure: no files, no processes, so every rule can be tested directly.
  #
  # Three ways to ask:
  #   :retry  continue from the first step that did not finish, but never later than the server
  #           step, because a failed run stops the server and everything after it needs a new one
  #   :from   re-run one step and every step after it
  #   :only   re-run exactly one step, leaving the rest of the run (and a running server) alone
  #
  # Refusals are plain-language ArgumentErrors, so callers can show them as they are.
  class ResumePlan
    class Refused < ArgumentError; end

    Plan = Struct.new(:mode, :run_keys, :steps, :touches_server, :after_server, :description, keyword_init: true)

    MODES = %i(only from).freeze

    def self.describe(recipe_steps:, persisted:, server_live: false)
      new(recipe_steps, persisted).describe(server_live: server_live)
    end

    def self.build(recipe_steps:, persisted:, mode:, key: nil, server_live: false)
      new(recipe_steps, persisted).build(mode: mode, key: key, server_live: server_live)
    end

    def initialize(recipe_steps, persisted)
      @recipe_keys = recipe_steps.map { |step| step['id'] }
      @server_key = recipe_steps.find { |step| step['background'] }&.fetch('id')
      @persisted = Array(persisted).map(&:dup)
      @keys = @persisted.map { |step| step['key'] }
    end

    # What the dashboard needs to offer the right buttons, or nil when re-running is not possible
    # (no recorded steps, or the recipe's steps have changed since they were recorded). Each step
    # lists the modes that would be accepted for it, by asking `build` rather than repeating its rules.
    def describe(server_live: false)
      return nil unless compatible?

      index = retry_index
      { 'server_key' => @server_key,
        'retry_from' => index && @keys[index],
        'retry_label' => index && @persisted[index]['label'],
        'step_modes' => @keys.to_h { |key| [key, allowed_modes(key, server_live)] } }
    end

    def build(mode:, key: nil, server_live: false)
      unless compatible?
        raise Refused, 'The steps recorded for this workspace no longer match .workspaces.yml; re-run all steps instead'
      end

      from, to = range_for(mode, key)
      run_keys = @keys[from..to]
      touches = (from..to).cover?(server_idx)
      after = from > server_idx
      if after && !server_live
        raise Refused, 'The server is not running, or was started before step re-runs were supported; ' \
                       're-run from the server step instead'
      end

      Plan.new(mode: mode, run_keys: run_keys, steps: carried_steps(run_keys), touches_server: touches,
               after_server: after, description: describe_range(mode, run_keys))
    end

    private

    # The recorded steps are either the whole recipe or, after a restart, everything from the
    # server step on. Anything else means the recipe moved on and the record cannot be trusted.
    def compatible?
      return false if @server_key.nil? || @keys.empty?

      @keys == @recipe_keys || @keys == @recipe_keys.drop(@recipe_keys.index(@server_key))
    end

    def server_idx
      @server_idx ||= @keys.index(@server_key)
    end

    def retry_index
      first = @persisted.index { |step| step['state'] != 'complete' }
      first && [first, server_idx].min
    end

    def range_for(mode, key)
      last = @keys.length - 1
      case mode
      when :retry
        index = retry_index
        raise Refused, 'Every step already completed, so there is nothing to retry' unless index

        [index, last]
      when :from
        index = index_of(key)
        require_finished_before!(index)
        [index, last]
      when :only
        index = index_of(key)
        if index == server_idx
          raise Refused, 'Restarting the server means re-running the steps after it; re-run from that step instead'
        end
        require_others_finished!(index)

        [index, index]
      else
        raise ArgumentError, "Unknown re-run mode: #{mode.inspect}"
      end
    end

    # A re-run must never leave an unfinished step behind, so that a successful one always means the
    # whole workspace is complete.
    def require_finished_before!(index)
      first = @persisted.index { |step| step['state'] != 'complete' }
      return if first.nil? || first >= index

      raise Refused, "\"#{label_at(first)}\" has not finished; re-run from that step or an earlier one"
    end

    def require_others_finished!(index)
      other = @persisted.each_index.find { |i| i != index && @persisted[i]['state'] != 'complete' }
      return if other.nil?

      raise Refused, "\"#{label_at(other)}\" has not finished; re-run from that step instead of a single step"
    end

    def label_at(index)
      @persisted[index]['label'] || @keys[index]
    end

    def allowed_modes(key, server_live)
      MODES.select do |mode|
        build(mode: mode, key: key, server_live: server_live)
        true
      rescue Refused
        false
      end.map(&:to_s)
    end

    def index_of(key)
      @keys.index(key.to_s) || raise(Refused, "Unknown step: #{key.to_s[0, 60].inspect}")
    end

    # The step list to publish: finished work stays as it was, the steps about to run start over.
    def carried_steps(run_keys)
      @persisted.map do |step|
        next step unless run_keys.include?(step['key'])

        step.merge('state' => 'pending', 'duration_seconds' => nil).tap { |reset| reset.delete('started_at') }
      end
    end

    def describe_range(mode, run_keys)
      names = run_keys.map { |key| @persisted[@keys.index(key)]['label'] || key }
      case mode
      when :only then "only #{names.first}"
      when :from then "from #{names.first}"
      else "from #{names.first}"
      end
    end
  end
end
