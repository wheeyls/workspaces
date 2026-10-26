require_relative 'spec_helper'

RSpec.describe Workspaces::ChildEnv do
  it 'never passes the vault master key to anything it starts, however it arrives' do
    env = described_class.for_workspace(
      workspace_path: '/tmp/ws', parent_env: { 'WORKSPACES_MASTER_KEY' => 'from-parent', 'KEEP' => '1' },
      extra_env: { 'WORKSPACES_MASTER_KEY' => 'from-recipe', 'ALSO' => '2' }
    )

    expect(env).not_to have_key('WORKSPACES_MASTER_KEY')
    expect(env).to include('KEEP' => '1', 'ALSO' => '2')
  end
end
