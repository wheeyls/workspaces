require_relative 'spec_helper'

RSpec.describe Workspaces::Sleeper do
  let(:now) { [0.0] }
  let(:tracker) { Workspaces::ActivityTracker.new(clock: -> { now.first }) }
  let(:coordinator) { instance_double(Workspaces::Coordinator, sleep_candidates: %w(a b), sleep!: true, reconcile_sleep: nil) }
  let(:sleeper) { described_class.new(coordinator: coordinator, tracker: tracker, threshold: 60, interval: 1) }

  it 'puts only idle workspaces to sleep' do
    tracker.touch('a')
    tracker.touch('b')
    now[0] = 50
    tracker.touch('b')
    now[0] = 70

    expect(sleeper.sweep).to eq(['a'])
    expect(coordinator).to have_received(:sleep!).with('a')
    expect(coordinator).not_to have_received(:sleep!).with('b')
  end

  it 'does not sleep a workspace with a request in flight' do
    lease = tracker.acquire('a')
    tracker.touch('b')
    now[0] = 1000

    expect(sleeper.sweep).to eq(['b'])
    lease.release
  end

  it 'does not count a workspace as slept when the coordinator declined' do
    allow(coordinator).to receive(:sleep!).and_return(false)
    tracker.touch('a')
    now[0] = 100

    expect(sleeper.sweep).to eq([])
  end

  it 'keeps sweeping the others when one fails' do
    allow(coordinator).to receive(:sleep!).with('a').and_raise(Errno::EPERM)
    tracker.touch('a')
    tracker.touch('b')
    now[0] = 100

    expect { expect(sleeper.sweep).to eq(['b']) }.to output(/could not put a to sleep/).to_stderr
  end

  it 'is inert when sleeping is switched off' do
    off = described_class.new(coordinator: coordinator, tracker: tracker, threshold: nil)

    expect(off.start).to eq(off)
    expect(off.sweep).to eq([])
    expect(coordinator).not_to have_received(:reconcile_sleep)
  end

  it 'reconciles once and then sweeps on a timer' do
    tracker.touch('a')
    now[0] = 100
    sleeper.start
    sleep 1.4
    sleeper.stop

    expect(coordinator).to have_received(:reconcile_sleep).once
    expect(coordinator).to have_received(:sleep!).with('a').at_least(:once)
  end
end
