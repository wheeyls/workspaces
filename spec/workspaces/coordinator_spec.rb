require_relative 'spec_helper'

RSpec.describe Workspaces::Coordinator do
  before { repository }

  let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }

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
