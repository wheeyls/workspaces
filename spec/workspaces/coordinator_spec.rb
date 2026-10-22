require_relative 'spec_helper'

RSpec.describe Workspaces::Coordinator do
  before { repository }

  let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }

  it 'switches a running workspace preset before launching a restart' do
    path = Workspaces::Config.repo_root.join('.workspaces.yml')
    recipe = YAML.safe_load(path.read)
    recipe['default_editable_env'] = { 'APP_VARIANT' => 'www' }
    recipe['environment_presets'] = { 'Admin' => { 'APP_VARIANT' => 'admin' } }
    path.write(YAML.dump(recipe))
    overrides = Workspaces::EnvironmentOverrides.new(workspace.id)
    backend = instance_double(Workspaces::Backend, running?: true, resumable?: false)
    allow(Workspaces::Backend).to receive(:new).with(workspace.id).and_return(backend)
    workflow = instance_double(Workspaces::Workflow)
    allow(Workspaces::Workflow).to receive(:new).and_return(workflow)
    allow(workflow).to receive(:run!) do |restart:|
      expect(restart).to be(true)
      expect(overrides.editable_values(recipe['default_editable_env'])).to eq('APP_VARIANT' => 'admin')
      30123
    end

    coordinator = described_class.new
    expect(coordinator.restart(workspace.id, preset: 'Admin')).to be(true)
    expect(coordinator.wait(workspace.id)['steps']).to all(include('state' => 'pending'))
    expect(workflow).to have_received(:run!).with(restart: true)
  end

  it 'applies a preset before preparing a stopped workspace' do
    path = Workspaces::Config.repo_root.join('.workspaces.yml')
    recipe = YAML.safe_load(path.read)
    recipe['default_editable_env'] = { 'APP_VARIANT' => 'www' }
    recipe['environment_presets'] = { 'Admin' => { 'APP_VARIANT' => 'admin' } }
    path.write(YAML.dump(recipe))
    overrides = Workspaces::EnvironmentOverrides.new(workspace.id)
    backend = instance_double(Workspaces::Backend, running?: false, resumable?: false)
    allow(Workspaces::Backend).to receive(:new).with(workspace.id).and_return(backend)
    workflow = instance_double(Workspaces::Workflow)
    allow(Workspaces::Workflow).to receive(:new).and_return(workflow)
    allow(workflow).to receive(:run!) do |restart:|
      expect(restart).to be(false)
      expect(overrides.editable_values(recipe['default_editable_env'])).to eq('APP_VARIANT' => 'admin')
      30123
    end

    coordinator = described_class.new
    expect(coordinator.start(workspace.id, preset: 'Admin')).to be(true)
    expect(coordinator.wait(workspace.id)['steps']).to all(include('state' => 'pending'))
  end

  it 'does not overwrite settings for a missing preset or while workspace is busy' do
    path = Workspaces::Config.repo_root.join('.workspaces.yml')
    recipe = YAML.safe_load(path.read)
    recipe['default_editable_env'] = { 'APP_VARIANT' => 'www' }
    recipe['environment_presets'] = { 'Admin' => { 'APP_VARIANT' => 'admin' } }
    path.write(YAML.dump(recipe))
    overrides = Workspaces::EnvironmentOverrides.new(workspace.id)
    expect { described_class.new.start(workspace.id, preset: 'Missing') }
      .to raise_error(Workspaces::EnvironmentOverrides::Invalid, /Unknown environment preset/)
    expect(overrides.load).to eq({})
    Workspaces::Registry.new.with_lock(workspace.id) do
      expect(described_class.new.restart(workspace.id, preset: 'Admin')).to be(false)
    end
    expect(overrides.load).to eq({})
  end

  it 'requires restart when changing a running workspace through start' do
    path = Workspaces::Config.repo_root.join('.workspaces.yml')
    recipe = YAML.safe_load(path.read)
    recipe['default_editable_env'] = { 'APP_VARIANT' => 'www' }
    recipe['environment_presets'] = { 'Admin' => { 'APP_VARIANT' => 'admin' } }
    path.write(YAML.dump(recipe))
    workspace_id = workspace.id
    backend = instance_double(Workspaces::Backend, running?: true, resumable?: false)
    allow(Workspaces::Backend).to receive(:new).with(workspace_id).and_return(backend)

    expect { described_class.new.start(workspace_id, preset: 'Admin') }
      .to raise_error(ArgumentError, /restart --preset/)
    expect(Workspaces::EnvironmentOverrides.new(workspace_id).load).to eq({})
  end

  describe 'snapshot environment presets' do
    let(:defaults) { { 'APP_VARIANT' => 'www', 'ROUTING_SUBDOMAIN' => 'www', 'DEMO_MODE' => 'false' } }
    let(:presets) do
      { 'Seller preview' => { 'APP_VARIANT' => 'seller', 'ROUTING_SUBDOMAIN' => 'my' },
        'Demo preview' => { 'DEMO_MODE' => 'true' }, 'Default preview' => {} }
    end

    before do
      path = Workspaces::Config.repo_root.join('.workspaces.yml')
      recipe = YAML.safe_load(path.read)
      recipe.merge!('default_editable_env' => defaults, 'environment_presets' => presets,
                    'env' => { 'SERVICE_TOKEN' => 'recipe-private-value' })
      File.write(path, YAML.dump(recipe))
    end

    it 'completes each sparse preset with defaults without changing the editable environment' do
      snapshot = described_class.new.snapshot(workspace.id)

      expect(snapshot.fetch('environment_presets')).to eq(
        'Seller preview' => defaults.merge('APP_VARIANT' => 'seller', 'ROUTING_SUBDOMAIN' => 'my'),
        'Demo preview' => defaults.merge('DEMO_MODE' => 'true'),
        'Default preview' => defaults
      )
      expect(snapshot.fetch('editable_environment')).to eq(defaults)
      expect(snapshot.to_json).not_to include('recipe-private-value')
      expect(Workspaces::Config.home.join('environment')).not_to exist
    end

    it 'ignores saved overrides in presets and leaves legacy and editable storage unchanged' do
      id = workspace.id
      overrides = Workspaces::EnvironmentOverrides.new(id)
      overrides.replace_editable("DEMO_MODE=true\nCUSTOM_FLAG=custom\n", defaults: defaults)
      overrides.apply_patch(set: { 'APP_VARIANT' => 'legacy', 'SERVICE_TOKEN' => 'legacy-private-value',
                                   'HIDDEN_SETTING' => 'hidden-legacy-value' }, remove: [])
      paths = Workspaces::Config.home.join('environment').children
      stored = paths.to_h { |path| [path, [path.read, path.mtime]] }
      coordinator = described_class.new
      expect(coordinator).not_to receive(:start)
      expect(coordinator).not_to receive(:restart)

      snapshot = coordinator.snapshot(id)

      expect(snapshot.fetch('environment_presets')).to eq(
        'Seller preview' => defaults.merge('APP_VARIANT' => 'seller', 'ROUTING_SUBDOMAIN' => 'my'),
        'Demo preview' => defaults.merge('DEMO_MODE' => 'true'),
        'Default preview' => defaults
      )
      expect(snapshot.fetch('editable_environment')).to eq(
        defaults.merge('APP_VARIANT' => 'legacy', 'DEMO_MODE' => 'true', 'CUSTOM_FLAG' => 'custom')
      )
      expect(snapshot.to_json).not_to include('legacy-private-value', 'hidden-legacy-value', 'recipe-private-value')
      expect(paths.to_h { |path| [path, [path.read, path.mtime]] }).to eq(stored)
      expect(Workspaces::Config.home.join('environment').children).to match_array(paths)
    end

    it 'reads presets from the trusted source recipe rather than the workspace checkout' do
      File.write(workspace.path.join('.workspaces.yml'), YAML.dump('version' => 'untrusted'))

      expect(described_class.new.snapshot(workspace.id).fetch('environment_presets')).to include(
        'Demo preview' => defaults.merge('DEMO_MODE' => 'true')
      )
    end

    it 'returns no presets for older recipes while retaining editable defaults' do
      path = Workspaces::Config.repo_root.join('.workspaces.yml')
      recipe = YAML.safe_load(path.read)
      recipe.delete('environment_presets')
      File.write(path, YAML.dump(recipe))

      expect(described_class.new.snapshot(workspace.id)).to include(
        'environment_presets' => {}, 'editable_environment' => defaults
      )
    end

    it 'returns empty environment maps when the trusted recipe is invalid' do
      File.write(Workspaces::Config.repo_root.join('.workspaces.yml'), YAML.dump('version' => 'invalid'))

      expect(described_class.new.snapshot(workspace.id)).to include(
        'environment_presets' => {}, 'editable_environment' => {}
      )
    end
  end

  it 'seeds nil durations before prepare and restart workers and preserves persisted timings in snapshots' do
    state = Workspaces::StateStore.new(Workspaces::Config.state_file)
    backend = instance_double(Workspaces::Backend, running?: true, resumable?: false)
    allow(Workspaces::Backend).to receive(:new).with(workspace.id).and_return(backend)
    workflow = instance_double(Workspaces::Workflow)
    allow(Workspaces::Workflow).to receive(:new).and_return(workflow)
    allow(workflow).to receive(:run!) do |restart:|
      steps = state.get(workspace.id)['steps']
      expect(steps.map { |step| step['key'] }).to eq(restart ? %w(app ready) : %w(setup app ready))
      expect(steps).to all(include('state' => 'pending', 'duration_seconds' => nil))
      steps.each { |step| step.merge!('state' => 'complete', 'duration_seconds' => 1.234) }
      state.set(workspace.id, 'steps' => steps)
      30123
    end
    coordinator = described_class.new

    expect(coordinator.start(workspace.id, force: true)).to be(true)
    expect(coordinator.wait(workspace.id)['steps']).to all(include('duration_seconds' => 1.234))
    expect(coordinator.restart(workspace.id)).to be(true)
    expect(coordinator.wait(workspace.id)['steps']).to all(include('duration_seconds' => 1.234))
    expect(described_class.new.snapshot(workspace.id)['steps']).to eq(state.get(workspace.id)['steps'])
  end

  it 'prepares and restarts without changing branch, fetching, or cleaning agent work' do
    File.write(workspace.path.join('tracked.txt'), 'edited')
    File.write(workspace.path.join('scratch.txt'), 'untracked')
    backend = instance_double(Workspaces::Backend, running?: true, resumable?: false)
    allow(Workspaces::Backend).to receive(:new).with(workspace.id).and_return(backend)
    workflow = instance_double(Workspaces::Workflow, run!: 30123)
    allow(Workspaces::Workflow).to receive(:new).and_return(workflow)
    coordinator = described_class.new
    expect(coordinator.start(workspace.id, force: true)).to be(true)
    expect(coordinator.wait(workspace.id)['status']).to eq('ready')
    expect(coordinator.restart(workspace.id)).to be(true)
    expect(coordinator.wait(workspace.id)['status']).to eq('ready')
    expect(workflow).to have_received(:run!).with(restart: false).once
    expect(workflow).to have_received(:run!).with(restart: true).once
    expect(workspace.path.join('tracked.txt').read).to eq('edited')
    expect(workspace.path.join('scratch.txt').read).to eq('untracked')
    expect(workspace.describe['branch']).to eq("workspaces/#{workspace.id}")
  end

  it 'reports preparation failures and releases the lock' do
    backend = instance_double(Workspaces::Backend, stop!: nil, running?: false, resumable?: false)
    allow(Workspaces::Backend).to receive(:new).and_return(backend)
    allow(Workspaces::Workflow).to receive(:new).and_raise('token=secret install failed')
    coordinator = described_class.new
    coordinator.start(workspace.id)
    snapshot = coordinator.wait(workspace.id)
    expect(snapshot['status']).to eq('error')
    expect(snapshot['active']).to be(false)
    expect(snapshot['last_error']).not_to include('secret')
  end

  it 'reports saved environment key names without exposing values in snapshots' do
    Workspaces::EnvironmentOverrides.new(workspace.id).apply_patch(set: { 'APP_VARIANT' => 'secret-value' }, remove: [])

    snapshot = described_class.new.snapshot(workspace.id)

    expect(snapshot['environment_keys']).to eq(['APP_VARIANT'])
    expect(snapshot.to_json).not_to include('secret-value')
  end

  it 'reads only the selected log, bounds and scrubs backend output, and rejects unknown sources' do
    id = workspace.id
    File.write(Workspaces::Config.setup_log_path(id), "setup only\n")
    File.write(Workspaces::Config.backend_log_path(id), "ignored\n" * 120 + "token=private backend only\n")
    coordinator = described_class.new

    expect(coordinator.snapshot(id)).to include('log_source' => 'setup', 'log_tail' => "setup only\n")
    tail = coordinator.snapshot(id, log: 'backend').fetch('log_tail')
    expect(tail).to include('token=[FILTERED]', 'backend only')
    expect(tail).not_to include('setup only', 'token=private')
    expect(tail.lines.length).to be <= Workspaces::Config::SAFE_LOG_LINES
    expect(coordinator.snapshot(id, include_log: false)['log_tail']).to eq('')
    expect { coordinator.snapshot(id, log: 'wrong') }.to raise_error(ArgumentError, /Unknown workspace log/)
  end

  it 'reads only the selected log, bounds and scrubs backend output, and rejects unknown sources' do
    id = workspace.id
    setup_path = Workspaces::Config.setup_log_path(id)
    backend_path = Workspaces::Config.backend_log_path(id)
    File.write(setup_path, "setup only\n")
    File.write(backend_path, "ignored\n" * 120 + "token=private backend only\n")
    coordinator = described_class.new

    expect(coordinator.snapshot(id)).to include('log_source' => 'setup', 'log_tail' => "setup only\n")
    expect(coordinator.snapshot(id, log: 'backend')).to include('log_source' => 'backend')
    tail = coordinator.snapshot(id, log: 'backend').fetch('log_tail')
    expect(tail).to include('token=[FILTERED]', 'backend only')
    expect(tail).not_to include('setup only', 'token=private')
    expect(tail.lines.length).to be <= Workspaces::Config::SAFE_LOG_LINES
    expect(coordinator.snapshot(id, include_log: false)['log_tail']).to eq('')
    expect { coordinator.snapshot(id, log: 'wrong') }.to raise_error(ArgumentError, /Unknown workspace log/)
  end

  describe 'total run time' do
    def run_once(recipe_steps)
      path = Workspaces::Config.repo_root.join('.workspaces.yml')
      recipe = YAML.safe_load(path.read)
      recipe['steps'] = recipe_steps
      path.write(YAML.dump(recipe))
      coordinator = described_class.new
      coordinator.start(workspace.id)
      coordinator.wait(workspace.id)
    end

    it 'persists the wall-clock time of a finished run, covering more than the steps alone' do
      snapshot = run_once([{ 'id' => 'wait', 'name' => 'Wait', 'run' => ['ruby', '-e', 'sleep 0.3'] },
                           { 'id' => 'app', 'name' => 'App', 'run' => ['ruby', '-e', 'sleep 30'], 'background' => true },
                           { 'id' => 'ready', 'name' => 'Ready', 'run' => ['ruby', '-e', 'puts 1'] }])

      expect(snapshot['status']).to eq('ready')
      step_total = snapshot['steps'].sum { |step| step['duration_seconds'] }
      expect(snapshot['total_seconds']).to be >= 0.3
      # Step durations are each rounded to the millisecond, so allow for that rounding.
      expect(snapshot['total_seconds']).to be >= step_total - 0.01
      expect(Workspaces::StateStore.new(Workspaces::Config.state_file).get(workspace.id)['total_seconds'])
        .to eq(snapshot['total_seconds'])
    ensure
      Workspaces::Backend.new(workspace.id).stop!
    end

    it 'persists the time a failed run took before it stopped' do
      snapshot = run_once([{ 'id' => 'boom', 'name' => 'Boom', 'run' => ['ruby', '-e', 'sleep 0.2; exit 3'] },
                           { 'id' => 'app', 'name' => 'App', 'run' => ['ruby', '-e', 'sleep 30'], 'background' => true },
                           { 'id' => 'ready', 'name' => 'Ready', 'run' => ['ruby', '-e', 'puts 1'] }])

      expect(snapshot['status']).to eq('error')
      expect(snapshot['total_seconds']).to be >= 0.2
    end

    it 'clears the previous total when a new run starts' do
      Workspaces::StateStore.new(Workspaces::Config.state_file)
                            .set(workspace.id, 'status' => 'ready', 'total_seconds' => 99.0)
      registry_lock = Workspaces::Registry.new
      registry_lock.with_lock(workspace.id) { nil }

      coordinator = described_class.new
      allow(coordinator).to receive(:spawn_worker)
      coordinator.start(workspace.id, force: true)

      expect(Workspaces::StateStore.new(Workspaces::Config.state_file).get(workspace.id)['total_seconds']).to be_nil
    end
  end

  describe 'build history and progress estimates' do
    def run_recipe(steps)
      path = Workspaces::Config.repo_root.join('.workspaces.yml')
      recipe = YAML.safe_load(path.read)
      recipe['steps'] = steps
      path.write(YAML.dump(recipe))
      coordinator = described_class.new
      coordinator.start(workspace.id)
      coordinator.wait(workspace.id)
    end

    let(:passing) do
      [{ 'id' => 'setup', 'name' => 'Setup', 'run' => ['ruby', '-e', 'sleep 0.1'] },
       { 'id' => 'app', 'name' => 'App', 'run' => ['ruby', '-e', 'sleep 30'], 'background' => true },
       { 'id' => 'ready', 'name' => 'Ready', 'run' => ['ruby', '-e', 'puts 1'] }]
    end

    after { Workspaces::Backend.new(workspace.id).stop! }

    it 'records every successful run, with the time of each step' do
      run_recipe(passing)

      line = JSON.parse(Workspaces::Config.build_history_path.read.lines.last)
      expect(line).to include('workspace_id' => workspace.id, 'result' => 'complete', 'operation' => 'prepare')
      expect(line['steps'].map { |s| s['id'] }).to eq(%w(setup app ready))
      expect(line['steps']).to all(include('state' => 'complete', 'seconds' => be_a(Numeric)))
      expect(line['total_seconds']).to be >= 0.1
    end

    it 'records a failed run too, but keeps it out of the averages' do
      run_recipe([{ 'id' => 'setup', 'name' => 'Setup', 'run' => ['ruby', '-e', 'exit 3'] }] + passing.drop(1))

      line = JSON.parse(Workspaces::Config.build_history_path.read.lines.last)
      expect(line).to include('result' => 'failed')
      expect(line['steps'].first).to include('id' => 'setup', 'state' => 'failed')
      expect(Workspaces::BuildHistory.estimates(%w(setup))).to eq({})
    end

    it 'learns from each successful build, and the next run is given those averages up front' do
      run_recipe(passing)
      expect(Workspaces::BuildHistory.estimates(%w(setup app ready)).keys).to match_array(%w(setup app ready))

      allow_any_instance_of(described_class).to receive(:spawn_worker)
      later = described_class.new
      later.start(workspace.id, force: true)

      stored = Workspaces::StateStore.new(Workspaces::Config.state_file).get(workspace.id)
      expect(stored['estimates'].keys).to match_array(%w(setup app ready))
      expect(later.snapshot(workspace.id)['estimates']).to eq(stored['estimates'])
    end

    it 'carries progress in the snapshot only while a build is being prepared' do
      allow_any_instance_of(described_class).to receive(:spawn_worker)
      coordinator = described_class.new
      coordinator.start(workspace.id)

      progress = coordinator.snapshot(workspace.id).dig('presentation', 'progress')
      expect(progress).to include('percent' => 0, 'step_text' => 'Step 1 of 3')

      Workspaces::StateStore.new(Workspaces::Config.state_file).set(workspace.id, 'status' => 'ready')
      expect(coordinator.snapshot(workspace.id).dig('presentation', 'progress')).to be_nil
    end

    it 'does not break a build when the history cannot be written' do
      Workspaces::Config.build_history_path.dirname.mkpath
      Workspaces::Config.build_history_path.mkdir

      snapshot = nil
      expect { snapshot = run_recipe(passing) }.to output(/build history not recorded/).to_stderr
      expect(snapshot['status']).to eq('ready')
    end
  end

  describe 'step logs in the snapshot' do
    let(:steps) do
      [{ 'key' => 'gems', 'label' => 'Gems', 'state' => 'complete', 'duration_seconds' => 1.0 },
       { 'key' => 'ready', 'label' => 'Ready', 'state' => 'pending', 'duration_seconds' => nil }]
    end

    before do
      Workspaces::StateStore.new(Workspaces::Config.state_file).set(workspace.id, 'status' => 'stopped', 'steps' => steps)
    end

    it 'includes a bounded, scrubbed tail for each step that has output, and none for steps that have not run' do
      Workspaces::Config.step_log_path(workspace.id, 'gems').write("old\n" * 200 + "token=private-step\nlast line\n")

      logs = described_class.new.snapshot(workspace.id).fetch('step_logs')

      expect(logs.keys).to eq(['gems'])
      expect(logs['gems']['text']).to include('token=[FILTERED]', 'last line')
      expect(logs['gems']['text']).not_to include('private-step')
      expect(logs['gems']['text'].lines.length).to be <= Workspaces::Config::STEP_LOG_LINES
      expect(logs['gems']['truncated']).to eq(true)
    end

    it 'reports truncated false for a short step log' do
      Workspaces::Config.step_log_path(workspace.id, 'gems').write("short\n")

      expect(described_class.new.snapshot(workspace.id).dig('step_logs', 'gems'))
        .to eq('text' => "short\n", 'truncated' => false)
    end

    it 'leaves step logs out of the backend view and out of status calls that skip logs' do
      Workspaces::Config.step_log_path(workspace.id, 'gems').write("x\n")
      coordinator = described_class.new

      expect(coordinator.snapshot(workspace.id, log: 'backend')['step_logs']).to eq({})
      expect(coordinator.snapshot(workspace.id, include_log: false)['step_logs']).to eq({})
    end

    it 'advertises the web server log only once the backend has written something' do
      coordinator = described_class.new
      expect(coordinator.snapshot(workspace.id)['backend_log_available']).to eq(false)

      Workspaces::Config.backend_log_path(workspace.id).write('')
      expect(coordinator.snapshot(workspace.id)['backend_log_available']).to eq(false)

      Workspaces::Config.backend_log_path(workspace.id).write("listening\n")
      expect(coordinator.snapshot(workspace.id)['backend_log_available']).to eq(true)
    end

    it 'ignores a step key that is not a safe slug instead of reading outside the log directory' do
      Workspaces::StateStore.new(Workspaces::Config.state_file)
                            .set(workspace.id, 'status' => 'stopped', 'steps' => [{ 'key' => '../x', 'label' => 'x', 'state' => 'complete' }])

      expect(described_class.new.snapshot(workspace.id)['step_logs']).to eq({})
    end
  end

  it 'serializes preparation and commands against the same per-workspace lock' do
    registry = Workspaces::Registry.new
    registry.with_lock(workspace.id) do
      expect(described_class.new.start(workspace.id)).to be(false)
      expect { registry.with_lock(workspace.id) {} }.to raise_error(ArgumentError, /busy/)
    end
  end

  it 'executes commands in the workspace with literal arguments and returns their exit status' do
    cli = Workspaces::Cli.new
    status = cli.run(['exec', workspace.id, '--', 'ruby', '-e', 'File.write("result.txt", ARGV.fetch(0)); exit 7',
                      'literal;not-shell'])
    expect(status).to eq(7)
    expect(workspace.path.join('result.txt').read).to eq('literal;not-shell')
  end

  it 'returns a machine-readable creation result and leaves it unprepared' do
    output = []
    allow_any_instance_of(Workspaces::Cli).to receive(:puts) { |_, text| output << text }
    expect(Workspaces::Cli.run(['create', '--branch', 'main', '--json'])).to eq(0)
    data = JSON.parse(output.join)
    expect(data).to include('id', 'path', 'branch', 'dashboard_url', 'preview_url')
    expect(Workspaces::StateStore.new(Workspaces::Config.state_file).get(data['id'])['status']).to eq('idle')
  end
end
