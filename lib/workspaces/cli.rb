require 'optparse'
require 'rack'
require 'rackup'
require 'rack/handler/puma'
require_relative 'registry'
require_relative 'coordinator'
require_relative 'front_door'
require_relative 'tls'
require_relative 'child_env'

module Workspaces
  class Cli
    COMMANDS = {
      'serve' => :serve, 'create' => :create, 'list' => :list, 'show' => :show,
      'start' => :lifecycle, 'prepare' => :lifecycle, 'restart' => :lifecycle,
      'stop' => :stop, 'remove' => :remove, 'help' => :help
    }.freeze
    def self.run(argv)
      new.run(argv.dup)
    end

    def run(argv)
      command = argv.shift || 'serve'
      return execute(argv) if command == 'exec'

      options = parse(command, argv)
      id = argv.shift
      raise ArgumentError, 'Unexpected extra arguments' unless argv.empty?

      handler = COMMANDS.fetch(command) { raise ArgumentError, usage }
      send(handler, id, options.merge(command: command))
      0
    rescue ArgumentError, OptionParser::ParseError, Worktree::CommandFailedError => e
      warn e.message
      1
    end

    private

    def registry
      @registry ||= Registry.new
    end

    def coordinator
      @coordinator ||= Coordinator.new(registry: registry)
    end

    def parse(command, argv)
      options = {}
      OptionParser.new do |parser|
        parse_common_options(parser, options)
        parse_tls_options(parser, options) if command == 'serve'
      end.parse!(argv)
      options
    end

    def parse_common_options(parser, options)
      parser.on('--branch REF') { |value| options[:branch] = value }
      parser.on('--pr NUMBER') { |value| options[:pr] = value }
      parser.on('--new-branch NAME') { |value| options[:new_branch] = value }
      parser.on('--from REF') { |value| options[:from] = value }
      parser.on('--json') { options[:json] = true }
      parser.on('--force') { options[:force] = true }
    end

    def parse_tls_options(parser, options)
      parser.on('--secure') { options[:secure] = true }
      parser.on('--tls-cert PATH') { |value| options[:tls_cert] = value }
      parser.on('--tls-key PATH') { |value| options[:tls_key] = value }
    end

    def serve(_id, options)
      tls = Tls.from_serve_options(options)&.validate!

      if tls
        tls.apply_env_defaults { serve_with_tls(tls) }
      else
        serve_with_tls(nil)
      end
    end

    def serve_with_tls(tls)
      puts "Workspaces listening on #{Config.bind_address}:#{Config.front_door_port}"
      puts "Dashboard: #{Config.public_origin}/workspaces"
      puts "Managed directory: #{Config.worktrees_dir}"
      print_tls_exports(tls)
      Rackup::Handler::Puma.run(FrontDoor.new, **puma_options(tls))
    end

    def print_tls_exports(tls)
      return unless tls&.shortcut

      puts 'When using separate commands, export the workspace public origin settings first:'
      tls.env_exports.each { |command| puts command }
    end

    def puma_options(tls)
      options = { config_files: ['-'], workers: 0 }
      return options.merge(Host: tls.bind_uri(host: Config.bind_address, port: Config.front_door_port)) if tls

      options.merge(Host: Config.bind_address, Port: Config.front_door_port)
    end

    def create(_id, options)
      emit(registry.create(**options.slice(:branch, :pr, :new_branch, :from)).describe, options)
    end

    def list(_id, options)
      emit(registry.list(pr: options[:pr]), options)
    end

    def show(id, options)
      emit(coordinator.snapshot(id), options)
    end

    def lifecycle(id, options)
      action = proc { run_lifecycle(options.fetch(:command), id) }
      result = options[:json] ? with_stdout_on_stderr(&action) : action.call
      emit(result, options)
      raise ArgumentError, result['last_error'] if result['status'] == 'error'
    end

    def run_lifecycle(command, id)
      started = command == 'restart' ? coordinator.restart(id) : coordinator.start(id, force: command == 'prepare')
      if !started && coordinator.snapshot(id)['active']
        raise ArgumentError, 'Workspace is busy; inspect it with show --json'
      end

      coordinator.wait(id)
    end

    def stop(id, options)
      registry.with_lock(id) do
        Backend.new(id).stop!
        StateStore.new(Config.state_file).set(id, 'status' => 'stopped', 'message' => 'Server stopped')
      end
      emit(coordinator.snapshot(id), options)
    end

    def remove(id, options)
      registry.remove(id, force: options[:force])
      emit({ 'id' => id, 'removed' => true, 'branch_preserved' => true }, options)
    end

    def execute(argv)
      id = argv.shift
      unless argv.shift == '--' && !argv.empty?
        raise ArgumentError,
              'Usage: workspaces exec ID -- COMMAND [ARGUMENTS...]'
      end

      registry.with_lock(id) do |workspace|
        child_env = ChildEnv.for_workspace(workspace_path: workspace.path)
        pid = Process.spawn(child_env, [argv.first, argv.first], *argv.drop(1),
                            chdir: workspace.path.to_s, unsetenv_others: true)
        _, status = Process.wait2(pid)
        status.exitstatus || (128 + status.termsig)
      end
    end

    def with_stdout_on_stderr
      previous = $stdout
      $stdout = $stderr
      yield
    ensure
      $stdout = previous
    end

    def emit(data, options)
      puts(options[:json] ? JSON.generate(data) : JSON.pretty_generate(data))
    end

    def usage
      'Usage: bin/workspaces serve | create (--branch REF | --pr NUMBER | --new-branch NAME [--from REF]) [--json] | ' \
        'list [--pr NUMBER] [--json] | show/start/prepare/restart/stop ID [--json] | ' \
        'exec ID -- COMMAND... | remove ID [--force]'
    end

    def help(*)
      puts usage
    end
  end
end
