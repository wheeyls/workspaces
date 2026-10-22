require_relative 'spec_helper'

# Real runs: real recipe, real steps, a real background server process. Nothing here is stubbed,
# because the point is that finished steps are not executed again.
RSpec.describe Workspaces::Coordinator, 're-running part of a run' do
  before do
    repository
    write_recipe
  end

  after { Workspaces::Backend.new(workspace.id).stop! }

  let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }
  let(:coordinator) { described_class.new }
  let(:state) { Workspaces::StateStore.new(Workspaces::Config.state_file) }
  let(:marks) { Workspaces::Config.home.join('marks') }

  def mark(name)
    marks.join(name)
  end

  def runs(name)
    mark(name).exist? ? mark(name).read.lines.size : 0
  end

  # Each step appends a line to its own file, so a count says how often it really ran. Readiness
  # fails while the `fail-ready` flag exists, and the flag is removed by the test, not the step.
  def write_recipe
    FileUtils.mkdir_p(marks_dir = Workspaces::Config.home.join('marks'))
    step = lambda do |id, name, extra = ''|
      { 'id' => id, 'name' => name,
        'run' => ['ruby', '-e', %(File.open("#{marks_dir}/#{id}", "a") { |f| f.puts "x" }; #{extra})] }
    end
    ready = step.call('ready', 'Readiness',
                      %(exit(File.exist?("#{marks_dir}/fail-ready") ? 1 : 0)))
    recipe = { 'version' => 1, 'steps' => [
      step.call('setup', 'Install'), step.call('assets', 'Assets', %(exit(1) if File.exist?("#{marks_dir}/fail-assets"))),
      { 'id' => 'app', 'name' => 'Server', 'run' => ['ruby', '-e', %(File.open("#{marks_dir}/app", "a") { |f| f.puts "x" }; sleep 120)],
        'background' => true },
      ready
    ] }
    File.write(Workspaces::Config.repo_root.join('.workspaces.yml'), YAML.dump(recipe))
  end

  def step_states
    coordinator.snapshot(workspace.id)['steps'].to_h { |step| [step['key'], step['state']] }
  end

  def fail_ready_then_start
    FileUtils.touch(mark('fail-ready'))
    coordinator.start(workspace.id, force: true)
    expect(coordinator.wait(workspace.id)['status']).to eq('error')
  end

  it 'retries a failed readiness check without running setup or assets again' do
    fail_ready_then_start
    expect(step_states).to eq('setup' => 'complete', 'assets' => 'complete', 'app' => 'complete', 'ready' => 'failed')
    expect(Workspaces::Backend.new(workspace.id).running?).to be_falsey

    FileUtils.rm(mark('fail-ready'))
    expect(coordinator.rerun(workspace.id)).to be(true)
    snapshot = coordinator.wait(workspace.id)

    expect(snapshot['status']).to eq('ready')
    expect(step_states.values).to all(eq('complete'))
    expect([runs('setup'), runs('assets')]).to eq([1, 1])
    expect([runs('app'), runs('ready')]).to eq([2, 2])
    expect(Workspaces::Backend.new(workspace.id).running?).to be_truthy
  end

  it 'keeps the time and log of steps that finished earlier' do
    fail_ready_then_start
    before_steps = state.get(workspace.id)['steps'].to_h { |step| [step['key'], step['duration_seconds']] }
    FileUtils.rm(mark('fail-ready'))

    coordinator.rerun(workspace.id)
    after = coordinator.wait(workspace.id)['steps'].to_h { |step| [step['key'], step['duration_seconds']] }

    expect(after['setup']).to eq(before_steps['setup'])
    expect(after['assets']).to eq(before_steps['assets'])
    expect(Workspaces::Config.step_logs_dir(workspace.id).join('setup.log').read).to include('Install complete')
  end

  it 'retries from a failure in the middle, running the failed step and everything after it' do
    FileUtils.touch(mark('fail-assets'))
    coordinator.start(workspace.id, force: true)
    expect(coordinator.wait(workspace.id)['status']).to eq('error')
    expect(step_states).to include('setup' => 'complete', 'assets' => 'failed', 'app' => 'pending')

    FileUtils.rm(mark('fail-assets'))
    coordinator.rerun(workspace.id)

    expect(coordinator.wait(workspace.id)['status']).to eq('ready')
    expect([runs('setup'), runs('assets'), runs('app'), runs('ready')]).to eq([1, 2, 1, 1])
  end

  it 'records only the steps it re-ran in the build history' do
    fail_ready_then_start
    FileUtils.rm(mark('fail-ready'))
    coordinator.rerun(workspace.id)
    coordinator.wait(workspace.id)

    last = Workspaces::BuildHistory.records.select { |record| record['workspace_id'] == workspace.id }.last
    expect(last).to include('operation' => 'resume', 'result' => 'complete')
    expect(last['steps'].map { |step| step['id'] }).to eq(%w(app ready))
  end

  it 're-runs one step on a finished workspace while its server keeps running' do
    coordinator.start(workspace.id, force: true)
    expect(coordinator.wait(workspace.id)['status']).to eq('ready')
    pid = state.get(workspace.id)['pid']
    port = state.get(workspace.id)['port']

    expect(coordinator.rerun(workspace.id, mode: :only, key: 'assets')).to be(true)
    snapshot = coordinator.wait(workspace.id)

    expect(snapshot['status']).to eq('ready')
    expect([runs('setup'), runs('assets'), runs('app'), runs('ready')]).to eq([1, 2, 1, 1])
    expect(state.get(workspace.id).values_at('pid', 'port')).to eq([pid, port])
  end

  it 'leaves the server running when a single re-run step fails' do
    coordinator.start(workspace.id, force: true)
    coordinator.wait(workspace.id)
    pid = state.get(workspace.id)['pid']
    FileUtils.touch(mark('fail-assets'))

    coordinator.rerun(workspace.id, mode: :only, key: 'assets')

    expect(coordinator.wait(workspace.id)['status']).to eq('error')
    expect(state.get(workspace.id)['pid']).to eq(pid)
    expect(Workspaces::Backend.new(workspace.id).running?).to be_truthy
  end

  it 're-runs readiness against the same server and boot token after a full run' do
    coordinator.start(workspace.id, force: true)
    coordinator.wait(workspace.id)
    token = state.get(workspace.id)['run_id']
    expect(token).to match(/\A\h{48}\z/)

    coordinator.rerun(workspace.id, mode: :from, key: 'ready')
    coordinator.wait(workspace.id)

    expect(state.get(workspace.id)['run_id']).to eq(token)
    expect(runs('ready')).to eq(2)
  end

  it 'refuses, without changing anything, when the recipe no longer matches the recorded steps' do
    fail_ready_then_start
    recipe_path = Workspaces::Config.repo_root.join('.workspaces.yml')
    recipe = YAML.safe_load(recipe_path.read)
    recipe['steps'].insert(1, { 'id' => 'extra', 'name' => 'Extra', 'run' => ['ruby', '-e', '1'] })
    File.write(recipe_path, YAML.dump(recipe))
    recorded = state.get(workspace.id)['steps']

    expect { coordinator.rerun(workspace.id) }.to raise_error(ArgumentError, /no longer match/)

    expect(state.get(workspace.id)['steps']).to eq(recorded)
    expect(coordinator.snapshot(workspace.id)['active']).to be(false)
    expect(coordinator.snapshot(workspace.id)['resume']).to be_nil
  end

  it 'releases the lock when the request is refused' do
    expect { coordinator.rerun(workspace.id) }.to raise_error(ArgumentError)

    expect(coordinator.snapshot(workspace.id)['active']).to be(false)
  end

  it 'offers a retry after an interruption and continues from the interrupted step' do
    fail_ready_then_start
    state.set(workspace.id, 'status' => 'preparing')
    FileUtils.rm(mark('fail-ready'))

    snapshot = coordinator.snapshot(workspace.id)
    expect(snapshot['status']).to eq('interrupted')
    expect(snapshot['presentation']['actions'].first).to include('key' => 'resume', 'label' => 'Continue setup')

    coordinator.rerun(workspace.id)
    expect(coordinator.wait(workspace.id)['status']).to eq('ready')
    expect(runs('setup')).to eq(1)
  end

  it 'reports busy instead of starting a second run' do
    coordinator.start(workspace.id, force: true)
    coordinator.wait(workspace.id)
    result = nil
    Workspaces::Registry.new.with_lock(workspace.id) do
      result = coordinator.rerun(workspace.id, mode: :only, key: 'assets')
    end

    expect(result).to be(false)
  end
end
