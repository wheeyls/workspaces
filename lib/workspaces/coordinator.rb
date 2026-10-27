require 'time'
require_relative 'registry'
require_relative 'backend'
require_relative 'workflow'
require_relative 'tee_log'
require_relative 'presentation'
require_relative 'environment_overrides'
require_relative 'duration_format'
require_relative 'build_history'
require_relative 'resume_plan'

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

    def start(id, force: false, preset: nil, set: {}, unset: [])
      if !force && sleeping?(id)
        return wake(id) unless preset || !set.empty? || !unset.empty?

        return launch(id, restart: true, force: true, prelaunch: settings_update(id, preset, set, unset))
      end

      launch(id, restart: false, force: force, prelaunch: settings_update(id, preset, set, unset))
    end

    def restart(id, preset: nil, set: {}, unset: [])
      launch(id, restart: true, force: true, prelaunch: settings_update(id, preset, set, unset))
    end

    # Re-runs part of the last run instead of all of it. `mode` is :retry (continue from the first
    # step that did not finish), :from (that step and everything after it) or :only (exactly that
    # step). Finished steps keep their time and log; see ResumePlan for what each mode allows.
    # Returns false when the workspace is busy and raises ArgumentError (with a plain-language
    # message) when the request cannot be honoured.
    def rerun(id, mode: :retry, key: nil)
      workspace = @registry.find(id)
      lock = acquire_lock(id)
      return false unless lock

      plan = rerun_plan(id, mode, key)
      publish_rerun(id, plan)
      spawn_worker(workspace, false, lock, plan: plan)
      true
    rescue StandardError
      lock&.close unless lock&.closed?
      raise
    end

    def update_environment(id, set:, remove:)
      restart = Backend.new(id).running? || sleeping?(id)
      launch(id, restart: restart, force: true,
                 prelaunch: lambda { |_workspace|
                   Recipe.new
                   EnvironmentOverrides.new(id).apply_patch(set: set, remove: remove)
                 })
    end

    # Saves the settings form (rows of name / value / secret) and starts the workspace, restarting it
    # if it is already up. See EnvironmentOverrides#replace_rows.
    def replace_environment_rows(id, rows:)
      restart = Backend.new(id).running? || sleeping?(id)
      launch(id, restart: restart, force: true,
                 prelaunch: lambda { |_workspace|
                   defaults = Recipe.new.default_editable_env
                   EnvironmentOverrides.new(id).replace_rows(rows, defaults: defaults)
                 })
    end

    def replace_editable_environment(id, text:)
      restart = Backend.new(id).running? || sleeping?(id)
      launch(id, restart: restart, force: true,
                 prelaunch: lambda { |_workspace|
                   defaults = Recipe.new.default_editable_env
                   EnvironmentOverrides.new(id).replace_editable(text, defaults: defaults)
                 })
    end

    # Stops an idle workspace's server and keeps everything else: worktree, database, dependencies,
    # built assets, settings and build history. Returns true when it slept. Does nothing (false) while
    # the workspace is busy, is kept awake, is not running, or is already asleep.
    def sleep!(id)
      @registry.find(id)
      lock = acquire_lock(id)
      return false unless lock

      begin
        entry = @state.get(id) || {}
        return false unless sleepable?(id, entry)

        update(id, 'sleep_state' => 'sleeping', 'slept_at' => now)
        begin
          Backend.new(id).stop!
        rescue StandardError
          update(id, 'sleep_state' => nil, 'slept_at' => nil)
          raise
        end
        true
      ensure
        lock.close
      end
    end

    # Starts a sleeping workspace's server again and returns at once; the caller watches for readiness.
    # Only a workspace that is intentionally asleep is woken: one that was stopped by hand, failed,
    # or is already starting is left alone (false). Concurrent callers share one wake because only
    # the one holding the workspace lock gets past the check.
    def wake(id)
      workspace = @registry.find(id)
      lock = acquire_lock(id)
      return false unless lock

      entry = @state.get(id) || {}
      if entry['sleep_state'] != 'sleeping' || Backend.new(id).running?
        lock.close
        return false
      end

      restart = preparation_current?(entry)
      publish_starting(id, restart, extra: { 'sleep_state' => 'waking', 'message' => 'Waking workspace' })
      spawn_worker(workspace, restart, lock)
      true
    rescue StandardError
      lock&.close unless lock&.closed?
      raise
    end

    # Stops the server by hand. A workspace stopped this way is not asleep, so traffic never wakes it.
    def stop(id)
      @registry.with_lock(id) do
        Backend.new(id).stop!
        @state.set(id, 'status' => 'stopped', 'message' => 'Server stopped', 'sleep_state' => nil, 'slept_at' => nil)
      end
    end

    def keep_awake(id, enabled)
      @registry.find(id)
      @state.set(id, 'keep_awake' => !!enabled)
      !!enabled
    end

    def sleeping?(id)
      (@state.get(id) || {})['sleep_state'] == 'sleeping'
    end

    # :sleeping, :waking (a wake is running), or nil.
    def sleep_phase(id)
      case (@state.get(id) || {})['sleep_state']
      when 'sleeping' then :sleeping
      when 'waking' then locked?(id) ? :waking : nil
      end
    end

    def status_of(id)
      entry = @state.get(id) || {}
      resolve_status(id, entry, locked?(id))
    end

    # Workspaces that look ready, are not kept awake and are not asleep. A cheap read of the state
    # file; `sleep!` checks everything again under the workspace lock.
    def sleep_candidates
      @state.all.filter_map do |id, entry|
        id if entry['status'] == 'ready' && !entry['keep_awake'] && entry['sleep_state'].nil?
      end
    end

    # Run once when a front door starts. A sleep that was cut short is finished, and a wake that was
    # cut short is cleared, so the workspace reads as interrupted rather than as waking forever.
    def reconcile_sleep
      @state.all.each do |id, entry|
        case entry['sleep_state']
        when 'sleeping' then finish_interrupted_sleep(id)
        when 'waking' then @state.set(id, 'sleep_state' => nil) unless locked?(id)
        end
      end
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
      status = resolve_status(id, entry, busy)
      data = workspace.describe.merge(snapshot_fields(id, entry, busy, status, log, include_log))
      data.merge('presentation' => Presentation.new(data).to_h)
    end

    def inventory
      @registry.list.map do |workspace|
        id = workspace.fetch('id')
        entry = @state.get(id) || {}
        busy = locked?(id)
        workspace.merge('status' => resolve_status(id, entry, busy),
                        'running' => !!Backend.new(id).running?, 'active' => busy,
                        'started_at' => entry['started_at'])
      end
    end

    private

    def settings_update(id, preset, set, unset)
      return if !preset && set.empty? && unset.empty?

      lambda do |_workspace|
        EnvironmentOverrides.new(id).apply_settings(preset: preset, set: set, unset: unset)
      end
    end

    def resolve_status(id, entry, busy)
      status = entry.fetch('status', 'idle')
      return busy ? status : 'interrupted' if ACTIVE.include?(status)
      return status if status == 'error'
      return 'ready' if Backend.new(id).running?
      return 'sleeping' if entry['sleep_state'] == 'sleeping'

      status == 'ready' ? 'stopped' : status
    end

    def sleepable?(id, entry)
      entry['status'] == 'ready' && !entry['keep_awake'] && entry['sleep_state'].nil? && Backend.new(id).running?
    end

    # What was prepared still matches the recipe, so waking only needs the server and readiness steps.
    # A workspace prepared before this was recorded is trusted.
    def preparation_current?(entry)
      recorded = entry['prepared_digest']
      recorded.nil? || recorded == Recipe.new.preparation_digest
    end

    def finish_interrupted_sleep(id)
      lock = acquire_lock(id)
      return unless lock

      begin
        Backend.new(id).stop! if Backend.new(id).running?
      ensure
        lock.close
      end
    end

    def snapshot_fields(id, entry, busy, status, log, include_log)
      {
        'workspace_id' => id, 'status' => status, 'active' => busy,
        'sleeping' => status == 'sleeping', 'slept_at' => entry['slept_at'],
        'keep_awake' => !!entry['keep_awake'], 'sleep_after_seconds' => Config.sleep_after_seconds,
        'message' => status == entry['status'] ? entry['message'] : status.capitalize,
        'prepare_started_at' => entry['prepare_started_at'], 'started_at' => entry['started_at'],
        'running' => !!Backend.new(id).running?, 'updated_at' => entry['updated_at'],
        'source_update_message' => entry['source_update_message'],
        'completed_at' => entry['completed_at'], 'last_error' => entry['last_error'],
        'operation' => entry['operation'], 'failed_phase' => failure_phase(entry, status),
        'steps' => entry.fetch('steps', []), 'total_seconds' => entry['total_seconds'],
        'resume' => resume_info(id, entry),
        'estimates' => entry.fetch('estimates', {}),
        'step_logs' => include_log && log == 'setup' ? step_logs(id, entry.fetch('steps', [])) : {},
        'backend_log_available' => backend_log_available?(id),
        'log_tail' => include_log ? log_tail(id, log) : '', 'log_source' => log, 'port' => entry['port'],
        'environment_keys' => environment_keys(id),
        'editable_environment' => editable_environment(id),
        'secret_names' => secret_names(id),
        'vault' => Vault.status,
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

      if prelaunch && !restart && !force && Backend.new(id).running?
        raise ArgumentError, 'Workspace is running; use restart --preset to change its environment'
      end
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

    def resume_info(id, entry)
      steps = entry['steps']
      return nil if steps.nil? || steps.empty?

      ResumePlan.describe(recipe_steps: Recipe.new.steps, persisted: steps, server_live: Backend.new(id).resumable?)
    rescue Recipe::Invalid
      nil
    end

    def rerun_plan(id, mode, key)
      entry = @state.get(id) || {}
      ResumePlan.build(recipe_steps: Recipe.new.steps, persisted: entry['steps'], mode: mode.to_sym, key: key,
                       server_live: Backend.new(id).resumable?)
    end

    def publish_rerun(id, plan)
      update(id, 'status' => 'preparing', 'message' => "Re-running #{plan.description}",
                 'steps' => plan.steps, 'estimates' => BuildHistory.estimates(plan.steps.map { |step| step['key'] }),
                 'operation' => 'resume', 'rerun_keys' => plan.run_keys, 'failed_phase' => nil,
                 'prepare_started_at' => now, 'completed_at' => nil, 'last_error' => nil, 'total_seconds' => nil)
    end

    def acquire_lock(id)
      Config.locks_dir.mkpath
      # The worker owns this duplicate; closing the request's descriptor must not release its lock.
      File.open(Config.prepare_lock_path(id), File::RDWR | File::CREAT, 0o600) do |file|
        file.dup if file.flock(File::LOCK_EX | File::LOCK_NB)
      end
    end

    def publish_starting(id, restart, extra: {})
      recipe = Recipe.new
      steps = recipe.for_operation(restart: restart).map do |step|
        { 'key' => step['id'], 'label' => step['name'], 'state' => 'pending', 'duration_seconds' => nil }
      end
      # Frozen for the whole run, so the bar does not shift under the reader and the history file
      # is read once per run rather than once per poll.
      update(id, {
                 'status' => 'preparing', 'message' => restart ? 'Restarting application' : 'Preparing workspace',
                 'steps' => steps, 'estimates' => BuildHistory.estimates(steps.map { |step| step['key'] }),
                 'operation' => restart ? 'restart' : 'prepare', 'rerun_keys' => nil, 'failed_phase' => nil,
                 'prepare_started_at' => now, 'completed_at' => nil, 'last_error' => nil,
                 'total_seconds' => nil, 'sleep_state' => nil, 'slept_at' => nil
               }.merge(extra))
    end

    def spawn_worker(workspace, restart, lock, plan: nil)
      id = workspace.id
      workers_mutex.synchronize do
        workers[id] = Thread.new do
          run(workspace, restart: restart, plan: plan)
        ensure
          lock.close
          workers_mutex.synchronize { workers.delete(id) }
        end
      end
    end

    def run(workspace, restart:, plan: nil)
      id = workspace.id
      started = monotonic
      File.open(Config.setup_log_path(id), 'a') do |file|
        file.sync = true
        log = TeeLog.new(id, file)
        verb = plan ? "re-running #{plan.description} of" : (restart ? 'restarting' : 'preparing')
        log.puts "==> #{verb} workspace #{id}; branch and working files unchanged"
        prepare_and_boot(workspace, log, restart, started, plan)
      end
    rescue StandardError => e
      publish_error(id, e, started)
    end

    # The wall-clock time of the whole run, boot and readiness included. Step durations add up to
    # less than this because orchestration between steps is not inside any step.
    def prepare_and_boot(workspace, log, restart, started, plan = nil)
      id = workspace.id
      workflow = Workflow.new(workspace, log, state: @state)
      # Full runs call the workflow exactly as they always have; only a partial re-run passes a plan.
      port = plan ? workflow.run!(restart: restart, plan: plan) : workflow.run!(restart: restart)
      total = elapsed_since(started)
      # A re-run that left no server running (a step before it on a stopped workspace) keeps the
      # recorded port as it was; the workspace then reads as stopped until it is started.
      attributes = { 'status' => 'ready', 'message' => 'Workspace ready', 'completed_at' => now, 'total_seconds' => total,
                     'sleep_state' => nil }
      attributes['port'] = port if port
      attributes['prepared_digest'] = Recipe.new.preparation_digest if plan.nil? && !restart
      update(id, attributes)
      record_run(id, 'complete', total)
    end

    def publish_error(id, exception, started = nil)
      detail = scrub("#{exception.class}: #{exception.message}", id: id)
      $stdout.puts "[Workspace #{id}] ERROR: #{detail}"
      File.open(Config.setup_log_path(id), 'a') { |file| file.puts "ERROR: #{detail}" }
      total = started && elapsed_since(started)
      update(id, 'status' => 'error', 'message' => 'Workspace preparation failed', 'last_error' => detail,
                 'failed_phase' => @state.get(id)&.fetch('status', nil), 'completed_at' => now,
                 'total_seconds' => total, 'sleep_state' => nil)
      record_run(id, 'failed', total)
    end

    # Appends to the build history. A problem here must never change how the run itself ended.
    def record_run(id, result, total_seconds)
      entry = @state.get(id) || {}
      steps = entry['steps']
      steps = steps.select { |step| entry['rerun_keys'].include?(step['key']) } if entry['rerun_keys'] && steps
      BuildHistory.record(workspace_id: id, operation: entry['operation'], result: result,
                          total_seconds: total_seconds, steps: steps)
    rescue StandardError
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_since(started)
      (monotonic - started).round(3)
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

    # Output for each recipe step, keyed by step id. Only steps that have written something
    # appear, so a pending step has no entry and the page can show it as not started.
    def step_logs(id, steps)
      steps.each_with_object({}) do |step, logs|
        path = Config.step_log_path(id, step['key'], create: false)
        next unless path.file?

        logs[step['key']] = tail_file(path, id, bytes: Config::STEP_LOG_BYTES, lines: Config::STEP_LOG_LINES)
      end
    rescue ArgumentError
      {}
    end

    def backend_log_available?(id)
      path = Config.backend_log_path(id, create: false)
      path.file? && !path.zero?
    end

    # The tail of a log file, scrubbed, with whether earlier output was cut off.
    def tail_file(path, id, bytes:, lines:)
      size = path.size
      raw = File.open(path, 'rb') do |file|
        file.seek(-bytes, IO::SEEK_END) if size > bytes
        file.read
      end
      kept = scrub(raw, id: id).lines
      { 'text' => kept.last(lines).join, 'truncated' => size > bytes || kept.length > lines }
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

    # Names only. A secret's value is never part of a snapshot, a status response or a page.
    def secret_names(id)
      EnvironmentOverrides.new(id).secret_names
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
