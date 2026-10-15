module Workspaces
  class Presentation
    TITLES = { 'idle' => 'Ready to start', 'stopped' => 'Server stopped', 'ready' => 'Workspace ready',
               'preparing' => 'Running setup', 'error' => 'Setup failed',
               'interrupted' => 'Setup interrupted' }.freeze
    ACTIONS = { 'start' => 'Start workspace', 'prepare' => 'Rebuild & restart',
                'restart' => 'Restart server', 'stop' => 'Stop server' }.freeze

    # Three layers, from friendly to technical. `lead` is the headline, one sentence and at
    # most one primary action. `environment` (presets and variables) is the area for
    # deliberately changing something. `technical` is one disclosure holding setup steps,
    # logs, workspace details, lifecycle controls and deletion; it is never the first thing
    # a user reads, but it opens by itself when something needs attention.
    SECTIONS = %w(lead progress actions environment technical log details danger).freeze
    TECHNICAL = %w(technical progress actions log details danger).freeze

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
    #
    # Per state: `headline` and `summary` are plain language; `open_environment` and
    # `open_technical` say which disclosures start expanded. A failure always opens the
    # technical section so the cause is visible without hunting for it.
    STATES = {
      'idle' => {
        sections: %w(lead environment),
        headline: "Let's get your workspace running",
        summary: 'Pick the version of the site you want to preview, then start. Setup usually takes a few minutes.',
        environment_submit: 'Start workspace', environment_title: 'Choose what to preview',
        open_environment: true, open_technical: false
      },
      'busy' => {
        sections: %w(lead technical progress log),
        headline: 'Setting things up…',
        summary: "This usually takes a few minutes. We'll take you to the preview when it's ready.",
        environment_submit: 'Save & restart', environment_title: 'Change settings',
        open_environment: false, open_technical: true
      },
      'ready' => {
        sections: %w(lead environment) + TECHNICAL,
        headline: 'Your workspace is ready',
        summary: 'Everything is set up and running. Open it to see your changes.',
        environment_submit: 'Save & restart', environment_title: 'Change settings',
        open_environment: false, open_technical: false
      },
      'stopped' => {
        sections: %w(lead environment) + TECHNICAL,
        headline: 'Your workspace is paused',
        summary: 'Start it again to pick up where you left off.',
        environment_submit: 'Save & start', environment_title: 'Change settings',
        open_environment: false, open_technical: false
      },
      'error' => {
        sections: %w(lead environment) + TECHNICAL,
        headline: "Something didn't go to plan",
        summary: 'Setup stopped before it finished. You can try again, or change settings first.',
        environment_submit: 'Save & retry', environment_title: 'Change settings',
        open_environment: false, open_technical: true
      },
      'interrupted' => {
        sections: %w(lead environment) + TECHNICAL,
        headline: 'Setup was interrupted',
        summary: 'It stopped before it finished. Try again to pick up from the start.',
        environment_submit: 'Save & retry', environment_title: 'Change settings',
        open_environment: false, open_technical: true
      },
      'unknown' => {
        sections: %w(lead technical log details),
        headline: 'Workspace status unknown',
        summary: 'Open the technical details to see what the workspace is doing.',
        environment_submit: 'Save & restart', environment_title: 'Change settings',
        open_environment: false, open_technical: true
      }
    }.freeze

    def initialize(snapshot)
      @snapshot = snapshot
    end

    def to_h
      { 'title' => title, 'busy' => busy?, 'error' => error, 'steps' => steps,
        'actions' => actions, 'ready' => status == 'ready' && !busy?,
        'state' => state, 'sections' => sections,
        'headline' => definition[:headline], 'summary' => definition[:summary],
        'subtitle' => subtitle, 'lead_action' => lead_action,
        'environment_title' => definition[:environment_title],
        'environment_submit' => definition[:environment_submit],
        'open' => { 'environment' => definition[:open_environment], 'technical' => definition[:open_technical] } }
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

    # The single most useful thing to do next, or nil when the user should just wait.
    # `open` links straight to the preview; the others are lifecycle form posts.
    def lead_action
      case state
      when 'ready' then { 'kind' => 'open', 'label' => 'Open workspace' }
      when 'stopped' then { 'kind' => 'post', 'key' => 'start', 'label' => 'Start workspace' }
      when 'error', 'interrupted' then retry_action.merge('kind' => 'post')
      end
    end

    # What is happening right now, in the quiet line under the headline.
    def subtitle
      return nil unless state == 'busy'

      @snapshot['message']
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
