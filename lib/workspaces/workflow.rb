require 'securerandom'
require_relative 'recipe'
require_relative 'command_runner'
require_relative 'backend'
require_relative 'environment_overrides'
require_relative 'step_log'
require_relative 'duration_format'

module Workspaces
  class Workflow
    def initialize(workspace, log, state: StateStore.new(Config.state_file))
      @workspace = workspace
      @combined_log = log
      @log = StepLog.new(log, workspace.id)
      @state = state
      @backend = Backend.new(workspace.id)
    end

    # `plan` (a ResumePlan::Plan) re-runs part of the recipe: finished steps keep their state, time
    # and log, only the planned steps start over, and the server is stopped and restarted only when
    # the planned steps include the one that starts it. Without a plan the whole operation runs.
    #
    # Returns the server's port, or nil when no server is running afterwards (which can only happen
    # when a plan re-ran a step before the server on a workspace whose server was stopped).
    def run!(restart: false, plan: nil)
      recipe = Recipe.new
      overrides = EnvironmentOverrides.new(@workspace.id).load
      steps = plan ? recipe.steps.select { |step| plan.run_keys.include?(step['id']) } : recipe.for_operation(restart: restart)
      plan ? @state.set(@workspace.id, 'steps' => plan.steps) : publish_steps(steps)
      StepLog.reset(@workspace.id, keys: plan&.run_keys)
      context = prepare_server(plan)
      runner = CommandRunner.new(@workspace.path, @log)
      steps.each { |step| execute(step, recipe, context, runner, overrides) }
      return finish_full_run if plan.nil? || plan.touches_server || plan.after_server

      @backend.running? ? @backend.port : nil
    rescue StandardError
      # A server this run started (or would have replaced) is not trustworthy after a failure. One
      # this run never touched is left as it was.
      @backend.stop! if plan.nil? || plan.touches_server
      raise
    ensure
      @log.finish_step
    end

    private

    # Stops the old server and reserves a fresh port and token when this run will start the server;
    # otherwise the running server's own port and token are reused, so steps see the same values.
    def prepare_server(plan)
      if plan.nil? || plan.touches_server
        @backend.stop!
        return build_context(@backend.reserve!)
      end

      @server_started = plan.after_server
      build_context(@backend.port, run_id: @backend.run_id)
    end

    # A run that covers the server step (or follows it) ends with a liveness check, exactly as a
    # full run always has, and reports the port of the server it leaves running.
    def finish_full_run
      @backend.ensure_alive!
      @backend.port
    end

    def publish_steps(steps)
      @state.set(@workspace.id, 'steps' => steps.map do |step|
        { 'key' => step['id'], 'label' => step['name'], 'state' => 'pending', 'duration_seconds' => nil }
      end)
    end

    def build_context(port, run_id: nil)
      {
        'WORKSPACE_ID' => @workspace.id, 'WORKSPACE_PATH' => @workspace.path.to_s,
        'WORKSPACE_REPO_ROOT' => Config.repo_root.to_s, 'WORKSPACE_PORT' => port.to_s,
        'WORKSPACE_URL' => Config.preview_url(@workspace.id).delete_suffix('/'),
        'WORKSPACE_HOST' => Config.preview_host(@workspace.id),
        'WORKSPACE_CACHE_DIR' => Config.home.to_s, 'WORKSPACE_RUN_ID' => run_id || SecureRandom.hex(24)
      }
    end

    def execute(step, recipe, context, runner, overrides)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      progress(step, 'active')
      @log.begin_step(step.fetch('id'))
      @log.puts "==> #{step.fetch('name')}"
      command = recipe.command(step, context)
      env = recipe.env(step, context, overrides: overrides)
      if step['background']
        @backend.start!(@workspace, command, env: env)
        @state.set(@workspace.id, 'run_id' => context.fetch('WORKSPACE_RUN_ID'))
      else
        runner.run!(command, env: env, timeout: step.fetch('timeout'))
        @backend.ensure_alive! if @server_started
      end
      @server_started = true if step['background']
    rescue StandardError => e
      # The reason a step failed is not command output, so the step file would otherwise end
      # without it. Record it where the step's own accordion can show it.
      @log.puts "ERROR: #{e.message}"
      finish_step(step, 'failed', started_at)
      raise
    else
      finish_step(step, 'complete', started_at)
    end

    def finish_step(step, status, started_at)
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).round(3)
      progress(step, status, duration_seconds: duration)
      @log.puts format('==> %s %s (%s)', step.fetch('name'), status, DurationFormat.call(duration))
    end

    def progress(step, status, duration_seconds: nil)
      @state.transaction do |data|
        entry = data.fetch(@workspace.id)
        record = entry['steps'].find { |item| item['key'] == step['id'] }
        record.merge!('state' => status, 'duration_seconds' => duration_seconds)
        record['started_at'] = Time.now.utc.iso8601(3) if status == 'active'
        entry['message'] = step['name']
        entry['current_step'] = step['id']
        entry['updated_at'] = Time.now.utc.iso8601
      end
    end
  end
end
