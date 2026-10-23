# frozen_string_literal: true

require_relative 'config'

module Workspaces
  # Puts ready workspaces to sleep once they have seen no preview traffic for a while. It only
  # decides when; stopping the server, and every check that must hold while it does, is the
  # coordinator's. The tracker is what keeps a request that is being served from being cut off.
  class Sleeper
    def initialize(coordinator:, tracker:, threshold: Config.sleep_after_seconds, interval: Config.sleep_sweep_seconds)
      @coordinator = coordinator
      @tracker = tracker
      @threshold = threshold
      @interval = interval
      @thread = nil
    end

    # Settles anything a previous front door left half done, then sweeps on a timer.
    def start
      return self if @threshold.nil?

      @coordinator.reconcile_sleep
      @thread = Thread.new do
        loop do
          sleep @interval
          sweep
        end
      end
      self
    end

    def stop
      @thread&.kill
      @thread = nil
    end

    def sweep
      return [] if @threshold.nil?

      @coordinator.sleep_candidates.select do |id|
        @tracker.sleep_if_idle(id, @threshold) { @coordinator.sleep!(id) }
      rescue StandardError => e
        warn "[Workspaces] could not put #{id} to sleep: #{e.class}"
        false
      end
    end
  end
end
