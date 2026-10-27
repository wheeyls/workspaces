require_relative 'worktree'
require_relative 'state_store'
require_relative 'backend'
require_relative 'recipe'
require_relative 'environment_overrides'

module Workspaces
  class Registry
    def find(id)
      Worktree.new(id).require_owned!
    end

    def list(**filters)
      root = Config.worktrees_dir(create: false)
      return [] unless root.directory?

      root.children.sort.filter_map do |directory|
        describe_directory(directory, filters[:pr])
      end
    end

    def create(preset: nil, set: {}, unset: [], **options)
      recipe = Recipe.new if preset || !set.empty? || !unset.empty?
      EnvironmentOverrides.settings_for(recipe: recipe, preset: preset, set: set, unset: unset) if recipe
      workspace = Worktree.create(**options)
      StateStore.new(Config.state_file).set(workspace.id, 'status' => 'idle', 'related_pr' => workspace.related_pr)
      EnvironmentOverrides.new(workspace.id).apply_settings(preset: preset, set: set, unset: unset, recipe: recipe) if recipe
      workspace
    end

    def with_lock(id)
      workspace = find(id)
      Config.locks_dir.mkpath
      File.open(Config.prepare_lock_path(id), File::RDWR | File::CREAT, 0o600) do |lock|
        unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise ArgumentError,
                'Workspace is busy preparing, restarting, or running a command'
        end

        yield workspace
      end
    end

    # Removes the workspace and its saved settings and secrets. Returns the secrets that could not be
    # removed (empty when all went), so callers can say so rather than report a clean removal.
    def remove(id, force: false)
      with_lock(id) do |workspace|
        raise ArgumentError, 'Workspace has uncommitted/untracked work' if !force && workspace.dirty?

        Backend.new(id).stop!
        workspace.remove!(force: force)
        StateStore.new(Config.state_file).delete(id)
        EnvironmentOverrides.new(id).clear!
      end
    end

    # Deletes stored secrets whose workspace no longer exists: removed by hand, with `git worktree
    # remove`, or by a purge that failed. Returns { 'removed' => [...], 'kept' => [...],
    # 'problems' => [...] }.
    #
    # It decides a workspace is gone only from the managed directory, and refuses to guess when that
    # directory cannot be read, so a missing or unmounted volume is never mistaken for "everything
    # was deleted". With dry_run it reports what it would remove and changes nothing.
    def sweep_orphaned_secrets(dry_run: false)
      root = Config.worktrees_dir(create: false)
      unless root.directory? && !root.symlink?
        raise ArgumentError, 'The workspaces directory cannot be read, so nothing was removed'
      end

      live = root.children.select { |path| path.directory? && !path.symlink? }.map { |path| path.basename.to_s }
      orphans = Vault.scopes - live
      result = { 'removed' => [], 'kept' => live & Vault.scopes, 'problems' => [] }
      orphans.each do |id|
        problems = dry_run ? [] : Vault.purge_everywhere(id)
        problems.empty? ? result['removed'] << id : result['problems'].concat(problems.map { |problem| "#{id}: #{problem}" })
      end
      result
    end

    def update_pr(id)
      with_lock(id) do |workspace|
        result = workspace.update_from_pr!
        message = result['updated'] ? 'PR checkout updated. Rebuild & restart to run the new code.' : 'PR checkout is already current.'
        StateStore.new(Config.state_file).set(id, 'source_update_message' => message,
                                                  'source_updated_at' => Time.now.utc.iso8601)
        result
      rescue Worktree::UpdateError, Worktree::CommandFailedError => e
        message = e.is_a?(Worktree::CommandFailedError) ? 'Could not fetch or update the PR checkout; local files were not intentionally discarded' : e.message
        StateStore.new(Config.state_file).set(id, 'source_update_message' => message,
                                                  'source_updated_at' => Time.now.utc.iso8601)
        raise Worktree::UpdateError, message
      end
    end

    private

    def describe_directory(directory, number)
      return unless managed_directory?(directory)
      return unless directory.basename.to_s.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)

      workspace = Worktree.new(directory.basename.to_s)
      return unless workspace.exists?
      return if number && workspace.related_pr&.fetch('number', nil).to_s != number.to_s

      workspace.describe
    end

    def managed_directory?(directory)
      directory.directory? && !directory.symlink?
    end
  end
end
