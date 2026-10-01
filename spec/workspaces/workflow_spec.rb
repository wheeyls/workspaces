require_relative 'spec_helper'

RSpec.describe Workspaces::Workflow do
  before { repository }

  let(:root) { Workspaces::Config.repo_root }
  let(:state) { Workspaces::StateStore.new(Workspaces::Config.state_file) }

  describe 'step timing' do
    let(:workspace) { double('workspace', id: 'timed-fixture', path: root) }
    let(:backend) { instance_double(Workspaces::Backend, stop!: nil, reserve!: 30123, port: 30123) }
    let(:runner) { instance_double(Workspaces::CommandRunner) }
    let(:log) { StringIO.new }
    let(:workflow) { described_class.new(workspace, log, state: state) }

    before do
      @clock = 100.0
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { @clock }
      allow(Workspaces::Backend).to receive(:new).with(workspace.id).and_return(backend)
      allow(Workspaces::CommandRunner).to receive(:new).with(root, log).and_return(runner)
      allow(runner).to receive(:run!) do |command, **_options|
        key = command.last.include?('setup') ? 'setup' : 'ready'
        expect(state.get(workspace.id)['steps'].find { |step| step['key'] == key })
          .to include('state' => 'active', 'duration_seconds' => nil)
        @clock += key == 'setup' ? 0.1236 : 1.25
      end
      allow(backend).to receive(:start!) do
        expect(state.get(workspace.id)['steps'][1]).to include('state' => 'active', 'duration_seconds' => nil)
        @clock += 0.5
      end
      allow(backend).to receive(:ensure_alive!) { @clock += 0.25 }
    end

    it 'persists rounded durations including liveness checks and logs each terminal step once' do
      expect(backend).to receive(:stop!) do
        expect(state.get(workspace.id)['steps']).to all(include('state' => 'pending', 'duration_seconds' => nil))
      end

      expect(workflow.run!).to eq(30123)

      steps = Workspaces::StateStore.new(Workspaces::Config.state_file).get(workspace.id)['steps']
      expect(steps).to match([
        include('key' => 'setup', 'state' => 'complete', 'duration_seconds' => 0.124),
        include('key' => 'app', 'state' => 'complete', 'duration_seconds' => 0.5),
        include('key' => 'ready', 'state' => 'complete', 'duration_seconds' => 1.5)
      ])
      expect(log.string.lines.grep(/\(\d+\.\d{3}s\)/)).to eq([
        "==> Fixture setup complete (0.124s)\n",
        "==> Fixture server complete (0.500s)\n",
        "==> Fixture readiness complete (1.500s)\n"
      ])
    end

    it 'records failed command time and leaves unexecuted steps pending without durations' do
      error = RuntimeError.new('command failed')
      allow(runner).to receive(:run!) { @clock += 2.3456; raise error }

      expect { workflow.run! }.to raise_error { |raised| expect(raised).to equal(error) }

      steps = state.get(workspace.id)['steps']
      expect(steps.first).to include('state' => 'failed', 'duration_seconds' => 2.346)
      expect(steps.drop(1)).to all(include('state' => 'pending', 'duration_seconds' => nil))
      expect(log.string.lines.grep(/\(\d+\.\d{3}s\)/)).to eq(["==> Fixture setup failed (2.346s)\n"])
      expect(backend).to have_received(:stop!).twice
    end

    it 'includes the liveness check in a failed readiness duration' do
      allow(backend).to receive(:ensure_alive!) { @clock += 0.75; raise 'backend exited' }

      expect { workflow.run! }.to raise_error(RuntimeError, 'backend exited')

      expect(state.get(workspace.id)['steps'].last).to include('state' => 'failed', 'duration_seconds' => 2.0)
      expect(log.string.lines.grep(/Fixture readiness (?:complete|failed)/))
        .to eq(["==> Fixture readiness failed (2.000s)\n"])
      expect(backend).to have_received(:stop!).twice
    end

    it 'records failed background launch time separately from pending readiness' do
      allow(backend).to receive(:start!) { @clock += 0.0625; raise 'launch failed' }

      expect { workflow.run! }.to raise_error(RuntimeError, 'launch failed')

      expect(state.get(workspace.id)['steps'][1]).to include('state' => 'failed', 'duration_seconds' => 0.063)
      expect(state.get(workspace.id)['steps'].last).to include('state' => 'pending', 'duration_seconds' => nil)
      expect(log.string.lines.grep(/Fixture server (?:complete|failed)/))
        .to eq(["==> Fixture server failed (0.063s)\n"])
    end

    it 'replaces previous timings on restart and measures only launch and readiness' do
      state.set(workspace.id, 'steps' => %w(setup app ready).map do |key|
        { 'key' => key, 'state' => 'complete', 'duration_seconds' => 99.0 }
      end)
      expect(backend).to receive(:stop!) do
        expect(state.get(workspace.id)['steps']).to match([
          include('key' => 'app', 'state' => 'pending', 'duration_seconds' => nil),
          include('key' => 'ready', 'state' => 'pending', 'duration_seconds' => nil)
        ])
      end
      allow(backend).to receive(:start!) { @clock += 0.5 }

      workflow.run!(restart: true)

      expect(state.get(workspace.id)['steps']).to match([
        include('key' => 'app', 'state' => 'complete', 'duration_seconds' => 0.5),
        include('key' => 'ready', 'state' => 'complete', 'duration_seconds' => 1.5)
      ])
      expect(runner).to have_received(:run!).once
      expect(log.string.lines.grep(/\(\d+\.\d{3}s\)/)).to eq([
        "==> Fixture server complete (0.500s)\n",
        "==> Fixture readiness complete (1.500s)\n"
      ])
    end
  end

  def install_recipe
    %w(server.rb ready.rb).each { |file| FileUtils.cp(File.join(__dir__, 'fixtures', file), root.join(file)) }
    root.join('.workspaces.yml').write(YAML.dump('version' => 1, 'steps' => fixture_steps))
    git('add', '.')
    git('-c', 'core.hooksPath=/dev/null', 'commit', '-m', 'Fixture commands')
  end

  def fixture_steps
    command = ['ruby', '-e', 'File.open("provisioned", "a") { |f| f.puts ENV.fetch("APP_MODE") }']
    [
      { 'id' => 'provision', 'name' => 'Provision fixture', 'run' => command, 'env' => { 'APP_MODE' => 'fixture' } },
      { 'id' => 'app', 'name' => 'Run socket server', 'run' => ['ruby', 'server.rb'], 'background' => true },
      { 'id' => 'ready', 'name' => 'Verify fixture identity', 'run' => ['ruby', 'ready.rb'], 'timeout' => 15 }
    ]
  end

  it 'provisions, proxies, restarts and stops a non-Rails repo through the real core' do
    install_recipe
    workspace = Workspaces::Registry.new.create(branch: 'main')
    backend = Workspaces::Backend.new(workspace.id)
    coordinator = Workspaces::Coordinator.new
    expect(coordinator.start(workspace.id)).to be(true)
    snapshot = coordinator.wait(workspace.id)
    expect(snapshot['status']).to eq('ready'), snapshot['last_error']
    expect(snapshot['steps']).to all(include('state' => 'complete'))
    expect(workspace.path.join('provisioned').read).to eq("fixture\n")
    env = Rack::MockRequest.env_for('http://localhost:4747/')
    env['HTTP_HOST'] = Workspaces::Config.preview_host(workspace.id)
    status, _, body = Workspaces::FrontDoor.new.call(env)
    expect(status).to eq(200)
    expect(body.join).to match(/\A[0-9a-f]{48}\z/)
    old_pid = state.get(workspace.id)['pid']
    coordinator.restart(workspace.id)
    expect(coordinator.wait(workspace.id)['status']).to eq('ready')
    expect(state.get(workspace.id)['pid']).not_to eq(old_pid)
    expect(workspace.path.join('provisioned').read).to eq("fixture\n")
    expect(coordinator.snapshot(workspace.id)['steps']).to match([include('key' => 'app'), include('key' => 'ready')])
    backend.stop!
    expect(backend).not_to be_running
  ensure
    backend&.stop!
  end

  it 'persists workspace environment overrides across restart and only changes non-runner variables' do
    install_recipe
    workspace = Workspaces::Registry.new.create(branch: 'main')
    Workspaces::EnvironmentOverrides.new(workspace.id).apply_patch(
      set: { 'APP_MODE' => 'override', 'APP_CHANNEL' => 'preview', 'APP_VARIANT' => '${WORKSPACE_PORT}' },
      remove: []
    )

    provision = 'File.open("provisioned", "a") { |f| ' \
                'f.puts [ENV.fetch("APP_MODE"), ENV.fetch("APP_VARIANT"), ENV.fetch("WORKSPACE_PORT")].join("|") }'
    root.join('.workspaces.yml').write(YAML.dump('version' => 1,
                                                 'env' => { 'APP_MODE' => 'global-default' },
                                                 'steps' => [
                                                   { 'id' => 'provision', 'name' => 'Provision fixture',
                                                     'run' => ['ruby', '-e', provision],
                                                     'env' => { 'APP_MODE' => 'fixture' } },
                                                   { 'id' => 'app', 'name' => 'Run socket server',
                                                     'run' => ['ruby', 'server.rb'], 'background' => true },
                                                   { 'id' => 'ready', 'name' => 'Verify fixture identity',
                                                     'run' => ['ruby', 'ready.rb'], 'timeout' => 15 }
                                                 ]))

    backend = Workspaces::Backend.new(workspace.id)
    coordinator = Workspaces::Coordinator.new
    expect(coordinator.start(workspace.id)).to be(true)
    coordinator.wait(workspace.id)
    expect(workspace.path.join('provisioned').read).to eq("override|${WORKSPACE_PORT}|#{backend.port}\n")

    coordinator.restart(workspace.id)
    coordinator.wait(workspace.id)
    expect(workspace.path.join('provisioned').read.lines.last).to eq("override|${WORKSPACE_PORT}|#{backend.port}\n")
  ensure
    backend&.stop!
  end

  it 'cleans up the server and reports the failed readiness step' do
    install_recipe
    recipe = YAML.safe_load(root.join('.workspaces.yml').read)
    recipe['steps'].last['run'] = ['ruby', '-e', 'warn "readiness failed"; exit 9']
    root.join('.workspaces.yml').write(YAML.dump(recipe))
    workspace = Workspaces::Registry.new.create(branch: 'main')
    coordinator = Workspaces::Coordinator.new
    coordinator.start(workspace.id)
    snapshot = coordinator.wait(workspace.id)
    expect(snapshot['status']).to eq('error')
    expect(snapshot['steps'].last['state']).to eq('failed')
    expect(snapshot['last_error']).to include('status 9')
    expect(snapshot['log_tail']).to include('readiness failed')
    expect(Workspaces::Backend.new(workspace.id)).not_to be_running
  end
end
