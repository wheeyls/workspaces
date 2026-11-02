require_relative 'spec_helper'

RSpec.describe Workspaces::WorkspaceLock do
  let(:id) { 'agent-1234' }

  def held?(id)
    described_class.held?(id)
  end

  it 'gives the lock to one taker at a time and frees it on close' do
    first = described_class.acquire(id, operation: 'exec')

    expect(first).not_to be_nil
    expect(described_class.acquire(id, operation: 'restart')).to be_nil
    first.close
    expect(described_class.acquire(id, operation: 'restart')).not_to be_nil
  end

  it 'records who holds the lock: operation, pid, start time and what it is doing' do
    lock = described_class.acquire(id, operation: 'exec', detail: 'bin/rails')

    expect(described_class.holder(id)).to include('operation' => 'exec', 'pid' => Process.pid, 'detail' => 'bin/rails')
    expect(Time.iso8601(described_class.holder(id).fetch('started_at'))).to be_within(5).of(Time.now)
    lock.close
  end

  it 'lets the holder add to its record' do
    lock = described_class.acquire(id, operation: 'exec')
    lock.update('child_pid' => 4242, 'timeout_seconds' => 900)

    expect(described_class.holder(id)).to include('operation' => 'exec', 'child_pid' => 4242, 'timeout_seconds' => 900)
    lock.close
  end

  it 'clears the record when the lock is released' do
    described_class.acquire(id, operation: 'exec').close

    expect(Workspaces::Config.prepare_lock_path(id).read).to eq('')
    expect(described_class.holder(id)).to be_nil
  end

  it 'ignores a record left behind by a holder that died, because nothing holds the lock' do
    Workspaces::Config.locks_dir.mkpath
    Workspaces::Config.prepare_lock_path(id).write(JSON.generate('operation' => 'exec', 'pid' => 1))

    expect(held?(id)).to be(false)
    expect(described_class.holder(id)).to be_nil
  end

  it 'reports no holder, not an error, when the record is unreadable' do
    lock = described_class.acquire(id, operation: 'exec')
    Workspaces::Config.prepare_lock_path(id).write('not json {')

    expect(described_class.holder(id)).to be_nil
    lock.close
  end

  it 'releases the lock when the holding process is killed outright, so nothing can be left stuck by a dead holder' do
    Workspaces::Config.locks_dir.mkpath
    reader, writer = IO.pipe
    holder = fork do
      reader.close
      lock = described_class.acquire(id, operation: 'exec')
      writer.puts(lock ? 'held' : 'refused')
      sleep 60
    end
    writer.close
    expect(reader.gets.to_s.strip).to eq('held')
    expect(held?(id)).to be(true)

    Process.kill('KILL', holder)
    Process.wait(holder)

    expect(held?(id)).to be(false)
    expect(described_class.acquire(id, operation: 'restart')).not_to be_nil
  end

  describe '.busy_message' do
    it 'stays generic when it cannot tell who holds the lock' do
      expect(described_class.busy_message(id)).to eq('Workspace is busy preparing, restarting, or running a command')
    end

    it 'names a running command, how long it has run, its pid and when it will be stopped' do
      now = Time.at(Time.now.to_i).utc
      lock = described_class.acquire(id, operation: 'exec', detail: 'bin/rails')
      lock.update('started_at' => (now - 125).iso8601, 'child_pid' => 4242, 'timeout_seconds' => 900)
      allow(Time).to receive(:now).and_return(now)

      message = described_class.busy_message(id)

      expect(message).to include('Workspace is busy', 'running a command', 'bin/rails', 'pid 4242', '2m 5s')
      expect(message).to include('stopped automatically after 15m 0s')
      lock.close
    end

    it 'says what a lifecycle operation is doing' do
      lock = described_class.acquire(id, operation: 'restart')

      expect(described_class.busy_message(id)).to match(/busy: restarting/)
      lock.close
    end

    it 'falls back to the raw name for an operation it does not know' do
      lock = described_class.acquire(id, operation: 'defrag')

      expect(described_class.busy_message(id)).to include('defrag')
      lock.close
    end
  end
end
