require_relative 'spec_helper'

RSpec.describe Workspaces::Registry do
  before do
    repository
    git('config', 'user.name', 'Fixture')
    git('config', 'user.email', 'fixture@example.test')
    git('remote', 'add', 'origin', Workspaces::Config.repo_root.to_s)
  end

  let(:registry) { described_class.new }

  def pr_workspace
    allow_any_instance_of(Workspaces::Worktree).to receive(:resolve_pr).and_return(
      'kind' => 'pr', 'repository' => 'example/project', 'number' => 43828,
      'branch' => 'feature', 'ref' => git('rev-parse', 'HEAD')
    )
    registry.create(pr: '43828')
  end

  def publish_change(content)
    File.write(Workspaces::Config.repo_root.join('tracked.txt'), content)
    git('add', 'tracked.txt')
    git('-c', 'core.hooksPath=/dev/null', 'commit', '-m', 'Update PR')
    git('update-ref', 'refs/pull/43828/head', git('rev-parse', 'HEAD'))
    git('rev-parse', 'HEAD')
  end

  it 'fast-forwards a PR checkout and preserves tracked, staged, and untracked edits' do
    workspace = pr_workspace
    File.write(workspace.path.join('local.txt'), 'staged work')
    git('add', 'local.txt', cwd: workspace.path)
    File.write(workspace.path.join('untracked.txt'), 'untracked work')
    head = publish_change('next version')

    result = registry.update_pr(workspace.id)

    expect(result).to include('updated' => true, 'head' => head)
    expect(git('rev-parse', 'HEAD', cwd: workspace.path)).to eq(head)
    expect(git('diff', '--cached', '--name-only', cwd: workspace.path)).to eq('local.txt')
    expect(workspace.path.join('untracked.txt').read).to eq('untracked work')
    expect(git('stash', 'list', cwd: workspace.path)).to eq('')
  end

  it 'does not touch a divergent checkout or stash its edits' do
    workspace = pr_workspace
    File.write(workspace.path.join('tracked.txt'), 'workspace commit')
    git('add', 'tracked.txt', cwd: workspace.path)
    git('-c', 'core.hooksPath=/dev/null', 'commit', '-m', 'Local commit', cwd: workspace.path)
    File.write(workspace.path.join('local.txt'), 'unsaved work')
    original = git('rev-parse', 'HEAD', cwd: workspace.path)
    publish_change('remote commit')

    expect { registry.update_pr(workspace.id) }.to raise_error(Workspaces::Worktree::UpdateError, /diverged/)
    expect(git('rev-parse', 'HEAD', cwd: workspace.path)).to eq(original)
    expect(workspace.path.join('local.txt').read).to eq('unsaved work')
    expect(git('stash', 'list', cwd: workspace.path)).to eq('')
  end

  it 'retains the stash when local edits conflict with the newly fetched PR head' do
    workspace = pr_workspace
    File.write(workspace.path.join('tracked.txt'), 'local version')
    publish_change('remote version')

    expect { registry.update_pr(workspace.id) }.to raise_error(Workspaces::Worktree::UpdateError, /retained/)
    expect(git('rev-parse', 'HEAD', cwd: workspace.path)).to eq(git('rev-parse', 'HEAD'))
    expect(git('stash', 'list', cwd: workspace.path)).to include("workspaces update #{workspace.id}")
    expect { registry.update_pr(workspace.id) }.to raise_error(Workspaces::Worktree::UpdateError, /retained/)
  end

  it 'does not create a stash when the PR head is unchanged' do
    workspace = pr_workspace
    File.write(workspace.path.join('tracked.txt'), 'local version')
    git('update-ref', 'refs/pull/43828/head', git('rev-parse', 'HEAD'))

    expect(registry.update_pr(workspace.id)).to include('updated' => false)
    expect(workspace.path.join('tracked.txt').read).to eq('local version')
    expect(git('stash', 'list', cwd: workspace.path)).to eq('')
  end

  it 'leaves the checkout and local edits alone if the PR fetch fails' do
    workspace = pr_workspace
    File.write(workspace.path.join('tracked.txt'), 'local version')
    original = git('rev-parse', 'HEAD', cwd: workspace.path)

    expect { registry.update_pr(workspace.id) }.to raise_error(Workspaces::Worktree::UpdateError, /Could not fetch/)
    expect(git('rev-parse', 'HEAD', cwd: workspace.path)).to eq(original)
    expect(workspace.path.join('tracked.txt').read).to eq('local version')
    expect(git('stash', 'list', cwd: workspace.path)).to eq('')
  end

  it 'preserves preexisting stashes when reapplying its own temporary stash' do
    workspace = pr_workspace
    File.write(workspace.path.join('tracked.txt'), 'existing stash')
    git('stash', 'push', '-m', 'existing user stash', cwd: workspace.path)
    File.write(workspace.path.join('local.txt'), 'new local work')
    publish_change('remote change')

    registry.update_pr(workspace.id)

    expect(workspace.path.join('local.txt').read).to eq('new local work')
    expect(git('stash', 'list', cwd: workspace.path)).to include('existing user stash')
    expect(git('stash', 'list', cwd: workspace.path)).not_to include("workspaces update #{workspace.id}")
  end

  it 'refuses non-PR workspaces and concurrent lifecycle operations' do
    branch_workspace = registry.create(branch: 'main')
    expect { registry.update_pr(branch_workspace.id) }.to raise_error(Workspaces::Worktree::UpdateError, /PR workspace/)
    workspace = pr_workspace
    registry.with_lock(workspace.id) do
      expect { registry.update_pr(workspace.id) }.to raise_error(ArgumentError, /busy/)
    end
  end
end
