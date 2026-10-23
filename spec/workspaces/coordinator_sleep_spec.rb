require_relative 'spec_helper'

# Real processes: the recipe's server is a real background process, so these show that sleeping
# stops it and waking starts it again without re-running the steps before it.
RSpec.describe Workspaces::Coordinator, 'sleeping and waking' do
  before do
    repository
    write_recipe
  end

  after { Workspaces::Backend.new(workspace.id).stop! }

  let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }
  let(:coordinator) { described_class.new }
  let(:state) { Workspaces::StateStore.new(Workspaces::Config.state_file) }
  let(:marks) { Workspaces::Config.home.join('marks') }

  def runs(name)
    marks.join(name).exist? ? marks.join(name).read.lines.size : 0
  end

  def write_recipe
    FileUtils.mkdir_p(marks_dir = Workspaces::Config.home.join('marks'))
    step = lambda do |id, name, extra = ''|
      { 'id' => id, 'name' => name,
        'run' => ['ruby', '-e', %(File.open("#{marks_dir}/#{id}", "a") { |f| f.puts "x" }; #{extra})] }
    end
    recipe = { 'version' => 1, 'steps' => [
      step.call('setup', 'Install'), step.call('assets', 'Assets'),
      { 'id' => 'app', 'name' => 'Server', 'run' => ['ruby', '-e', %(File.open("#{marks_dir}/app", "a") { |f| f.puts "x" }; sleep 120)],
        'background' => true },
      step.call('ready', 'Readiness', %(exit(File.exist?("#{marks_dir}/fail-ready") ? 1 : 0)))
    ] }
    File.write(Workspaces::Config.repo_root.join('.workspaces.yml'), YAML.dump(recipe))
  end

  def boot
    coordinator.start(workspace.id)
    expect(coordinator.wait(workspace.id)['status']).to eq('ready')
  end

  def server_pid
    state.get(workspace.id)['pid']
  end

  it 'stops the server of a ready workspace and reports it as asleep, keeping its record' do
    boot
    pid = server_pid
    steps_before = state.get(workspace.id)['steps']

    expect(coordinator.sleep!(workspace.id)).to be(true)

    snapshot = coordinator.snapshot(workspace.id)
    expect(snapshot).to include('status' => 'sleeping', 'sleeping' => true, 'running' => false, 'active' => false)
    expect(snapshot['presentation']['state']).to eq('sleeping')
    expect(Workspaces::Backend.new(workspace.id).running?).to be_falsey
    expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    expect(state.get(workspace.id)['steps']).to eq(steps_before)
    expect(workspace.path).to be_directory
  end

  it 'releases the whole process group, not only the leader' do
    boot
    group = state.get(workspace.id)['process_group']

    coordinator.sleep!(workspace.id)

    expect { Process.kill(0, -group) }.to raise_error(Errno::ESRCH)
  end

  it 'wakes by running only the server and readiness steps' do
    boot
    coordinator.sleep!(workspace.id)

    expect(coordinator.wake(workspace.id)).to be(true)
    snapshot = coordinator.wait(workspace.id)

    expect(snapshot['status']).to eq('ready')
    expect(snapshot['sleeping']).to be(false)
    expect(Workspaces::Backend.new(workspace.id).running?).to be_truthy
    expect([runs('setup'), runs('assets')]).to eq([1, 1])
    expect([runs('app'), runs('ready')]).to eq([2, 2])
    expect(coordinator.snapshot(workspace.id)['steps'].map { |step| step['key'] }).to eq(%w(app ready))
  end

  it 'runs the whole preparation again on wake when a step before the server changed' do
    boot
    coordinator.sleep!(workspace.id)
    path = Workspaces::Config.repo_root.join('.workspaces.yml')
    recipe = YAML.safe_load(path.read)
    recipe['steps'][0]['run'] = ['ruby', '-e', %(File.open("#{marks}/setup", "a") { |f| f.puts "changed" })]
    path.write(YAML.dump(recipe))

    coordinator.wake(workspace.id)

    expect(coordinator.wait(workspace.id)['status']).to eq('ready')
    expect(runs('setup')).to eq(2)
  end

  it 'starts only one server when several requests wake it at once' do
    boot
    coordinator.sleep!(workspace.id)

    results = Array.new(6) { Thread.new { coordinator.wake(workspace.id) } }.map(&:value)
    coordinator.wait(workspace.id)

    expect(results.count(true)).to eq(1)
    expect(runs('app')).to eq(2)
  end

  it 'does not wake a workspace that was stopped by hand' do
    boot
    coordinator.stop(workspace.id)

    expect(coordinator.sleeping?(workspace.id)).to be(false)
    expect(coordinator.wake(workspace.id)).to be(false)
    expect(coordinator.snapshot(workspace.id)['status']).to eq('stopped')
    expect(runs('app')).to eq(1)
  end

  it 'does not wake a workspace whose setup failed' do
    FileUtils.touch(marks.join('fail-ready'))
    coordinator.start(workspace.id)
    expect(coordinator.wait(workspace.id)['status']).to eq('error')

    expect(coordinator.wake(workspace.id)).to be(false)
    expect(coordinator.sleep!(workspace.id)).to be(false)
  end

  it 'reports a failed wake as an error and leaves nothing running or asleep' do
    boot
    coordinator.sleep!(workspace.id)
    FileUtils.touch(marks.join('fail-ready'))

    coordinator.wake(workspace.id)
    snapshot = coordinator.wait(workspace.id)

    expect(snapshot['status']).to eq('error')
    expect(snapshot['sleeping']).to be(false)
    expect(Workspaces::Backend.new(workspace.id).running?).to be_falsey
    expect(coordinator.wake(workspace.id)).to be(false)
  end

  it 'refuses to sleep a workspace that is kept awake, busy, or not running' do
    boot
    coordinator.keep_awake(workspace.id, true)
    expect(coordinator.sleep!(workspace.id)).to be(false)
    expect(coordinator.sleep_candidates).not_to include(workspace.id)
    expect(coordinator.snapshot(workspace.id)).to include('keep_awake' => true)

    coordinator.keep_awake(workspace.id, false)
    expect(coordinator.sleep_candidates).to include(workspace.id)
    Workspaces::Registry.new.with_lock(workspace.id) { expect(coordinator.sleep!(workspace.id)).to be(false) }
    expect(Workspaces::Backend.new(workspace.id).running?).to be_truthy
  end

  it 'refuses to start a wake while a lifecycle operation holds the workspace' do
    boot
    coordinator.sleep!(workspace.id)

    Workspaces::Registry.new.with_lock(workspace.id) { expect(coordinator.wake(workspace.id)).to be(false) }
    expect(coordinator.sleeping?(workspace.id)).to be(true)
  end

  it 'treats Start on a sleeping workspace as a wake, and a settings change as a restart' do
    boot
    coordinator.sleep!(workspace.id)

    expect(coordinator.start(workspace.id)).to be(true)
    coordinator.wait(workspace.id)
    expect(runs('setup')).to eq(1)
    expect(runs('app')).to eq(2)
  end

  it 'clears the sleeping state when the server is stopped, restarted or rebuilt' do
    boot
    coordinator.sleep!(workspace.id)
    coordinator.start(workspace.id, force: true)
    coordinator.wait(workspace.id)

    expect(state.get(workspace.id)['sleep_state']).to be_nil
    expect(runs('setup')).to eq(2)
  end

  describe 'after a front door restart' do
    it 'keeps a sleeping workspace asleep and does not start anything' do
      boot
      coordinator.sleep!(workspace.id)

      fresh = described_class.new
      fresh.reconcile_sleep

      expect(fresh.snapshot(workspace.id)['status']).to eq('sleeping')
      expect(Workspaces::Backend.new(workspace.id).running?).to be_falsey
    end

    it 'finishes a sleep that was cut off before the server stopped' do
      boot
      state.set(workspace.id, 'sleep_state' => 'sleeping', 'slept_at' => Time.now.utc.iso8601)
      expect(Workspaces::Backend.new(workspace.id).running?).to be_truthy

      described_class.new.reconcile_sleep

      expect(Workspaces::Backend.new(workspace.id).running?).to be_falsey
      expect(described_class.new.snapshot(workspace.id)['status']).to eq('sleeping')
    end

    it 'does not leave a workspace waking forever when its wake was cut off' do
      boot
      coordinator.sleep!(workspace.id)
      state.set(workspace.id, 'sleep_state' => 'waking', 'status' => 'preparing')

      fresh = described_class.new
      fresh.reconcile_sleep

      expect(fresh.sleep_phase(workspace.id)).to be_nil
      expect(fresh.snapshot(workspace.id)['status']).to eq('interrupted')
    end
  end

  it 'puts back the awake state when stopping the server fails' do
    boot
    allow_any_instance_of(Workspaces::Backend).to receive(:stop!).and_raise(Errno::EPERM)

    expect { coordinator.sleep!(workspace.id) }.to raise_error(Errno::EPERM)
    expect(state.get(workspace.id)['sleep_state']).to be_nil
    allow_any_instance_of(Workspaces::Backend).to receive(:stop!).and_call_original
  end

  it 'takes a hung server down with a forced kill within bounded time' do
    stubborn = Workspaces::Config.repo_root.join('stubborn.rb')
    stubborn.write(%(trap("TERM") {}; puts "up"; sleep 120))
    recipe_path = Workspaces::Config.repo_root.join('.workspaces.yml')
    recipe = YAML.safe_load(recipe_path.read)
    recipe['steps'][2]['run'] = ['ruby', stubborn.to_s]
    recipe_path.write(YAML.dump(recipe))
    boot
    pid = server_pid

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(coordinator.sleep!(workspace.id)).to be(true)

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 20
    expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
  end
end
