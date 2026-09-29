module Workspaces
  class Presentation
    TITLES = { 'idle' => 'Ready to start', 'stopped' => 'Server stopped', 'ready' => 'Workspace ready',
               'preparing' => 'Running setup', 'error' => 'Setup failed',
               'interrupted' => 'Setup interrupted' }.freeze
    ACTIONS = { 'start' => 'Start workspace', 'prepare' => 'Rebuild & restart',
                'restart' => 'Restart server', 'stop' => 'Stop server' }.freeze

    def initialize(snapshot)
      @snapshot = snapshot
    end

    def to_h
      { 'title' => title, 'busy' => busy?, 'error' => error, 'steps' => steps,
        'actions' => actions, 'ready' => status == 'ready' && !busy? }
    end

    private

    def status
      @snapshot.fetch('status', 'idle')
    end

    def busy?
      @snapshot['active'] || status == 'preparing'
    end

    def title
      return 'Workspace busy' if @snapshot['active'] && !busy_status?
      return @snapshot['message'] || 'Running setup' if status == 'preparing'

      TITLES.fetch(status, 'Workspace status')
    end

    def busy_status?
      status == 'preparing'
    end

    def error
      return @snapshot['last_error'] unless status == 'interrupted'

      'The setup process stopped before it finished. Retry to continue.'
    end

    def steps
      @snapshot.fetch('steps', []).map do |step|
        step.merge('state' => status == 'interrupted' && step['state'] == 'active' ? 'failed' : step['state'])
      end
    end

    def actions
      return [] if busy?
      return %w(prepare restart stop).map { |key| action(key, false) } if status == 'ready'
      return [retry_action] if %w(error interrupted).include?(status)

      [action('start', true)]
    end

    def retry_action
      restart = @snapshot['operation'] == 'restart'
      action(restart ? 'restart' : 'prepare', true).merge('label' => restart ? 'Retry restart' : 'Retry setup')
    end

    def action(key, primary)
      { 'key' => key, 'label' => ACTIONS.fetch(key), 'primary' => primary }
    end
  end
end
