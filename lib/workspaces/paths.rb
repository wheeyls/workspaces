require 'pathname'
require 'digest'

module Workspaces
  module Paths
    def home
      @home ||= if ENV['WORKSPACES_HOME']
                  Pathname.new(File.expand_path(ENV.fetch('WORKSPACES_HOME')))
                else
                  Pathname.new(self::DEFAULT_HOME).join(Digest::SHA256.hexdigest(repo_root.realpath.to_s)[0, 16])
                end
    end

    def worktrees_dir(create: true)
      directory('workspaces', create: create)
    end

    def logs_dir(create: true)
      directory('logs', create: create)
    end

    def locks_dir(create: true)
      directory('locks', create: create)
    end

    def state_file
      home.join('state.json')
    end

    def log_path(workspace_id, create: true)
      setup_log_path(workspace_id, create: create)
    end

    def setup_log_path(workspace_id, create: true)
      logs_dir(create: create).join("#{workspace_id}.setup.log")
    end

    def backend_log_path(workspace_id, create: true)
      logs_dir(create: create).join("#{workspace_id}.backend.log")
    end

    def prepare_lock_path(workspace_id)
      locks_dir(create: false).join("#{workspace_id}.prepare.lock")
    end

    def boot_lock_path(workspace_id)
      locks_dir(create: false).join("#{workspace_id}.lock")
    end

    def repo_root
      return Pathname.new(File.expand_path(ENV.fetch('WORKSPACES_REPO_ROOT'))) if ENV['WORKSPACES_REPO_ROOT']

      Pathname.pwd.ascend.find { |directory| directory.join('.workspaces.yml').file? && directory.join('.git').exist? } ||
        raise(ArgumentError, 'Run inside a Git repository or set WORKSPACES_REPO_ROOT')
    end

    private

    def directory(name, create:)
      home.join(name).tap { |path| path.mkpath if create }
    end
  end
end
