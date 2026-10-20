require 'erb'
require 'json'
require_relative 'config'
require_relative 'presentation'
require_relative 'duration_format'

module Workspaces
  class DashboardView
    def self.render(snapshot)
      new(snapshot).render
    end

    def self.index(workspaces)
      view = new({})
      view.document('Workspaces', <<~HTML)
        <main class="dashboard"><header class="dashboard__header"><h1>Workspaces</h1></header>
        <section class="status-panel"><h2>Create workspace</h2>
        <p>Choose a branch, PR number, or new branch. Every submission creates a separate managed worktree.</p>
        <form method="post" action="/workspaces/create" class="stack">
          <label class="field">Existing branch <input name="branch" placeholder="main"></label>
          <label class="field">PR number <input name="pr" inputmode="numeric" placeholder="43828"></label>
          <label class="field">New branch <input name="new_branch" placeholder="agent/fix-checkout"></label>
          <label class="field">Start new branch from <input name="from" placeholder="HEAD"></label>
          <button class="button button--primary">Create workspace</button>
        </form></section>
        <section class="status-panel"><h2>Managed workspaces</h2>
        #{view.inventory_table(workspaces)}
        </section></main>
      HTML
    end

    def self.pull_request(number, workspaces)
      new({}).render_pull_request(number, workspaces)
    end

    def self.checkout_authentication_error(path)
      new({}).render_checkout_authentication_error(path)
    end

    def self.favicon
      local = Config.public_uri.host.match?(/(?:\A|\.)localhost\z/i)
      color = local ? '#4f8dff' : '#f1bb53'
      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="Workspaces">
          <rect x="3" y="3" width="58" height="58" rx="13" fill="#0f1524"/>
          <rect x="11" y="13" width="42" height="38" rx="5" fill="none" stroke="#{color}" stroke-width="4"/>
          <path d="M11 25h42M32 25v26" fill="none" stroke="#{color}" stroke-width="4"/>
          <circle cx="18" cy="19" r="2" fill="#{color}"/>
          <circle cx="25" cy="19" r="2" fill="#{color}"/>
        </svg>
      SVG
    end

    def initialize(snapshot)
      @snapshot = snapshot
      @presentation = Presentation.new(snapshot).to_h
    end

    def render
      @id = Config.validate_id!(@snapshot.fetch('workspace_id'))
      document("Workspace #{@id}",
               ERB.new(File.read(File.join(__dir__, 'dashboard/template.html.erb'),
                                 encoding: 'UTF-8')).result(binding))
    end

    def render_pull_request(number, workspaces)
      @number = number
      @workspaces = workspaces
      template = File.read(File.join(__dir__, 'dashboard/pull_request.html.erb'))
      document("PR ##{number} workspaces", ERB.new(template).result(binding))
    end

    def render_checkout_authentication_error(path)
      @retry_path = path if path.match?(%r{\A/pr/[1-9][0-9]*\z})
      template = File.read(File.join(__dir__, 'dashboard/checkout_authentication_error.html.erb'))
      document('GitHub access needs setup', ERB.new(template).result(binding))
    end

    def document(title, body)
      css = File.read(File.join(__dir__, 'dashboard/styles.css'), encoding: 'UTF-8')
      script = File.read(File.join(__dir__, 'dashboard/app.js'), encoding: 'UTF-8') +
               File.read(File.join(__dir__, 'dashboard/environment.js'), encoding: 'UTF-8')
      '<!doctype html><html lang="en"><head><meta charset="utf-8">' \
        '<meta name="viewport" content="width=device-width, initial-scale=1">' \
        '<link rel="icon" type="image/svg+xml" href="/favicon.svg">' \
        "<title>#{escape(title)}</title><style>#{css}</style></head>" \
        "<body>#{body}<script>#{script}</script></body></html>"
    end

    def escape(value)
      ERB::Util.html_escape(value.to_s)
    end

    # Tabular data gets a real table. The workspace ID is both the row header and the
    # link, so no separate name/branch/link columns are needed. Narrow screens hide the
    # date columns and stack each row (see styles.css).
    def inventory_table(workspaces)
      return '<p class="muted">No workspaces yet.</p>' if workspaces.empty?

      <<~HTML
        <table class="workspace-table">
          <thead><tr><th scope="col">Workspace</th><th scope="col">Status</th><th scope="col" class="workspace-table__date">Created</th><th scope="col" class="workspace-table__date">Last startup</th></tr></thead>
          <tbody>
        #{workspaces.map { |workspace| inventory_row(workspace) }.join}
          </tbody>
        </table>
      HTML
    end

    def inventory_row(workspace)
      id = escape(Config.validate_id!(workspace.fetch('id')))
      status = escape(workspace['status'] || 'idle')
      running = workspace['running'] ? 'Running' : 'Not running'
      <<~HTML
        <tr>
          <th scope="row"><a href="/workspaces/#{id}">#{id}</a></th>
          <td><span class="status-pill" data-status="#{status}"><span class="status-dot" aria-hidden="true"></span>#{running} · #{status}#{workspace['active'] ? ' (busy)' : ''}</span></td>
          <td class="workspace-table__date"><time datetime="#{escape(workspace['created_at'])}">#{escape(workspace['created_at'] || 'Unavailable')}</time></td>
          <td class="workspace-table__date"><time datetime="#{escape(workspace['started_at'])}">#{escape(workspace['started_at'] || 'Never')}</time></td>
        </tr>
      HTML
    end

    private

    def section?(name)
      @presentation.fetch('sections', {})[name]
    end

    def field(name)
      escape(@snapshot[name])
    end

    def environment_keys
      keys = @snapshot['environment_keys']
      return [] unless keys.is_a?(Array)

      keys.map(&:to_s).sort
    end

    def editable_environment_text
      values = @snapshot['editable_environment']
      return '' unless values.is_a?(Hash)

      values.sort.map { |name, value| "#{name}=#{value}" }.join("\n")
    end

    def environment_presets
      presets = @snapshot['environment_presets']
      return {} unless presets.is_a?(Hash)

      presets.each_with_object({}) do |(name, entries), memo|
        next unless name.respond_to?(:to_s)
        next unless entries.is_a?(Hash)

        lines = entries.sort.map { |entry_name, value| "#{entry_name}=#{value}" }.join("\n")
        memo[name.to_s] = lines
      end
    end

    def environment_presets_json
      JSON.generate(environment_presets)
    end

    # The lead's primary action. `open` is rendered separately as a link (it needs the
    # preview URL and must stay a real anchor), so only lifecycle posts produce a form.
    def lead_action_form(action)
      return '' unless action && action['kind'] == 'post'

      "<form method=\"post\" action=\"/workspaces/#{@id}/#{action.fetch('key')}\">" \
        "<button class=\"button button--primary button--large\">#{escape(action.fetch('label'))}</button></form>"
    end

    def action_form(action)
      style = action['primary'] ? 'button--primary' : 'button--subtle'
      "<form method=\"post\" action=\"/workspaces/#{@id}/#{action.fetch('key')}\">" \
        "<button class=\"button #{style}\">#{escape(action.fetch('label'))}</button></form>"
    end

    # The Full setup log row's right-hand label: how the last run ended and how long it took.
    def full_log_outcome
      return 'in progress' if @presentation['busy']

      total = @presentation['total']
      text = total && DurationFormat.call(total['seconds'])
      text ? "#{total['state']} · #{text}" : 'everything, in order'
    end

    # The bar's text, rendered on the server for the first paint; app.js keeps it current after that.
    def progress
      @presentation['progress'] || {}
    end

    def progress_percent
      progress.fetch('percent', 0)
    end

    def progress_step_text
      return '' if progress.empty?

      "#{progress['step_text']} · #{progress['step_label']}"
    end

    def progress_elapsed_text
      DurationFormat.call(progress['elapsed_seconds']) || '—'
    end

    def progress_eta_suffix
      progress['eta_text'] ? " · #{progress['eta_text']}" : ''
    end

    def progress_valuetext
      return '' if progress.empty?

      [progress_step_text, progress['eta_text']].compact.join('. ')
    end

    def preset_badge_text
      name = @presentation['current_preset']
      name ? "Preset: #{name}" : ''
    end

    def backend_tab?
      @snapshot['log_source'] == 'backend' || @snapshot['backend_log_available']
    end

    # One GitHub-Actions-style accordion per recipe step. A step that is running or has
    # failed starts open; a completed or not-yet-started one starts closed.
    def step_accordion(step)
      key = escape(step['key'])
      state = escape(step['state'])
      entry = (@snapshot['step_logs'] || {})[step['key']]
      open = %w(active failed).include?(step['state']) ? ' open' : ''
      current = step['state'] == 'active' ? ' aria-current="step"' : ''
      <<~HTML
        <details class="step-log" data-step-log="#{key}" data-step-state="#{state}"#{open}#{current}>
          <summary><span class="step-log__status" aria-hidden="true"></span><span class="step-log__name">#{escape(step['label'])}</span><span class="step-log__outcome step-outcome">#{escape(step_outcome(step))}</span></summary>
          <pre tabindex="0" aria-label="#{escape(step['label'])} output">#{entry ? escape(entry['text']) : ''}</pre>
        </details>
      HTML
    end

    def step_outcome(step)
      state = step['state'].to_s
      return state unless %w(complete failed).include?(state)

      text = DurationFormat.call(step['duration_seconds'])
      text ? "#{state} · #{text}" : state
    end
  end
end
