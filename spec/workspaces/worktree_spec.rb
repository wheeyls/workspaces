require_relative 'spec_helper'

RSpec.describe Workspaces::Worktree do
  before { repository }

  it 'creates independent branches from local refs without requiring any remote' do
    a = described_class.create(branch: 'main')
    b = described_class.create(branch: 'main')
    expect(a.id).not_to eq(b.id)
    expect(a.describe['branch']).to eq("workspaces/#{a.id}")
    expect(b.describe['branch']).to eq("workspaces/#{b.id}")
    expect(a.path.join('tracked.txt').read).to eq('baseline')
    expect(a.related_pr).to be_nil
    expect(a.dirty?).to be(false)
    expect(git('branch', '--show-current')).to eq('main')
  end

  it 'creates the explicitly named new branch from the chosen ref' do
    workspace = described_class.create(new_branch: 'agent/checkout', from: 'main')
    expect(workspace.describe['branch']).to eq('agent/checkout')
  end

  it 'allows many workspaces per PR and reconstructs associations from excluded metadata' do
    allow_any_instance_of(described_class).to receive(:resolve_pr).with('43828').and_return(
      'kind' => 'pr', 'repository' => 'g2crowd/ue', 'number' => 43828, 'branch' => 'feature', 'ref' => 'main'
    )
    first = described_class.create(pr: '43828')
    second = described_class.create(pr: '43828')
    expect(first.related_pr).to eq('repository' => 'g2crowd/ue', 'number' => 43828)
    expect(git('status', '--porcelain', cwd: first.path)).to eq('')
    workspaces = Workspaces::Registry.new.list(pr: '43828')
    expect(workspaces).to contain_exactly(include('id' => first.id), include('id' => second.id))
    git('add', '.', cwd: first.path)
    expect(git('diff', '--cached', '--name-only', cwd: first.path)).to eq('')
  end

  it 'refuses dirty removal unless explicitly forced and preserves branch history' do
    workspace = described_class.create(branch: 'main')
    File.write(workspace.path.join('new.txt'), 'agent work')
    expect { workspace.remove! }.to raise_error(ArgumentError, /uncommitted/)
    expect(workspace.path.join('new.txt').read).to eq('agent work')
    workspace.remove!(force: true)
    expect(workspace.path).not_to exist
    expect(git('branch', '--list', "workspaces/#{workspace.id}")).not_to eq('')
  end

  it 'rejects external worktrees and workspace-directory symlinks' do
    outside = Workspaces::Config.home.join('outside')
    outside.dirname.mkpath
    git('worktree', 'add', '--detach', outside.to_s, 'main')
    expect(Workspaces::Registry.new.list).to eq([])
    Workspaces::Config.worktrees_dir.mkpath
    File.symlink(outside, Workspaces::Config.worktrees_dir.join('outside'))
    expect { Workspaces::Registry.new.find('outside') }.to raise_error(ArgumentError)
  end

  it 'rejects unsafe IDs and conflicting creation selectors' do
    %w(../repo /tmp/other --help foo.bar).each { |id| expect { described_class.new(id) }.to raise_error(ArgumentError) }
    expect { described_class.create(branch: 'main', pr: '43828') }.to raise_error(ArgumentError)
    expect { described_class.create(branch: 'missing') }.to raise_error(described_class::CommandFailedError)
  end

  it 'resolves PR branch metadata and fetches only for explicit PR creation' do
    workspace = described_class.new('pr-43828-fixture')
    sha = git('rev-parse', 'HEAD')
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture2e).with('gh', 'pr', 'view', '43828', '--repo', 'fixture/example',
                                             '--json', 'headRefName,headRefOid', chdir: Workspaces::Config.repo_root.to_s)
                      .and_return([JSON.generate('headRefName' => 'feature/checkout', 'headRefOid' => sha), status])
    allow(workspace).to receive(:git!).with('fetch', 'origin', 'pull/43828/head').and_return('')
    source = workspace.send(:resolve_pr, '43828')
    expect(source).to include('number' => 43828, 'branch' => 'feature/checkout', 'ref' => sha)
    expect(workspace).to have_received(:git!).with('fetch', 'origin', 'pull/43828/head').once
  end

  it 'does not run repository checkout hooks while creating managed worktrees' do
    marker = Workspaces::Config.home.join('hook-executed')
    hooks = Workspaces::Config.home.join('hooks')
    hooks.mkpath
    File.write(hooks.join('post-checkout'), "#!/bin/sh\ntouch '#{marker}'\n")
    File.chmod(0o755, hooks.join('post-checkout'))
    git('config', 'core.hooksPath', hooks.to_s)
    workspace = described_class.create(branch: 'main')
    expect(workspace.exists?).to be(true)
    expect(marker).not_to exist
  end
end
