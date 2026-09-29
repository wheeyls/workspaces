require_relative 'spec_helper'

RSpec.describe Workspaces::Workflow do
  before { repository }

  let(:root) { Workspaces::Config.repo_root }
  let(:state) { Workspaces::StateStore.new(Workspaces::Config.state_file) }

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
      set: { 'APP_MODE' => 'override', 'ROUTING_SUBDOMAIN' => 'preview', 'UE_APP' => '${WORKSPACE_PORT}' },
      remove: []
    )

    provision = 'File.open("provisioned", "a") { |f| ' \
                'f.puts [ENV.fetch("APP_MODE"), ENV.fetch("UE_APP"), ENV.fetch("WORKSPACE_PORT")].join("|") }'
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
