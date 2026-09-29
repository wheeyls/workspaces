require_relative 'worktree'
require_relative 'state_store'

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

    def create(**options)
      workspace = Worktree.create(**options)
      StateStore.new(Config.state_file).set(workspace.id, 'status' => 'idle', 'related_pr' => workspace.related_pr)
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
