require_relative 'spec_helper'

RSpec.describe Workspaces::Worktree do
  let(:workspace) { described_class.new('auth-test') }

  it 'disables interactive Git authentication and identifies HTTPS credential failures' do
    failure = instance_double(Process::Status, success?: false)
    message = "fatal: could not read Username for 'https://github.com': terminal prompts disabled"
    allow(Open3).to receive(:capture2e).and_return([message, failure])

    expect { workspace.git!('fetch', 'origin') }.to raise_error(described_class::AuthenticationError)
    expect(Open3).to have_received(:capture2e).with(
      hash_including('GIT_TERMINAL_PROMPT' => '0', 'GIT_ASKPASS' => '/bin/false', 'GCM_INTERACTIVE' => 'Never'),
      'git', 'fetch', 'origin', chdir: Workspaces::Config.repo_root.to_s
    )
  end

  it 'does not misclassify missing refs as authentication failures' do
    failure = instance_double(Process::Status, success?: false)
    allow(Open3).to receive(:capture2e).and_return(['fatal: remote ref does not exist', failure])
    expect { workspace.git!('fetch', 'origin') }.to raise_error(described_class::CommandFailedError) do |error|
      expect(error).not_to be_a(described_class::AuthenticationError)
    end
  end
end
