require 'erb'
require 'json'
require 'time'
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
        <main class="dashboard"><header class="dashboard__header"><h1>Workspaces</h1><p class="dashboard__note">#{view.inventory_summary(workspaces)}</p></header>
        <section class="status-panel" aria-labelledby="create-heading"><h2 id="create-heading">Create workspace</h2>
        <p>Pick an existing branch, a PR number, or a new branch. Each submission creates its own managed worktree.</p>
        <form method="post" action="/workspaces/create" class="stack">
          <div class="create-fields">
            <div class="field"><label for="create-branch">Existing branch</label><input id="create-branch" name="branch" placeholder="main" autocomplete="off" spellcheck="false"></div>
            <div class="field"><label for="create-pr">PR number</label><input id="create-pr" name="pr" inputmode="numeric" placeholder="43828" autocomplete="off"></div>
            <div class="field"><label for="create-new-branch">New branch</label><input id="create-new-branch" name="new_branch" placeholder="agent/fix-checkout" autocomplete="off" spellcheck="false"></div>
            <div class="field"><label for="create-from">Start new branch from</label><input id="create-from" name="from" placeholder="HEAD" autocomplete="off" spellcheck="false"></div>
          </div>
          <button type="submit" class="button button--primary">Create workspace</button>
        </form></section>
        <section class="status-panel" aria-labelledby="inventory-heading"><h2 id="inventory-heading">Managed workspaces</h2>
        #{view.inventory_table(workspaces)}
        </section></main>
      HTML
    end

    # The default page for a workspace: one small card with the headline, progress and the single
    # next action. Everything else lives on the settings page.
    def self.card(snapshot, preview: false)
      new(snapshot, preview: preview).render_card
    end

    PREVIEW_STATUS_KEYS = %w(state busy ready headline summary progress lead_action current_preset sleep open).freeze
    PREVIEW_ERROR = 'Setup failed. Open settings for the full log.'.freeze

    # What the card polls for on a preview host, where the workspace's own pages share the origin.
    # Only what the card draws: no log, no steps, no environment and no error text.
    def self.preview_status(snapshot)
      view = Presentation.new(snapshot).to_h
      slim = view.slice(*PREVIEW_STATUS_KEYS).merge('error' => view['error'] ? PREVIEW_ERROR : '')
      { 'presentation' => slim, 'prepare_started_at' => snapshot['prepare_started_at'],
        'completed_at' => snapshot['completed_at'] }
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

    def initialize(snapshot, preview: false)
      @snapshot = snapshot
      @preview = preview
      @presentation = Presentation.new(snapshot).to_h
    end

    def render
      @id = Config.validate_id!(@snapshot.fetch('workspace_id'))
      document("Workspace #{@id}",
               ERB.new(File.read(File.join(__dir__, 'dashboard/template.html.erb'),
                                 encoding: 'UTF-8')).result(binding))
    end

    # On a preview host the card is served from the workspace's own origin, so its controls go to the
    # front door's reserved /__workspaces/ endpoints, it never shows error text, and it reloads the
    # page the visitor asked for once the workspace is ready.
    def render_card
      @id = Config.validate_id!(@snapshot.fetch('workspace_id'))
      @presentation = @presentation.merge('error' => PREVIEW_ERROR) if @preview && @presentation['error']
      document("Workspace #{@id}",
               ERB.new(File.read(File.join(__dir__, 'dashboard/card.html.erb'),
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
        <div class="table-scroll">
        <table class="workspace-table">
          <thead><tr><th scope="col">Workspace</th><th scope="col">Status</th><th scope="col" class="workspace-table__date">Created (UTC)</th><th scope="col" class="workspace-table__date">Last startup (UTC)</th></tr></thead>
          <tbody>
        #{by_last_startup(workspaces).map { |workspace| inventory_row(workspace) }.join}
          </tbody>
        </table>
        </div>
      HTML
    end

    # Most recently started first; workspaces that have never started (or whose start time cannot be read)
    # come last. Moments are compared as moments, not as text, so a different UTC offset or fraction cannot
    # misorder rows, and ties fall back to the id so the list never shuffles between loads.
    def by_last_startup(workspaces)
      workspaces.sort_by do |workspace|
        started = startup_moment(workspace['started_at'])
        [started ? 0 : 1, started ? -started.to_r : 0, workspace['id'].to_s]
      end
    end

    def startup_moment(value)
      return nil if value.nil? || value.to_s.empty?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # "8 managed worktrees · none running", counted from the data on the page.
    def inventory_summary(workspaces)
      total = workspaces.length
      running = workspaces.count { |workspace| workspace['running'] }
      noun = total == 1 ? 'managed worktree' : 'managed worktrees'
      "#{total} #{noun} · #{running.zero? ? 'none running' : "#{running} running"}"
    end

    # "Oct 27, 10:48" in UTC, with the full value kept in the title. Anything that is not a timestamp is
    # shown as it came rather than guessed at.
    def short_time(value)
      Time.iso8601(value.to_s).utc.strftime('%b %-d, %H:%M')
    rescue ArgumentError
      value.to_s
    end

    def time_cell(value, empty)
      return "<span class=\"never\">#{empty}</span>" if value.nil? || value.to_s.empty?

      "<time datetime=\"#{escape(value)}\" title=\"#{escape(value)}\">#{escape(short_time(value))}</time>"
    end

    # The word shown in a status pill. What the workspace is doing is the word; whether a server is
    # up is the dot's job elsewhere, so there is no repeated "Not running ·" prefix.
    def status_text(workspace)
      status = (workspace['status'] || 'idle').to_s
      status = status.capitalize
      workspace['active'] ? "#{status} (busy)" : status
    end

    def inventory_row(workspace)
      id = escape(Config.validate_id!(workspace.fetch('id')))
      status = escape(workspace['status'] || 'idle')
      <<~HTML
        <tr>
          <th scope="row"><a href="/workspaces/#{id}">#{id}</a></th>
          <td><span class="status-pill" data-status="#{status}" data-busy="#{workspace['active'] ? 'true' : 'false'}"><span class="status-dot" aria-hidden="true"></span>#{escape(status_text(workspace))}</span></td>
          <td class="workspace-table__date">#{time_cell(workspace['created_at'], 'Unavailable')}</td>
          <td class="workspace-table__date">#{time_cell(workspace['started_at'], 'Never')}</td>
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

    # The rows the settings form starts with: visible variables with their values, then secrets by
    # name only. A secret row never carries a value, so there is nothing to leak into the page.
    def environment_rows
      values = @snapshot['editable_environment']
      plain = values.is_a?(Hash) ? values.sort.map { |name, value| { 'name' => name.to_s, 'value' => value.to_s, 'secret' => false } } : []
      names = @snapshot['secret_names']
      secrets = names.is_a?(Array) ? names.map(&:to_s).sort.map { |name| { 'name' => name, 'value' => '', 'secret' => true } } : []
      plain + secrets
    end

    # What a preset loads: its rows in the same shape. Secrets are untouched by presets.
    def environment_preset_rows
      environment_presets_raw.transform_values do |entries|
        entries.sort.map { |name, value| { 'name' => name.to_s, 'value' => value.to_s } }
      end
    end

    # One row of the settings form. Plain rows show their value. Secret rows have a password field,
    # never pre-filled, with a placeholder saying a value is stored. The secret checkbox is the only
    # thing that decides which store a row goes to, and it is disabled for a stored secret so a
    # saved secret cannot be quietly turned into a visible variable.
    # Keeps password managers from offering to fill, save or generate anything for these inputs. No
    # single attribute does it: `autocomplete="off"` is ignored on password fields, so each manager's
    # own opt-out goes alongside it (1Password, LastPass, Bitwarden).
    NO_AUTOFILL = 'autocomplete="off" data-1p-ignore data-lpignore="true" data-bwignore'

    # One row of the settings form.
    #
    # A stored secret has no value input at all: just its name, a note, and a Replace button that
    # adds the input when it is clicked. So the page holds no password field for a password manager
    # to find until someone asks to replace one. (Without script, the input sits inside <noscript> so
    # a secret can still be replaced.) A row posted with no value keeps what is stored.
    #
    # The secret checkbox is disabled for a stored secret, with a hidden field carrying it, so a
    # saved secret cannot be quietly turned into a visible variable.
    def env_row_html(index, row)
      secret = row['secret']
      stored = secret && !row['name'].to_s.empty?
      <<~HTML.delete("\n")
        <div class="env-row" data-env-row#{secret ? ' data-secret="true"' : ''}#{stored ? ' data-stored="true"' : ''}>
        <input class="env-row__name" name="env[#{index}][name]" value="#{escape(row['name'])}" placeholder="NAME" aria-label="Variable name" spellcheck="false" #{NO_AUTOFILL} autocapitalize="off">
        #{stored ? stored_value_html(index) : value_input_html(index, row)}
        <label class="env-row__secret"><input type="checkbox" name="env[#{index}][secret]" value="1" data-env-secret#{secret ? ' checked' : ''}#{stored ? ' disabled' : ''}> Secret</label>
        #{stored ? "<input type=\"hidden\" name=\"env[#{index}][secret]\" value=\"1\">" : ''}
        <button type="button" class="button button--subtle button--small" data-env-remove-row aria-label="Remove variable" hidden>Remove</button>
        </div>
      HTML
    end

    def value_input_html(index, row, placeholder: nil)
      secret = row['secret']
      placeholder ||= secret ? 'Value' : 'value'
      %(<input class="env-row__value" name="env[#{index}][value]" type="#{secret ? 'password' : 'text'}" value="#{secret ? '' : escape(row['value'])}" placeholder="#{escape(placeholder)}" aria-label="Value" spellcheck="false" #{NO_AUTOFILL} autocapitalize="off" data-env-value>)
    end

    def stored_value_html(index)
      '<span class="env-row__stored" data-env-stored><span class="muted">Stored. Write-only.</span> ' \
        '<button type="button" class="button button--subtle button--small" data-env-replace hidden>Replace</button></span>' \
        "<noscript>#{value_input_html(index, { 'secret' => true }, placeholder: 'New value (leave blank to keep)')}</noscript>"
    end

    def environment_presets_raw
      presets = @snapshot['environment_presets']
      return {} unless presets.is_a?(Hash)

      presets.select { |name, entries| name.respond_to?(:to_s) && entries.is_a?(Hash) }.transform_keys(&:to_s)
    end

    def vault_status
      vault = @snapshot['vault']
      vault.is_a?(Hash) ? vault : { 'available' => false, 'problem' => nil }
    end

    # The preset names and values the buttons are built from.
    def environment_presets
      environment_presets_raw
    end

    def environment_presets_json
      JSON.generate(environment_preset_rows)
    end

    # The lead's primary action. `open` is rendered separately as a link (it needs the
    # preview URL and must stay a real anchor), so only lifecycle posts produce a form.
    def lead_action_form(action)
      return '' unless action && action['kind'] == 'post'

      "<form method=\"post\" action=\"#{action_base}/#{action.fetch('key')}\">" \
        "<button class=\"button button--primary button--large\">#{escape(action.fetch('label'))}</button></form>"
    end

    def action_base
      @preview ? '/__workspaces' : "/workspaces/#{@id}"
    end

    def settings_href
      @preview ? Config.settings_url(@id) : "/workspaces/#{@id}/settings"
    end

    # Where the card's start form posts. A shared card with presets saves the chosen one through the
    # environment form; a preview card starts through its own origin.
    def start_form_action
      return "#{action_base}/start" if @preview || environment_presets.empty?

      "/workspaces/#{@id}/environment"
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

    def sleep_note
      sleep = @presentation['sleep']
      return '' unless sleep
      return 'Kept awake: this workspace will not sleep when idle.' if sleep['keep_awake']
      return '' unless @presentation['state'] == 'ready'

      minutes = (sleep['after_seconds'] / 60.0).round
      "Sleeps after #{minutes >= 1 ? "#{minutes} min" : "#{sleep['after_seconds'].round} s"} without preview traffic."
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
    # Small forms for re-running just this step or this step and everything after it, shown only
    # for what the workspace can actually do right now (the server decides, not the page).
    def step_controls(step)
      modes = @presentation.dig('resume', 'step_modes')&.fetch(step['key'], nil)
      return '' if modes.nil? || modes.empty?

      last = @presentation['steps'].last
      key = ERB::Util.url_encode(step['key'].to_s)
      forms = []
      forms << step_control(key, 'only', 'Re-run this step') if modes.include?('only')
      forms << step_control(key, 'from', 'Re-run from here') if modes.include?('from') && !(modes.include?('only') && last && last['key'] == step['key'])
      %(<div class="step-log__actions">#{forms.join}</div>)
    end

    def step_control(key, mode, label)
      "<form method=\"post\" action=\"/workspaces/#{@id}/resume?#{mode}=#{key}\">" \
        "<button class=\"button button--subtle button--small\">#{label}</button></form>"
    end

    def step_accordion(step)
      key = escape(step['key'])
      state = escape(step['state'])
      entry = (@snapshot['step_logs'] || {})[step['key']]
      open = %w(active failed).include?(step['state']) ? ' open' : ''
      current = step['state'] == 'active' ? ' aria-current="step"' : ''
      <<~HTML
        <details class="step-log" data-step-log="#{key}" data-step-state="#{state}"#{open}#{current}>
          <summary><span class="step-log__status" aria-hidden="true"></span><span class="step-log__name">#{escape(step['label'])}</span><span class="step-log__outcome step-outcome">#{escape(step_outcome(step))}</span></summary>
          #{step_controls(step)}
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
