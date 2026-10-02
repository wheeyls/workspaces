require_relative 'spec_helper'

RSpec.describe Workspaces::Backend do
  let(:backend) { described_class.new('fixture-123') }
  let(:state) { Workspaces::StateStore.new(Workspaces::Config.state_file) }

  it 'does not report an exited child as running' do
    state.set('fixture-123', 'pid' => 456, 'port' => 30123)
    allow(Process).to receive(:waitpid).with(456, Process::WNOHANG).and_return(456)
    expect(backend.running?).to be(false)
  end

  it 'reserves distinct ports across workspace state before spawning' do
    first = backend.reserve!
    second = described_class.new('second-123').reserve!
    expect(first).not_to eq(second)
    expect(state.get('fixture-123')['port']).to eq(first)
  end

  it 'rejects a listener that claimed the port before launch' do
    TCPServer.open('127.0.0.1', 0) do |server|
      state.set('fixture-123', 'port' => server.addr[1])
      workspace = instance_double(Workspaces::Worktree)
      expect { backend.start!(workspace, ['ruby', '-e', 'sleep 1'], env: {}) }
        .to raise_error(described_class::BootFailedError, /occupied/)
    end
  end

  it 'stops an owned background process and releases its port' do
    root = Workspaces::Config.home.join('process')
    root.mkpath
    workspace = instance_double(Workspaces::Worktree, path: root)
    backend.reserve!
    backend.start!(workspace, ['ruby', '-e', 'sleep 30'], env: {})
    expect(backend).to be_running
    backend.stop!
    expect(backend).not_to be_running
    expect(backend.port).to be_nil
  ensure
    backend.stop!
  end

  it 'spawns background commands with workspace Bundler env instead of source Bundler env' do
    source_root = Workspaces::Config.home.join('source-bundle')
    write_path_marker_bundle(root: source_root, marker: 'source')

    workspace_root = Workspaces::Config.home.join('process-with-bundle')
    write_path_marker_bundle(root: workspace_root, marker: 'workspace')
    output_file = workspace_root.join('backend-marker.txt')
    workspace = instance_double(Workspaces::Worktree, path: workspace_root)

    backend.reserve!
    source_env = {
      'BUNDLE_GEMFILE' => source_root.join('Gemfile').to_s,
      'BUNDLE_LOCKFILE' => source_root.join('Gemfile.lock').to_s,
      'BUNDLER_ORIG_BUNDLE_GEMFILE' => source_root.join('Gemfile').to_s,
      'BUNDLER_ORIG_BUNDLE_LOCKFILE' => source_root.join('Gemfile.lock').to_s,
      'BUNDLER_ORIG_GEM_PATH' => '/tmp/orig-gem-path'
    }

    command = bundled_path_marker_command(output_path: output_file)
    ClimateControl.modify(source_env) do
      backend.start!(workspace, command, env: { 'APP_KEEP' => 'yes', 'APP_DELETE' => nil })
    end

    Timeout.timeout(5) { sleep 0.05 until output_file.exist? && !output_file.read.empty? }
    backend_output = output_file.read

    expect(backend_output).to include('marker=workspace')
    expect(backend_output).to include('nested=workspace')
    expect(backend_output).to include("gemfile=#{workspace_root.join('Gemfile')}")
    expect(backend_output).to include("lockfile=#{workspace_root.join('Gemfile.lock')}")
    expect(backend_output).to include('app_keep=yes')
    expect(backend_output).to include('app_delete=<unset>')
    expect(backend_output).not_to include('marker=source')
    expect(backend_output).not_to include(source_root.join('Gemfile').to_s)
    expect(backend_output).not_to include(source_root.join('Gemfile.lock').to_s)
  ensure
    backend.stop!
  end
end
