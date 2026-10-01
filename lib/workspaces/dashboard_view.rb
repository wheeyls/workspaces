require 'erb'
require_relative 'config'
require_relative 'presentation'

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
        <form method="post" action="/workspaces/create">
          <p><label>Existing branch <input name="branch" placeholder="main"></label></p>
          <p><label>PR number <input name="pr" inputmode="numeric" placeholder="43828"></label></p>
          <p><label>New branch <input name="new_branch" placeholder="agent/fix-checkout"></label></p>
          <p><label>Start new branch from <input name="from" placeholder="HEAD"></label></p>
          <button class="button button--primary">Create workspace</button>
        </form></section>
        <section class="status-panel"><h2>Managed workspaces</h2><ul class="workspace-list">
        #{workspaces.map { |workspace| view.inventory_item(workspace) }.join}
        </ul></section></main>
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

    def inventory_item(workspace)
      id = escape(Config.validate_id!(workspace.fetch('id')))
      running = workspace['running'] ? 'Running' : 'Not running'
      <<~HTML
        <li class="workspace-list__item">
          <a href="/workspaces/#{id}">#{id}</a>
          <span class="muted">#{escape(workspace['branch'])}</span>
          <span>#{running} · #{escape(workspace['status'] || 'idle')}#{workspace['active'] ? ' (busy)' : ''}</span>
          <span class="muted">Created <time datetime="#{escape(workspace['created_at'])}">#{escape(workspace['created_at'] || 'Unavailable')}</time></span>
          <span class="muted">Last startup <time datetime="#{escape(workspace['started_at'])}">#{escape(workspace['started_at'] || 'Never')}</time></span>
        </li>
      HTML
    end

    private

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

    def action_form(action)
      style = action['primary'] ? 'button--primary' : 'button--subtle'
      "<form method=\"post\" action=\"/workspaces/#{@id}/#{action.fetch('key')}\">" \
        "<button class=\"button #{style}\">#{escape(action.fetch('label'))}</button></form>"
    end
  end
end
