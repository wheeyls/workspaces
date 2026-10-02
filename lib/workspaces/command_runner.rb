require 'open3'
require 'timeout'
require_relative 'child_env'

module Workspaces
  class CommandRunner
    class Failed < StandardError; end

    def initialize(path, log)
      @path = path
      @log = log
    end

    def run!(command, env:, timeout:)
      executable = [command.first, command.first]
      child_env = ChildEnv.for_workspace(workspace_path: @path, extra_env: env)
      Open3.popen2e(child_env, executable, *command.drop(1), chdir: @path.to_s, pgroup: true,
                    unsetenv_others: true) do |input, output, child|
        input.close
        output.set_encoding(Encoding::UTF_8, invalid: :replace, undef: :replace)
        run_child(output, child, timeout)
      end
    rescue Errno::ENOENT
      raise Failed, "Executable not found: #{command.first}. Install it or update the repository's run step."
    end

    private

    def run_child(output, child, timeout)
      Timeout.timeout(timeout) do
        output.each_line { |line| @log.print(line) }
        result = child.value
        unless result.success?
          raise Failed,
                "Command exited with status #{result.exitstatus || "signal #{result.termsig}"}; see setup log"
        end
      end
    rescue Timeout::Error
      terminate(child)
      raise Failed, "Command exceeded its #{timeout}s timeout"
    ensure
      terminate(child) if child.alive?
    end

    def terminate(child)
      Process.kill('KILL', -child.pid)
      child.join
    rescue Errno::ESRCH
      child.join
    end
  end
end
