# frozen_string_literal: true

require 'time'
require_relative 'duration_format'

module Workspaces
  # A deliberately simple read on how far along a run is, for a progress bar.
  #
  # With history: each step carries weight equal to its usual duration, finished steps count in
  # full, and the running step counts by how much of its usual time has passed. Without history
  # every step weighs the same and only finished steps count. The bar never claims 100% while
  # work remains, and a step that overruns its usual time is held back so the bar waits for it.
  class Progress
    MIN_WEIGHT = 1.0
    MAX_PERCENT = 99
    STEP_CAP = 0.95
    SLOW_FACTOR = 1.5

    def initialize(steps:, estimates:, started_at:, now: Time.now)
      @steps = steps
      @estimates = estimates || {}
      @started_at = parse(started_at)
      @now = now
    end

    def to_h
      return nil if @steps.empty?

      { 'percent' => percent, 'step_label' => current_step['label'], 'step_text' => "Step #{current_index + 1} of #{@steps.length}",
        'elapsed_seconds' => elapsed, 'eta_text' => eta_text, 'slow' => slow?, 'estimated' => estimated? }
    end

    private

    def percent
      done = 0.0
      @steps.each_with_index do |step, index|
        case step['state']
        when 'complete' then done += weights[index]
        when 'active' then done += weights[index] * active_fraction(step, weights[index])
        end
      end
      [(done / weights.sum * 100).floor, MAX_PERCENT].min
    end

    def active_fraction(step, weight)
      return 0.0 unless estimated?

      [step_elapsed(step) / weight, STEP_CAP].min
    end

    def estimated?
      @steps.any? { |step| estimate(step) }
    end

    def estimate(step)
      value = @estimates[step['key']]
      value.is_a?(Numeric) && value.positive? ? [value, MIN_WEIGHT].max : nil
    end

    # A step with no history of its own borrows the average of the ones that have it.
    def weights
      @weights ||= begin
        known = @steps.filter_map { |step| estimate(step) }
        fallback = known.empty? ? 1.0 : known.sum / known.length
        @steps.map { |step| estimate(step) || fallback }
      end
    end

    def current_index
      @current_index ||= @steps.index { |step| step['state'] == 'active' } ||
                         @steps.index { |step| step['state'] == 'pending' } || (@steps.length - 1)
    end

    def current_step
      @steps[current_index]
    end

    def step_elapsed(step)
      started = parse(step['started_at'])
      started ? [@now - started, 0].max : 0.0
    end

    def slow?
      step = @steps.find { |item| item['state'] == 'active' }
      estimated? && !step.nil? && step_elapsed(step) > weights[@steps.index(step)] * SLOW_FACTOR
    end

    def remaining
      @steps.each_with_index.sum do |step, index|
        case step['state']
        when 'pending' then weights[index]
        when 'active' then [weights[index] - step_elapsed(step), 0].max
        else 0
        end
      end
    end

    def eta_text
      return nil unless estimated?
      return 'Taking longer than usual' if slow?
      return 'Almost done' if remaining < 5

      "About #{DurationFormat.call(round_eta(remaining))} left"
    end

    # A countdown that changes by single seconds reads as noise; round to what a person would say.
    def round_eta(seconds)
      seconds >= 60 ? (seconds / 10.0).round * 10 : (seconds / 5.0).round * 5
    end

    def elapsed
      @started_at ? [(@now - @started_at).floor, 0].max : nil
    end

    def parse(value)
      value && Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
