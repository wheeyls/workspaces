require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'time'
require_relative 'config'

module Workspaces
  class Worktree
    class CommandFailedError < StandardError; end
    class AuthenticationError < CommandFailedError; end
    class UpdateError < StandardError; end
    AUTH_FAILURE = Regexp.union(/could not read (?:Username|Password)|terminal prompts disabled|Authentication failed/i,
                                /Permission denied \(publickey\)|gh auth login|HTTP 401|HTTP 403/i)
    METADATA = '.workspace.json'.freeze
    PR_METADATA = '.related-pr'.freeze
    attr_reader :id, :path

    def self.create(branch: nil, new_branch: nil, from: nil, **options)
      number = options[:pr]
      unless [branch, number, new_branch].compact.length == 1
        raise ArgumentError, 'Choose exactly one of --branch, --pr, or --new-branch'
      end
      raise ArgumentError, '--from requires --new-branch' if from && !new_branch

      label = new_branch || branch || "pr-#{number}"
      slug = label.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')[0, 30].to_s.sub(/-+\z/, '')
      workspace = new("#{slug.empty? ? 'workspace' : slug}-#{SecureRandom.hex(4)}")
      workspace.create!(branch: branch, number: number, new_branch: new_branch, from: from)
      workspace
    end

    def initialize(id)
      @id = Config.validate_id!(id.to_s)
      @path = Config.worktrees_dir(create: false).join(@id)
    end

    def create!(branch:, number:, new_branch:, from:)
      Config.preview_host(id)
      raise ArgumentError, 'Workspace directory already exists' if path.exist? || path.symlink?

      source = number ? resolve_pr(number) : { 'kind' => 'branch', 'ref' => branch || from || 'HEAD' }
      target_branch = new_branch || "workspaces/#{id}"
      add_worktree!(target_branch, resolve_commit(source.fetch('ref')))
      initialize_worktree!(source, target_branch)
    end

    def exists?
      return false unless ownership_files?

      owned_metadata? && owned_repository?
    rescue JSON::ParserError, CommandFailedError, Errno::ENOENT
      false
    end

    def require_owned!
      raise ArgumentError, "Unknown managed workspace: #{id}" unless exists?

      self
    end

    def metadata
      JSON.parse(path.join(METADATA).read)
    end

    def describe
      require_owned!
      metadata.merge('path' => path.to_s, 'branch' => git!('branch', '--show-current', cwd: path),
                     'head' => git!('rev-parse', 'HEAD', cwd: path),
                     'related_pr' => related_pr, 'dashboard_url' => Config.dashboard_url(id),
                     'preview_url' => Config.preview_url(id))
    end

    def related_pr
      return nil unless path.join(PR_METADATA).file? && !path.join(PR_METADATA).symlink?

      JSON.parse(path.join(PR_METADATA).read)
    end

    def dirty?
      require_owned!
      !git!('status', '--porcelain', '--untracked-files=all', cwd: path).empty?
    end

    def remove!(force: false)
      require_owned!
      raise ArgumentError, 'Workspace has uncommitted/untracked work; use --force to discard it' if !force && dirty?

      args = %w(worktree remove)
      args << '--force' if force
      git!(*args, path.to_s)
    end

    def update_from_pr!
      require_owned!
      source = metadata.fetch('source')
      raise UpdateError, 'Only a PR workspace can be updated from a PR' unless source['kind'] == 'pr'
      raise UpdateError, 'Resolve the retained workspace update stash before updating again' if update_stash?

      number = source.fetch('number')
      raise UpdateError, 'Invalid PR number in workspace metadata' unless number.to_s.match?(/\A[1-9][0-9]*\z/)

      target = fetch_pr_head(number)
      current = git!('rev-parse', 'HEAD', cwd: path)
      raise UpdateError, 'Workspace branch has diverged from the PR; no files were changed' unless ancestor?(current, target)
      return { 'updated' => false, 'head' => current } if current == target

      stash = save_changes
      begin
        git!('-c', 'core.hooksPath=/dev/null', 'merge', '--ff-only', target, cwd: path)
      rescue CommandFailedError
        restore_changes(stash) if stash
        raise UpdateError, 'Could not fast-forward the workspace; local changes were restored'
      end

      restore_changes(stash) if stash
      { 'updated' => true, 'head' => target }
    end

    def git!(*args, cwd: Config.repo_root)
      output, status = Open3.capture2e(git_environment, 'git', *args, chdir: cwd.to_s)
      raise_authentication_error!(output) unless status.success?
      raise CommandFailedError, "git #{args.join(' ')} failed:\n#{output}" unless status.success?

      output.strip
    end

    private

    def fetch_pr_head(number)
      ref = "refs/workspaces/updates/#{id}"
      git!('fetch', 'origin', "+pull/#{number}/head:#{ref}", cwd: path)
      target = git!('rev-parse', '--verify', "#{ref}^{commit}", cwd: path)
      git!('update-ref', '-d', ref, cwd: path)
      target
    end

    def ancestor?(current, target)
      _, status = Open3.capture2e(git_environment, 'git', 'merge-base', '--is-ancestor', current, target,
                                  chdir: path.to_s)
      return true if status.exitstatus == 0
      return false if status.exitstatus == 1

      raise CommandFailedError, 'Unable to check PR ancestry'
    end

    def save_changes
      return nil unless dirty?

      previous = git!('rev-parse', '--verify', '-q', 'refs/stash', cwd: path) if stash_exists?
      git!('stash', 'push', '--include-untracked', '-m', "workspaces update #{id}", cwd: path)
      current = git!('rev-parse', '--verify', 'refs/stash', cwd: path)
      raise UpdateError, 'Unable to save workspace changes; check the worktree and stash before retrying' if current == previous || dirty?

      current
    end

    def stash_exists?
      _, status = Open3.capture2e(git_environment, 'git', 'rev-parse', '--verify', '-q', 'refs/stash',
                                  chdir: path.to_s)
      status.success?
    end

    def update_stash?
      git!('stash', 'list', '--format=%gs', cwd: path).lines.any? do |line|
        line.chomp.end_with?("workspaces update #{id}")
      end
    end

    def restore_changes(stash)
      return unless stash

      begin
        git!('stash', 'apply', '--index', stash, cwd: path)
      rescue CommandFailedError
        raise UpdateError, "Workspace changes could not be reapplied. Stash #{stash} is retained for manual recovery; resolve worktree conflicts before retrying"
      end
      return unless git!('rev-parse', 'refs/stash', cwd: path) == stash

      git!('stash', 'drop', 'stash@{0}', cwd: path)
    end

    def git_environment
      { 'GIT_MASTER' => '1', 'GIT_TERMINAL_PROMPT' => '0', 'GIT_ASKPASS' => '/bin/false', 'SSH_ASKPASS' => '/bin/false',
        'GCM_INTERACTIVE' => 'Never', 'GIT_SSH_COMMAND' => noninteractive_ssh }
    end

    def noninteractive_ssh
      command = ENV.fetch('GIT_SSH_COMMAND', 'ssh')
      "#{command} -o BatchMode=yes -o ConnectTimeout=15"
    end

    def raise_authentication_error!(output)
      return unless output.match?(AUTH_FAILURE)

      raise AuthenticationError,
            'GitHub authentication failed. Run gh auth status and ' \
            'gh auth setup-git --hostname github.com as the service user.'
    end

    def add_worktree!(target_branch, sha)
      git!('check-ref-format', '--branch', target_branch)
      raise ArgumentError, 'Workspace branch must not start with a dash' if target_branch.start_with?('-')

      Config.worktrees_dir.mkpath
      git!('-c', 'core.hooksPath=/dev/null', 'worktree', 'add', '-b', target_branch, path.to_s, sha)
    end

    def initialize_worktree!(source, target_branch)
      reject_tracked_metadata!
      exclude_metadata!
      write_metadata!(source, target_branch)
    rescue StandardError
      git!('worktree', 'remove', '--force', path.to_s)
      raise
    end

    def write_metadata!(source, target_branch)
      data = { 'version' => 1, 'id' => id, 'branch' => target_branch, 'source' => source,
               'created_at' => Time.now.utc.iso8601, 'repository_path' => Config.repo_root.realpath.to_s }
      File.write(path.join(METADATA), JSON.pretty_generate(data), perm: 0o600)
      return unless source['kind'] == 'pr'

      File.write(path.join(PR_METADATA), JSON.pretty_generate(source.slice('repository', 'number')),
                 perm: 0o600)
    end

    def ownership_files?
      !path.symlink? && path.join('.git').file? && path.join(METADATA).file? && !path.join(METADATA).symlink?
    end

    def owned_metadata?
      metadata['id'] == id && metadata['repository_path'] == Config.repo_root.realpath.to_s
    end

    def owned_repository?
      path.realpath.dirname == Config.worktrees_dir.realpath &&
        git!('rev-parse', '--path-format=absolute', '--git-common-dir', cwd: path) ==
          git!('rev-parse', '--path-format=absolute', '--git-common-dir')
    end

    def resolve_pr(number)
      raise ArgumentError, 'PR number must be a positive integer' unless number.to_s.match?(/\A[1-9][0-9]*\z/)

      output, status = Open3.capture2e('gh', 'pr', 'view', number.to_s, '--repo', github_repo,
                                       '--json', 'headRefName,headRefOid', chdir: Config.repo_root.to_s)
      raise_authentication_error!(output) unless status.success?
      raise CommandFailedError, "Unable to resolve PR ##{number}: #{output}" unless status.success?

      pr_source(number, output)
    end

    def pr_source(number, output)
      info = JSON.parse(output)
      sha = info.fetch('headRefOid')
      raise CommandFailedError, 'Invalid PR commit returned by GitHub' unless sha.match?(/\A[0-9a-f]{40,64}\z/)

      git!('fetch', 'origin', "pull/#{number}/head")
      { 'kind' => 'pr', 'repository' => github_repo, 'number' => number.to_i,
        'branch' => info.fetch('headRefName'), 'ref' => sha }
    end

    def github_repo
      return ENV.fetch('WORKSPACES_GITHUB_REPO') if ENV['WORKSPACES_GITHUB_REPO']

      remote = git!('remote', 'get-url', 'origin')
      match = %r{github\.com[:/]([^/]+/[^/]+?)(?:\.git)?\z}.match(remote)
      raise ArgumentError, 'Set WORKSPACES_GITHUB_REPO for the GitHub PR shortcut' unless match

      match[1]
    end

    def resolve_commit(ref)
      raise ArgumentError, 'Invalid starting ref' if ref.to_s.empty? || ref.start_with?('-')

      git!('rev-parse', '--verify', '--end-of-options', "#{ref}^{commit}")
    end

    def reject_tracked_metadata!
      tracked = git!('ls-files', '--', METADATA, PR_METADATA, cwd: path)
      raise ArgumentError, 'Source tracks reserved workspace metadata files' unless tracked.empty?
    end

    def exclude_metadata!
      common = Pathname(git!('rev-parse', '--path-format=absolute', '--git-common-dir'))
      exclude = common.join('info/exclude')
      exclude.dirname.mkpath
      File.open(exclude, File::RDWR | File::CREAT, 0o644) do |file|
        file.flock(File::LOCK_EX)
        existing = file.read.lines.map(&:strip)
        file.seek(0, IO::SEEK_END)
        ["/#{METADATA}", "/#{PR_METADATA}"].each do |pattern|
          file.puts "\n#{pattern}" unless existing.include?(pattern)
        end
      end
    end
  end
end
