# frozen_string_literal: true

module Workspaces
  # Remembers when each workspace last saw preview traffic and how many requests are in flight.
  # Only the front door that proxies the traffic can know this, so it lives in memory.
  #
  # A request holds a Lease from the moment it is accepted until its response is finished, and a
  # workspace with any lease out is never put to sleep. The decision to sleep and new requests meet
  # at one mutex: once a workspace is chosen for sleep, `acquire` refuses until the sleep is over,
  # so a request can never slip in between "nothing in flight" and "server stopped".
  class ActivityTracker
    class Lease
      def initialize(tracker, id, counted)
        @tracker = tracker
        @id = id
        @counted = counted
        @released = false
      end

      def release
        @tracker.send(:release, self, @id, @counted)
      end

      def released?
        @released
      end

      def mark_released!
        was = @released
        @released = true
        !was
      end
    end

    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @clock = clock
      @mutex = Mutex.new
      @last_activity = {}
      @in_flight = Hash.new(0)
      @sleeping = {}
    end

    # `counted: false` is for traffic that must not keep a workspace awake (configured background
    # polling): it still holds a lease, so the server is not stopped under it.
    # Returns nil while the workspace is being put to sleep.
    def acquire(id, counted: true)
      @mutex.synchronize do
        return nil if @sleeping[id]

        @in_flight[id] += 1
        @last_activity[id] = @clock.call if counted
        Lease.new(self, id, counted)
      end
    end

    def touch(id)
      @mutex.synchronize { @last_activity[id] = @clock.call }
    end

    # Seconds since the last counted activity. A workspace seen for the first time starts its idle
    # clock now, which is also how the clocks restart after the front door does.
    def idle_for(id)
      @mutex.synchronize { @clock.call - (@last_activity[id] ||= @clock.call) }
    end

    def in_flight(id)
      @mutex.synchronize { @in_flight[id] }
    end

    # Runs the block only if the workspace has been idle for `threshold` seconds with nothing in
    # flight, and keeps new requests out until it returns. Returns the block's value, or false.
    def sleep_if_idle(id, threshold)
      @mutex.synchronize do
        return false if @sleeping[id] || @in_flight[id].positive?
        return false if @clock.call - (@last_activity[id] ||= @clock.call) < threshold

        @sleeping[id] = true
      end
      begin
        yield
      ensure
        @mutex.synchronize { @sleeping.delete(id) }
      end
    end

    def forget(id)
      @mutex.synchronize do
        @last_activity.delete(id)
        @in_flight.delete(id)
        @sleeping.delete(id)
      end
    end

    private

    def release(lease, id, counted)
      @mutex.synchronize do
        return false unless lease.mark_released!

        @in_flight[id] -= 1
        @in_flight.delete(id) if @in_flight[id] <= 0
        @last_activity[id] = @clock.call if counted
        true
      end
    end
  end
end
