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
      'kind' => 'pr', 'repository' => 'example/project', 'number' => 43828, 'branch' => 'feature', 'ref' => 'main'
    )
    first = described_class.create(pr: '43828')
    second = described_class.create(pr: '43828')
    expect(first.related_pr).to eq('repository' => 'example/project', 'number' => 43828)
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
    allow(Open3).to receive(:capture2e).with('gh', 'pr', 'view', '43828', '--repo', 'example/project',
                                             '--json', 'headRefName,headRefOid', chdir: Workspaces::Config.repo_root.to_s)
                      .and_return([JSON.generate('headRefName' => 'feature/checkout', 'headRefOid' => sha), status])
    allow(workspace).to receive(:git!).with('fetch', 'origin', 'pull/43828/head').and_return('')
    source = workspace.send(:resolve_pr, '43828')
    expect(source).to include('number' => 43828, 'branch' => 'feature/checkout', 'ref' => sha)
    expect(workspace).to have_received(:git!).with('fetch', 'origin', 'pull/43828/head').once
  end

  describe 'Git LFS files' do
    before do
      skip 'git-lfs is not installed' unless system('git lfs version', out: File::NULL, err: File::NULL)

      git('lfs', 'install', '--local')
      git('lfs', 'track', 'big/**/*.bin')
      FileUtils.mkdir_p(Workspaces::Config.repo_root.join('big/keep'))
      FileUtils.mkdir_p(Workspaces::Config.repo_root.join('big/other'))
      File.binwrite(Workspaces::Config.repo_root.join('big/keep/a.bin'), 'A' * 100_000)
      File.binwrite(Workspaces::Config.repo_root.join('big/other/b.bin'), 'B' * 100_000)
      git('add', '.')
      git('-c', 'core.hooksPath=/dev/null', 'commit', '-m', 'Add LFS files')
    end

    def pointer?(path)
      path.read(40).to_s.start_with?('version https://git-lfs')
    end

    it 'gives a new workspace small pointer files instead of copying every LFS file, and stays clean' do
      workspace = described_class.create(branch: 'main')

      expect(pointer?(workspace.path.join('big/keep/a.bin'))).to be(true)
      expect(workspace.path.join('big/keep/a.bin').size).to be < 200
      expect(workspace.path.join('tracked.txt').read).to eq('baseline')
      expect(workspace.dirty?).to be(false)
    end

    it 'leaves the source checkout\'s real files untouched' do
      described_class.create(branch: 'main')

      expect(Workspaces::Config.repo_root.join('big/keep/a.bin').size).to eq(100_000)
    end

    it 'can fetch just the files a recipe names, using what the source repository already has' do
      workspace = described_class.create(branch: 'main')

      _, status = Open3.capture2e('git', 'lfs', 'pull', '--include=big/keep/**', chdir: workspace.path.to_s)

      expect(status.success?).to be(true)
      expect(workspace.path.join('big/keep/a.bin').size).to eq(100_000)
      expect(pointer?(workspace.path.join('big/other/b.bin'))).to be(true)
      expect(workspace.dirty?).to be(false)
    end

    it 'does not download LFS files when a PR workspace is fast-forwarded to a newer head' do
      allow_any_instance_of(described_class).to receive(:resolve_pr).with('43828').and_return(
        'kind' => 'pr', 'repository' => 'example/project', 'number' => 43828, 'branch' => 'feature', 'ref' => 'main'
      )
      workspace = described_class.create(pr: '43828')
      File.binwrite(Workspaces::Config.repo_root.join('big/other/b.bin'), 'C' * 100_000)
      git('add', '.')
      git('-c', 'core.hooksPath=/dev/null', 'commit', '-m', 'Change an LFS file')
      newer = git('rev-parse', 'HEAD')
      allow_any_instance_of(described_class).to receive(:fetch_pr_head).and_return(newer)

      result = workspace.update_from_pr!

      expect(result).to include('updated' => true, 'head' => newer)
      expect(pointer?(workspace.path.join('big/other/b.bin'))).to be(true)
      expect(workspace.dirty?).to be(false)
    end

    it 'does not turn a file someone fetched back into a pointer when stashing and restoring local changes' do
      workspace = described_class.create(branch: 'main')
      Open3.capture2e('git', 'lfs', 'pull', '--include=big/keep/**', chdir: workspace.path.to_s)
      File.write(workspace.path.join('tracked.txt'), 'edited')

      stash = workspace.send(:save_changes)
      workspace.send(:restore_changes, stash)

      expect(workspace.path.join('big/keep/a.bin').size).to eq(100_000)
      expect(workspace.path.join('tracked.txt').read).to eq('edited')
    end
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
