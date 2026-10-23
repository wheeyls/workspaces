require_relative 'spec_helper'

RSpec.describe Workspaces::ActivityTracker do
  let(:now) { [100.0] }
  let(:tracker) { described_class.new(clock: -> { now.first }) }

  def advance(seconds)
    now[0] += seconds
  end

  it 'starts the idle clock when a workspace is first seen and resets it on activity' do
    expect(tracker.idle_for('ws')).to eq(0)
    advance(50)
    expect(tracker.idle_for('ws')).to eq(50)
    tracker.touch('ws')
    expect(tracker.idle_for('ws')).to eq(0)
  end

  it 'does not sleep a workspace before the threshold' do
    tracker.touch('ws')
    advance(59)

    expect(tracker.sleep_if_idle('ws', 60) { :slept }).to be(false)
    advance(1)
    expect(tracker.sleep_if_idle('ws', 60) { :slept }).to eq(:slept)
  end

  it 'counts a request as activity when it is accepted and again when it finishes' do
    lease = tracker.acquire('ws')
    advance(40)
    lease.release
    advance(40)

    expect(tracker.idle_for('ws')).to eq(40)
  end

  it 'never sleeps a workspace with a request in flight, however long it has been quiet' do
    lease = tracker.acquire('ws')
    advance(10_000)

    expect(tracker.in_flight('ws')).to eq(1)
    expect(tracker.sleep_if_idle('ws', 60) { :slept }).to be(false)
    lease.release
    advance(60)
    expect(tracker.sleep_if_idle('ws', 60) { :slept }).to eq(:slept)
  end

  it 'releases a lease only once' do
    lease = tracker.acquire('ws')
    2.times { lease.release }

    expect(tracker.in_flight('ws')).to eq(0)
    expect(tracker.acquire('ws')).not_to be_nil
    expect(tracker.in_flight('ws')).to eq(1)
  end

  it 'lets uncounted traffic hold a lease without resetting the idle clock' do
    tracker.touch('ws')
    advance(30)
    lease = tracker.acquire('ws', counted: false)
    advance(30)
    lease.release

    expect(tracker.idle_for('ws')).to eq(60)
  end

  it 'refuses new requests while a sleep is in progress and accepts them afterwards' do
    tracker.touch('ws')
    advance(60)
    during = nil
    tracker.sleep_if_idle('ws', 60) { during = tracker.acquire('ws') }

    expect(during).to be_nil
    expect(tracker.acquire('ws')).not_to be_nil
  end

  it 'does not let a request slip between the idle check and the stop' do
    tracker.touch('ws')
    advance(60)
    started = Queue.new
    proceed = Queue.new
    sleeper = Thread.new do
      tracker.sleep_if_idle('ws', 60) do
        started << true
        proceed.pop
        :slept
      end
    end
    started.pop
    lease = nil
    requester = Thread.new { lease = tracker.acquire('ws') }
    sleep 0.05
    proceed << true

    expect(sleeper.value).to eq(:slept)
    requester.join
    expect(lease).to be_nil
  end

  it 'forgets a workspace' do
    tracker.acquire('ws')
    advance(5)
    tracker.forget('ws')

    expect(tracker.in_flight('ws')).to eq(0)
    expect(tracker.idle_for('ws')).to eq(0)
  end
end
