module Workspaces
  class Presentation
    TITLES = { 'idle' => 'Ready to start', 'stopped' => 'Server stopped', 'ready' => 'Workspace ready',
               'preparing' => 'Running setup', 'error' => 'Setup failed',
               'interrupted' => 'Setup interrupted' }.freeze
    ACTIONS = { 'start' => 'Start workspace', 'prepare' => 'Rebuild & restart',
                'restart' => 'Restart server', 'stop' => 'Stop server' }.freeze

    SECTIONS = %w(progress actions environment log details danger).freeze
    MANAGEABLE = SECTIONS

    # Workspace lifecycle state machine. Each state declares only what is usable and
    # meaningful there; everything else is hidden rather than shown disabled.
    #
    #   idle ──start──▶ busy ──▶ ready ◀──▶ busy
    #                     │        │
    #                     ▼        ▼
    #                   error   stopped ──start──▶ busy
    #                (interrupted)
    #
    # `environment_submit` labels the single environment-form button, which saves the
    # settings and (re)starts the workspace, so a brand new workspace needs only that.
    STATES = {
      'idle' => {
        sections: %w(environment),
        environment_submit: 'Start workspace', controls_title: 'Set up your workspace',
        hint: 'Choose the environment you want to preview below, then start the workspace. ' \
              'Setup usually takes a few minutes.'
      },
      'busy' => { sections: %w(progress log), environment_submit: 'Save & restart' },
      'ready' => { sections: MANAGEABLE, environment_submit: 'Save & restart' },
      'stopped' => { sections: %w(actions environment log details danger), environment_submit: 'Save & start' },
      'error' => { sections: MANAGEABLE, environment_submit: 'Save & retry' },
      'interrupted' => { sections: MANAGEABLE, environment_submit: 'Save & retry' },
      'unknown' => { sections: %w(log details), environment_submit: 'Save & restart' }
    }.freeze

    def initialize(snapshot)
      @snapshot = snapshot
    end

    def to_h
      { 'title' => title, 'busy' => busy?, 'error' => error, 'steps' => steps,
        'actions' => actions, 'ready' => status == 'ready' && !busy?,
        'state' => state, 'sections' => sections, 'hint' => definition[:hint],
        'controls_title' => definition.fetch(:controls_title, 'Actions & settings'),
        'environment_submit' => definition[:environment_submit] }
    end

    private

    def status
      @snapshot.fetch('status', 'idle')
    end

    def busy?
      @snapshot['active'] || status == 'preparing'
    end

    def state
      return 'busy' if busy?

      STATES.key?(status) ? status : 'unknown'
    end

    def definition
      STATES.fetch(state)
    end

    def sections
      visible = definition[:sections].dup
      visible.delete('progress') if steps.empty? || %w(idle stopped).include?(state)
      SECTIONS.to_h { |name| [name, visible.include?(name)] }
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
      available = if status == 'ready'
                    %w(prepare restart stop).map { |key| action(key, false) }
                  elsif %w(error interrupted).include?(status)
                    [retry_action]
                  else
                    [action('start', true)]
                  end
      available << { 'key' => 'update-pr', 'label' => 'Update from PR', 'primary' => false } if @snapshot.dig('source', 'kind') == 'pr'
      available

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
