require_relative 'progress'

module Workspaces
  class Presentation
    TITLES = { 'idle' => 'Ready to start', 'stopped' => 'Server stopped', 'ready' => 'Workspace ready',
               'sleeping' => 'Workspace asleep',
               'preparing' => 'Running setup', 'error' => 'Setup failed',
               'interrupted' => 'Setup interrupted' }.freeze
    ACTIONS = { 'start' => 'Start workspace', 'prepare' => 'Rebuild & restart',
                'restart' => 'Restart server', 'stop' => 'Stop server',
                'resume' => 'Retry failed step', 'keep-awake' => 'Keep awake',
                'allow-sleep' => 'Allow sleep' }.freeze

    # The sections of the settings page, from friendly to technical. `lead` is the headline, one
    # sentence and at most one primary action. `environment` (presets and variables) is the area for
    # deliberately changing something. `technical` holds setup steps, logs, workspace details,
    # lifecycle controls and deletion. All of them are plain sections, always open when shown: the
    # card at /workspaces/ID is what keeps the details out of the way, so this page has nothing to
    # fold. Setup steps are not a section of their own: each has its own log row inside `log`.
    SECTIONS = %w(lead actions environment technical log details danger).freeze
    TECHNICAL = %w(technical actions log details danger).freeze

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
    # Per state: `headline` and `summary` are plain language, `sections` says which sections are
    # shown, and `environment_submit` / `environment_title` word the settings form.
    STATES = {
      'idle' => {
        sections: %w(lead environment),
        headline: "Let's get your workspace running",
        summary: 'Pick the version of the site you want to preview, then start. Setup usually takes a few minutes.',
        environment_submit: 'Start workspace', environment_title: 'Choose what to preview'
      },
      'busy' => {
        sections: %w(lead technical log),
        headline: 'Setting things up…',
        summary: 'This page keeps itself up to date. Open the preview once it is ready.',
        environment_submit: 'Save & restart', environment_title: 'Change settings'
      },
      'ready' => {
        sections: %w(lead environment) + TECHNICAL,
        headline: 'Your workspace is ready',
        summary: 'Everything is set up and running. Open it to see your changes.',
        environment_submit: 'Save & restart', environment_title: 'Change settings'
      },
      'sleeping' => {
        sections: %w(lead environment) + TECHNICAL,
        headline: 'Your workspace is asleep',
        summary: 'It went quiet, so its server was stopped to free up resources. Your files and data are kept. ' \
                 'Opening the preview wakes it in a few seconds.',
        environment_submit: 'Save & start', environment_title: 'Change settings'
      },
      'stopped' => {
        sections: %w(lead environment) + TECHNICAL,
        headline: 'Your workspace is paused',
        summary: 'Start it again to pick up where you left off.',
        environment_submit: 'Save & start', environment_title: 'Change settings'
      },
      'error' => {
        sections: %w(lead environment) + TECHNICAL,
        headline: "Something didn't go to plan",
        summary: 'Setup stopped before it finished. You can try again, or change settings first.',
        environment_submit: 'Save & retry', environment_title: 'Change settings'
      },
      'interrupted' => {
        sections: %w(lead environment) + TECHNICAL,
        headline: 'Setup was interrupted',
        summary: 'It stopped before it finished. Try again to pick up from the start.',
        environment_submit: 'Save & retry', environment_title: 'Change settings'
      },
      'unknown' => {
        sections: %w(lead technical log details),
        headline: 'Workspace status unknown',
        summary: 'Open the technical details to see what the workspace is doing.',
        environment_submit: 'Save & restart', environment_title: 'Change settings'
      }
    }.freeze

    def initialize(snapshot)
      @snapshot = snapshot
    end

    def to_h
      { 'title' => title, 'busy' => busy?, 'error' => error, 'steps' => steps,
        'actions' => actions, 'ready' => status == 'ready' && !busy?,
        'state' => state, 'sections' => sections,
        'headline' => definition[:headline], 'summary' => summary, 'resume' => resume,
        'lead_action' => lead_action, 'total' => total, 'progress' => progress,
        'current_preset' => current_preset, 'sleep' => sleep_info,
        'environment_title' => definition[:environment_title],
        'environment_submit' => definition[:environment_submit] }
    end

    private

    def status
      @snapshot.fetch('status', 'idle')
    end

    # What the page needs to explain sleeping: whether this workspace is kept awake, and after how
    # long an idle one sleeps. Nil for states where sleeping is not in play.
    def sleep_info
      return nil unless %w(ready sleeping).include?(status) && !@snapshot['sleep_after_seconds'].nil?

      { 'keep_awake' => !!@snapshot['keep_awake'], 'after_seconds' => @snapshot['sleep_after_seconds'] }
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
      visible = definition[:sections]
      SECTIONS.to_h { |name| [name, visible.include?(name)] }
    end

    # The single most useful thing to do next, or nil when the user should just wait.
    # `open` links straight to the preview; the others are lifecycle form posts. After a failure the
    # first offer is to carry on from where it stopped; a full re-run stays one click away.
    def lead_action
      case state
      when 'ready' then { 'kind' => 'open', 'label' => 'Open workspace' }
      when 'stopped' then { 'kind' => 'post', 'key' => 'start', 'label' => 'Start workspace' }
      when 'sleeping' then { 'kind' => 'post', 'key' => 'start', 'label' => 'Wake workspace' }
      when 'error', 'interrupted' then (retryable? ? resume_action : retry_action).merge('kind' => 'post')
      end
    end

    # What a re-run of part of the last run could do, for the per-step controls and the retry
    # wording. Nil while a run is in progress, or when the recorded steps cannot be re-run.
    def resume
      info = @snapshot['resume']
      return nil if busy? || !info.is_a?(Hash)

      failed = steps.find { |step| step['state'] == 'failed' }
      { 'step_modes' => info['step_modes'] || {}, 'retry_from' => info['retry_from'],
        'retry_label' => info['retry_label'], 'failed_label' => failed && failed['label'] }
    end

    def retryable?
      %w(error interrupted).include?(status) && !resume.nil? && !resume['retry_from'].nil?
    end

    def resume_action
      action('resume', true).merge('label' => status == 'interrupted' ? 'Continue setup' : 'Retry failed step')
    end

    # Plain words for what a retry will do, naming the step. A failure at or after the server step
    # restarts the server (a failed run stops it), so say where the retry really begins.
    def summary
      return definition[:summary] unless retryable?

      info = resume
      failed = info['failed_label'] || info['retry_label']
      lead = status == 'interrupted' ? "Setup was interrupted during \"#{failed}\"." : "\"#{failed}\" didn't finish."
      from = info['retry_label'] == failed ? 'it' : "from \"#{info['retry_label']}\""
      "#{lead} Retrying runs #{from} again and keeps everything that already finished."
    end

    # The preset whose values exactly equal the workspace's saved editable settings, or nil when
    # there are no presets or the settings match none (for example after a hand edit). Presets
    # arrive already completed with the recipe defaults, so equality is a plain comparison.
    def current_preset
      presets = @snapshot['environment_presets']
      current = @snapshot['editable_environment']
      return nil unless presets.is_a?(Hash) && current.is_a?(Hash) && !current.empty?

      normalized = stringify(current)
      presets.find { |_name, values| values.is_a?(Hash) && stringify(values) == normalized }&.first&.to_s
    end

    def stringify(values)
      values.to_h { |name, value| [name.to_s, value.to_s] }
    end

    # How long the last run took and how it ended, or nil while one is in progress or when no
    # total was recorded (interrupted runs, and workspaces set up before totals were persisted).
    def total
      seconds = @snapshot['total_seconds']
      return nil if busy? || !seconds.is_a?(Numeric)

      failed = status == 'error' || steps.any? { |step| step['state'] == 'failed' }
      { 'state' => failed ? 'failed' : 'complete', 'seconds' => seconds }
    end

    # The progress bar's numbers, only while a build is being prepared (not for a lone command
    # on a ready workspace, which has no steps of its own to measure).
    def progress
      return nil unless status == 'preparing' && !steps.empty?

      Progress.new(steps: steps, estimates: @snapshot['estimates'], started_at: @snapshot['prepare_started_at']).to_h
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
                    %w(prepare restart stop).map { |key| action(key, false) } + keep_awake_actions
                  elsif status == 'sleeping'
                    [action('start', true).merge('label' => 'Wake workspace')] + keep_awake_actions
                  elsif retryable?
                    [resume_action, retry_action.merge('label' => 'Re-run all steps', 'primary' => false)]
                  elsif %w(error interrupted).include?(status)
                    [retry_action]
                  else
                    [action('start', true)]
                  end
      available << { 'key' => 'update-pr', 'label' => 'Update from PR', 'primary' => false } if @snapshot.dig('source', 'kind') == 'pr'
      available

    end

    def keep_awake_actions
      return [] if @snapshot['sleep_after_seconds'].nil?

      [action(@snapshot['keep_awake'] ? 'allow-sleep' : 'keep-awake', false)]
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
