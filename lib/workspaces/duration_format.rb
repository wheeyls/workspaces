# frozen_string_literal: true

module Workspaces
  # Human durations, written the way people read them: "0.5s", "12.3s", "1m 10s", "1h 5m 3s".
  #
  # The dashboard script (dashboard/app.js, formatDuration) implements the same rules, and a
  # spec runs both against the same inputs so the page and the setup log cannot disagree.
  module DurationFormat
    module_function

    # Returns nil for anything that is not a usable duration, so callers can fall back to
    # showing no time at all instead of a wrong one.
    def call(seconds)
      return nil unless seconds.is_a?(Numeric) && seconds.finite? && seconds >= 0

      return tenths(seconds) if seconds < 60

      whole = seconds.round
      hours, rest = whole.divmod(3600)
      minutes, secs = rest.divmod(60)
      return "#{hours}h #{minutes}m #{secs}s" if hours.positive?

      "#{minutes}m #{secs}s"
    end

    # Under a minute a decimal is still useful (0.5s reads better than 1s), but a trailing
    # ".0" is noise: 12.0 is "12s".
    def tenths(seconds)
      rounded = (seconds * 10).round / 10.0
      # 59.96 rounds to 60.0, which belongs on the minutes side.
      return '1m 0s' if rounded >= 60

      rounded == rounded.to_i ? "#{rounded.to_i}s" : "#{rounded}s"
    end
  end
end
