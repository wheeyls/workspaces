require 'time'
require_relative 'registry'
require_relative 'backend'
require_relative 'workflow'
require_relative 'tee_log'
require_relative 'presentation'
require_relative 'environment_overrides'

module Workspaces
  class Coordinator
    ACTIVE = %w(preparing).freeze
    attr_reader :workers, :workers_mutex

    def initialize(registry: Registry.new, state: StateStore.new(Config.state_file))
      @registry = registry
      @state = state
      @workers = {}
      @workers_mutex = Mutex.new
    end

    def start(id, force: false)
      launch(id, restart: false, force: force)
    end

    def restart(id)
      launch(id, restart: true, force: true)
    end

    def update_environment(id, set:, remove:)
      restart = Backend.new(id).running?
      launch(id, restart: restart, force: true,
                 prelaunch: lambda { |_workspace|
                   Recipe.new
                   EnvironmentOverrides.new(id).apply_patch(set: set, remove: remove)
                 })
    end

    def replace_editable_environment(id, text:)
      restart = Backend.new(id).running?
      launch(id, restart: restart, force: true,
                 prelaunch: lambda { |_workspace|
                   defaults = Recipe.new.default_editable_env
                   EnvironmentOverrides.new(id).replace_editable(text, defaults: defaults)
                 })
    end

    def wait(id)
      workers_mutex.synchronize { workers[id] }&.value
      snapshot(id)
    end

    def snapshot(id, log: 'setup', include_log: true)
      raise ArgumentError, 'Unknown workspace log' unless %w(setup backend).include?(log)

      workspace = @registry.find(id)
      entry = @state.get(id) || {}
      busy = locked?(id)
      status = resolve_status(id, entry.fetch('status', 'idle'), busy)
      data = workspace.describe.merge(snapshot_fields(id, entry, busy, status, log, include_log))
      data.merge('presentation' => Presentation.new(data).to_h)
    end

    def inventory
      @registry.list.map do |workspace|
        id = workspace.fetch('id')
        entry = @state.get(id) || {}
        busy = locked?(id)
        workspace.merge('status' => resolve_status(id, entry.fetch('status', 'idle'), busy),
                        'running' => !!Backend.new(id).running?, 'active' => busy,
                        'started_at' => entry['started_at'])
      end
    end

    private

    def resolve_status(id, status, busy)
      return busy ? status : 'interrupted' if ACTIVE.include?(status)
      return status if status == 'error'
      return 'ready' if Backend.new(id).running?

      status == 'ready' ? 'stopped' : status
    end

    def snapshot_fields(id, entry, busy, status, log, include_log)
      {
        'workspace_id' => id, 'status' => status, 'active' => busy,
        'message' => status == entry['status'] ? entry['message'] : status.capitalize,
        'prepare_started_at' => entry['prepare_started_at'], 'started_at' => entry['started_at'],
        'running' => !!Backend.new(id).running?, 'updated_at' => entry['updated_at'],
        'source_update_message' => entry['source_update_message'],
        'completed_at' => entry['completed_at'], 'last_error' => entry['last_error'],
        'operation' => entry['operation'], 'failed_phase' => failure_phase(entry, status),
        'steps' => entry.fetch('steps', []),
        'log_tail' => include_log ? log_tail(id, log) : '', 'log_source' => log, 'port' => entry['port'],
        'environment_keys' => environment_keys(id),
        'editable_environment' => editable_environment(id),
        'environment_presets' => environment_presets
      }
    end

    def failure_phase(entry, status)
      status == 'interrupted' ? entry['status'] : entry['failed_phase']
    end

    def launch(id, restart:, force:, prelaunch: nil)
      workspace = @registry.find(id)
      lock = acquire_lock(id)
      return false unless lock

      return false if backend_already_running?(id, force, lock)
      prelaunch&.call(workspace)
      publish_starting(id, restart)
      spawn_worker(workspace, restart, lock)
      true
    rescue StandardError
      lock&.close unless lock&.closed?
      raise
    end

    def backend_already_running?(id, force, lock)
      return false if force || !Backend.new(id).running?

      lock.close
      true
    end

    def acquire_lock(id)
      Config.locks_dir.mkpath
      # The worker owns this duplicate; closing the request's descriptor must not release its lock.
      File.open(Config.prepare_lock_path(id), File::RDWR | File::CREAT, 0o600) do |file|
        file.dup if file.flock(File::LOCK_EX | File::LOCK_NB)
      end
    end

    def publish_starting(id, restart)
      recipe = Recipe.new
      steps = recipe.for_operation(restart: restart).map do |step|
        { 'key' => step['id'], 'label' => step['name'], 'state' => 'pending', 'duration_seconds' => nil }
      end
      update(id, 'status' => 'preparing', 'message' => restart ? 'Restarting application' : 'Preparing workspace',
                 'steps' => steps,
                 'operation' => restart ? 'restart' : 'prepare', 'failed_phase' => nil,
                 'prepare_started_at' => now, 'completed_at' => nil, 'last_error' => nil)
    end

    def spawn_worker(workspace, restart, lock)
      id = workspace.id
      workers_mutex.synchronize do
        workers[id] = Thread.new do
          run(workspace, restart: restart)
        ensure
          lock.close
          workers_mutex.synchronize { workers.delete(id) }
        end
      end
    end

    def run(workspace, restart:)
      id = workspace.id
      File.open(Config.setup_log_path(id), 'a') do |file|
        file.sync = true
        log = TeeLog.new(id, file)
        log.puts "==> #{restart ? 'restarting' : 'preparing'} workspace #{id}; branch and working files unchanged"
        prepare_and_boot(workspace, log, restart)
      end
    rescue StandardError => e
      publish_error(id, e)
    end

    def prepare_and_boot(workspace, log, restart)
      id = workspace.id
      port = Workflow.new(workspace, log, state: @state).run!(restart: restart)
      update(id, 'status' => 'ready', 'message' => 'Workspace ready', 'completed_at' => now, 'port' => port)
    end

    def publish_error(id, exception)
      detail = scrub("#{exception.class}: #{exception.message}", id: id)
      $stdout.puts "[Workspace #{id}] ERROR: #{detail}"
      File.open(Config.setup_log_path(id), 'a') { |file| file.puts "ERROR: #{detail}" }
      update(id, 'status' => 'error', 'message' => 'Workspace preparation failed', 'last_error' => detail,
                 'failed_phase' => @state.get(id)&.fetch('status', nil), 'completed_at' => now)
    end

    def locked?(id)
      path = Config.prepare_lock_path(id)
      return false unless path.file?

      File.open(path, File::RDWR) { |lock| !lock.flock(File::LOCK_EX | File::LOCK_NB) }
    end

    def log_tail(id, log)
      path = log == 'backend' ? Config.backend_log_path(id, create: false) : Config.setup_log_path(id, create: false)
      return '' unless path.file?

      raw = File.open(path, 'rb') do |file|
        file.seek(-Config::SAFE_LOG_BYTES, IO::SEEK_END) if file.size > Config::SAFE_LOG_BYTES
        file.read
      end
      scrub(raw, id: id).lines.last(Config::SAFE_LOG_LINES).join
    end

    def scrub(value, id:)
      scrubbed = value.to_s
      scrubbed = EnvironmentOverrides.new(id).scrub(scrubbed)
      scrubbed.encode('UTF-8', invalid: :replace, undef: :replace)
        .gsub(%r{\e\[[0-9;?]*[ -/]*[@-~]}, '')
        .gsub(/((?:api[_-]?key|token|secret|password|authorization)[^\n:=]{0,40}[:=]\s*)[^\s"',;]+/i, '\1[FILTERED]')
        .gsub(/(Bearer\s+)[^\s]+/i, '\1[FILTERED]')
        .gsub(%r{(https?://[^:\s/]+:)[^@\s]+(@)}i, '\1[FILTERED]\2')
    end

    def environment_keys(id)
      EnvironmentOverrides.new(id).keys
    rescue EnvironmentOverrides::Invalid
      []
    end

    def editable_environment(id)
      EnvironmentOverrides.new(id).editable_values(Recipe.new.default_editable_env)
    rescue Recipe::Invalid, EnvironmentOverrides::Invalid
      {}
    end

    def environment_presets
      recipe = Recipe.new
      recipe.environment_presets.transform_values { |overlay| recipe.default_editable_env.merge(overlay) }
    rescue Recipe::Invalid
      {}
    end

    def update(id, attributes)
      @state.set(id, attributes.merge('updated_at' => now))
    end

    def now
      Time.now.utc.iso8601
    end
  end
end
