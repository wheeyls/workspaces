require_relative 'spec_helper'

RSpec.describe Workspaces::Coordinator do
  before { repository }

  let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }

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
    backend = instance_double(Workspaces::Backend, running?: true)
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
    backend = instance_double(Workspaces::Backend, running?: true)
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
    backend = instance_double(Workspaces::Backend, stop!: nil, running?: false)
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
