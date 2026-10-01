require 'securerandom'
require_relative 'recipe'
require_relative 'command_runner'
require_relative 'backend'
require_relative 'environment_overrides'

module Workspaces
  class Workflow
    def initialize(workspace, log, state: StateStore.new(Config.state_file))
      @workspace = workspace
      @log = log
      @state = state
      @backend = Backend.new(workspace.id)
    end

    def run!(restart: false)
      recipe = Recipe.new
      overrides = EnvironmentOverrides.new(@workspace.id).load
      steps = recipe.for_operation(restart: restart)
      publish_steps(steps)
      @backend.stop!
      context = build_context(@backend.reserve!)
      runner = CommandRunner.new(@workspace.path, @log)
      steps.each { |step| execute(step, recipe, context, runner, overrides) }
      @backend.ensure_alive!
      @backend.port
    rescue StandardError
      @backend.stop!
      raise
    end

    private

    def publish_steps(steps)
      @state.set(@workspace.id, 'steps' => steps.map do |step|
        { 'key' => step['id'], 'label' => step['name'], 'state' => 'pending', 'duration_seconds' => nil }
      end)
    end

    def build_context(port)
      {
        'WORKSPACE_ID' => @workspace.id, 'WORKSPACE_PATH' => @workspace.path.to_s,
        'WORKSPACE_REPO_ROOT' => Config.repo_root.to_s, 'WORKSPACE_PORT' => port.to_s,
        'WORKSPACE_URL' => Config.preview_url(@workspace.id).delete_suffix('/'),
        'WORKSPACE_HOST' => Config.preview_host(@workspace.id),
        'WORKSPACE_CACHE_DIR' => Config.home.to_s, 'WORKSPACE_RUN_ID' => SecureRandom.hex(24)
      }
    end

    def execute(step, recipe, context, runner, overrides)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      progress(step, 'active')
      @log.puts "==> #{step.fetch('name')}"
      command = recipe.command(step, context)
      env = recipe.env(step, context, overrides: overrides)
      if step['background']
        @backend.start!(@workspace, command, env: env)
      else
        runner.run!(command, env: env, timeout: step.fetch('timeout'))
        @backend.ensure_alive! if @server_started
      end
      @server_started = true if step['background']
    rescue StandardError
      finish_step(step, 'failed', started_at)
      raise
    else
      finish_step(step, 'complete', started_at)
    end

    def finish_step(step, status, started_at)
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).round(3)
      progress(step, status, duration_seconds: duration)
      @log.puts format('==> %s %s (%.3fs)', step.fetch('name'), status, duration)
    end

    def progress(step, status, duration_seconds: nil)
      @state.transaction do |data|
        entry = data.fetch(@workspace.id)
        entry['steps'].find { |item| item['key'] == step['id'] }
          .merge!('state' => status, 'duration_seconds' => duration_seconds)
        entry['message'] = step['name']
        entry['current_step'] = step['id']
        entry['updated_at'] = Time.now.utc.iso8601
      end
    end
  end
end
