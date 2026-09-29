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
end
