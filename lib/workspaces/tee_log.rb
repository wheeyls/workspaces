# frozen_string_literal: true

require_relative 'environment_overrides'

module Workspaces
  # Duplicates every log line to both the persistent per-PR log file AND the front door
  # process's own stdout - so progress during a (sometimes 1-2 minute) first-time prepare shows
  # up live in the terminal running `bin/pr-preview`, not just in a file nobody's tailing.
  # Prefixed with the PR number since multiple previews can be preparing concurrently.
  class TeeLog
    def initialize(workspace_id, file)
      @workspace_id = workspace_id
      @file = file
      @overrides = EnvironmentOverrides.new(workspace_id)
    end

    def puts(message = '')
      scrubbed = scrub(message)
      @file.puts(scrubbed)
      $stdout.puts(prefixed(scrubbed))
    end

    def print(message)
      scrubbed = scrub(message)
      @file.print(scrubbed)
      $stdout.print(prefixed(scrubbed))
    end

    private

    def scrub(message)
      @overrides.scrub(message)
    end

    def prefixed(message)
      "[Workspace #{@workspace_id}] #{message}"
    end
  end
end
