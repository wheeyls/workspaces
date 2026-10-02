require 'timeout'
require 'securerandom'
require 'time'
require_relative 'config'
require_relative 'state_store'
require_relative 'port_allocator'
require_relative 'child_env'

module Workspaces
  class Backend
    class BootFailedError < StandardError; end
    attr_reader :workspace_id

    def initialize(workspace_id)
      @workspace_id = Config.validate_id!(workspace_id.to_s)
      @state = StateStore.new(Config.state_file)
    end

    def running?
      entry = @state.get(workspace_id) || {}
      entry['pid'] && entry['port'] && !process_exited?(entry['pid'])
    end

    def port
      @state.get(workspace_id)&.fetch('port', nil)
    end

    def reserve!
      @state.transaction do |data|
        taken = data.values.filter_map { |entry| entry['port'] }
        assigned = PortAllocator.allocate(Config::BACKEND_PORT_RANGE, taken)
        data[workspace_id] = (data[workspace_id] || {}).merge('port' => assigned)
        assigned
      end
    end

    def start!(workspace, command, env:)
      assigned = port
      raise BootFailedError, 'Reserved port became occupied before server launch' unless PortAllocator.free?(assigned)

      pid = spawn_command(workspace, command, env)
      @state.set(workspace_id, 'pid' => pid, 'process_group' => pid, 'started_at' => Time.now.utc.iso8601)
      pid
    rescue StandardError
      terminate(pid) if pid
      raise
    end

    def ensure_alive!
      raise BootFailedError, 'Application exited before readiness completed; inspect the server log' unless running?
    end

    def stop!
      entry = @state.get(workspace_id) || {}
      terminate(entry['pid'], group: entry['process_group']) if entry['pid']
      @state.transaction do |data|
        %w(pid port process_group).each { |key| data[workspace_id]&.delete(key) }
      end
    end

    private

    def spawn_command(workspace, command, env)
      File.open(Config.backend_log_path(workspace_id), 'a') do |file|
        child_env = ChildEnv.for_workspace(workspace_path: workspace.path, extra_env: env)
        Process.spawn(child_env, [command.first, command.first], *command.drop(1),
                      chdir: workspace.path.to_s, in: File::NULL, out: file, err: file, pgroup: true,
                      unsetenv_others: true)
      end
    end

    def terminate(pid, group: nil)
      return if stopped?(pid, group)

      target = group ? -group : pid
      Process.kill('TERM', target)
      Timeout.timeout(10) { sleep 0.05 until stopped?(pid, group) }
    rescue Timeout::Error
      Process.kill('KILL', target)
      Timeout.timeout(5) { sleep 0.05 until process_exited?(pid) }
    rescue Errno::ESRCH
      nil
    end

    def stopped?(pid, group)
      process_exited?(pid) && !group_alive?(group)
    end

    def group_alive?(group)
      return false unless group

      Process.kill(0, -group)
      true
    rescue Errno::ESRCH
      false
    end

    def process_exited?(pid)
      !!Process.waitpid(pid, Process::WNOHANG)
    rescue Errno::ECHILD
      !pid_alive?(pid)
    end

    def pid_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, TypeError
      false
    end
  end
end
