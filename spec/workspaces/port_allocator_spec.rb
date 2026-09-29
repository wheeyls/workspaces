require_relative 'spec_helper'

RSpec.describe Workspaces::PortAllocator do
  it 'rejects a real occupied loopback port' do
    TCPServer.open('127.0.0.1', 0) do |server|
      port = server.addr[1]
      expect(described_class.free?(port)).to be(false)
      expect { described_class.allocate(port..port, []) }.to raise_error(described_class::NoFreePortError)
    end
  end
end
