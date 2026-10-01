require 'rack'
require 'json'
require 'uri'
require 'net/http'
require_relative 'coordinator'
require_relative 'dashboard_view'
require_relative 'environment_overrides'

module Workspaces
  class FrontDoor
    WORKSPACE_ROUTE = %r{\A/workspaces/([a-z0-9]+(?:-[a-z0-9]+)*)
                          (?:/(status|start|prepare|restart|stop|remove|update-pr|environment))?\z}x

    def initialize(coordinator: Coordinator.new, registry: Registry.new)
      @coordinator = coordinator
      @registry = registry
    end

    def call(env)
      request = Rack::Request.new(env)
      authority = request_authority(request)
      return response(400, 'Unexpected Host header.') unless authority

      id = Config.preview_workspace_id(authority.host)
      return proxy(id, request) if id && valid_authority?(authority, URI(Config.preview_url(id)))
      return response(400, 'Unexpected Host header.') unless valid_authority?(authority, Config.public_uri)

      route(request)
    rescue Worktree::AuthenticationError
      response(422, DashboardView.checkout_authentication_error(request.path_info), type: 'text/html')
    rescue ArgumentError, Worktree::CommandFailedError => e
      response(422, e.message)
    end

    private

    def route(request)
      return favicon(request) if request.path_info == '/favicon.svg'
      return index(request) if ['/', '/workspaces'].include?(request.path_info)
      return create(request) if request.path_info == '/workspaces/create'
      pr_match = %r{\A/pr/([1-9][0-9]*)\z}.match(request.path_info)
      return pr_preview(request, pr_match[1]) if pr_match

      workspace_route(request)
    end

    def favicon(request)
      return response(405, 'Use GET or HEAD') unless safe?(request)

      response(200, DashboardView.favicon, type: 'image/svg+xml', head: request.head?)
    end

    def workspace_route(request)
      match = WORKSPACE_ROUTE.match(request.path_info)
      return response(404, 'Not found. Visit /workspaces.') unless match

      id, action = match.captures
      return response(404, 'Unknown managed workspace') unless Worktree.new(id).exists?

      action_request(request, id, action)
    end

    def pr_preview(request, number)
      if safe?(request)
        page = DashboardView.pull_request(number, @registry.list(pr: number))
        return response(200, page, type: 'text/html', head: request.head?)
      end
      return response(405, 'Use GET, HEAD or POST') unless request.post?
      return response(403, 'Creation requires the configured dashboard origin') unless same_origin?(request)

      workspace = @registry.create(pr: number)
      @coordinator.start(workspace.id)
      redirect(Config.dashboard_url(workspace.id))
    end

    def index(request)
      return response(405, 'Use GET or HEAD') unless safe?(request)

      response(200, DashboardView.index(@coordinator.inventory), type: 'text/html', head: request.head?)
    end

    def action_request(request, id, action)
      return update_environment(request, id) if action == 'environment'
      return status_response(request, id, action) if action.nil? || action == 'status'
      return response(405, 'Use POST') unless request.post?
      return response(403, 'Actions require the configured dashboard origin') unless same_origin?(request)
      return remove(request, id) if action == 'remove'
      return update_pr(id) if action == 'update-pr'

      perform_action(id, action)
      redirect(Config.dashboard_url(id))
    end

    def status_response(request, id, action)
      return response(405, 'Use GET or HEAD') unless safe?(request)

      source = request.params.fetch('log', 'setup')
      return response(400, 'Unknown workspace log') unless %w(setup backend).include?(source)

      snapshot = @coordinator.snapshot(id, log: source)
      body = action ? JSON.generate(snapshot) : DashboardView.render(snapshot)
      response(200, body, type: action ? 'application/json' : 'text/html', head: request.head?)
    end

    def perform_action(id, action)
      case action
      when 'start' then @coordinator.start(id)
      when 'prepare' then @coordinator.start(id, force: true)
      when 'restart' then @coordinator.restart(id)
      when 'stop' then stop(id)
      end
    end

    def update_environment(request, id)
      return response(405, 'Use POST') unless request.post?
      return response(403, 'Actions require the configured dashboard origin') unless same_origin?(request)

      params = environment_params(request)
      updated = if params.key?('editable_env')
                  @coordinator.replace_editable_environment(id, text: parse_editable_environment(params))
                else
                  @coordinator.update_environment(id, **parse_environment_changes(params))
                end
      return response(409, 'Workspace is busy preparing, restarting, or running a command') unless updated

      redirect(Config.dashboard_url(id))
    rescue EnvironmentOverrides::Invalid => e
      response(422, e.message)
    end

    def stop(id)
      @registry.with_lock(id) do
        Backend.new(id).stop!
        StateStore.new(Config.state_file).set(id, 'status' => 'stopped', 'message' => 'Server stopped')
      end
    end

    def remove(request, id)
      unless request.media_type == 'application/x-www-form-urlencoded'
        return response(415, 'Deletion requires a form-encoded confirmation')
      end
      return response(413, 'Deletion confirmation is too large') if request.content_length.to_i > 512
      return response(422, 'Type the exact workspace ID to confirm deletion') unless request.POST['confirm_id'] == id

      @registry.remove(id, force: true)
      redirect("#{Config.public_origin}/workspaces")
    rescue ArgumentError, Worktree::CommandFailedError, SystemCallError
      response(409, 'Workspace was not removed. Check the server logs and retry when safe.')
    end

    def update_pr(id)
      @registry.update_pr(id)
      redirect(Config.dashboard_url(id))
    rescue Worktree::UpdateError
      redirect(Config.dashboard_url(id))
    end

    def create(request)
      return response(405, 'Use POST') unless request.post?
      return response(403, 'Creation requires the configured dashboard origin') unless same_origin?(request)

      params = request.POST
      options = {}
      %w(branch pr new_branch from).each { |key| options[key.to_sym] = params[key] unless params[key].to_s.empty? }
      workspace = @registry.create(**options)
      redirect(Config.dashboard_url(workspace.id))
    end

    def environment_params(request)
      validate_environment_content_type!(request)
      raw = environment_body(request)
      Rack::Utils.parse_nested_query(raw)
    rescue Rack::Utils::ParameterTypeError => e
      raise EnvironmentOverrides::Invalid, "Invalid environment form: #{e.class}"
    end

    def parse_environment_changes(params)
      { set: normalize_set(params['set']), remove: normalize_remove(params['remove']) }
    end

    def parse_editable_environment(params)
      unless params['editable_env'].is_a?(String)
        raise EnvironmentOverrides::Invalid, 'Environment editor requires one editable_env field'
      end

      params.fetch('editable_env')
    end

    def validate_environment_content_type!(request)
      return if ['', 'application/x-www-form-urlencoded'].include?(request.media_type.to_s)

      raise EnvironmentOverrides::Invalid, 'Environment updates must use form-encoded parameters'
    end

    def environment_body(request)
      limit = EnvironmentOverrides::MAX_BODY_BYTES
      if request.content_length.to_i > limit
        raise EnvironmentOverrides::Invalid,
              'Environment update payload is too large'
      end

      raw = request.body.read(limit + 1).to_s
      raise EnvironmentOverrides::Invalid, 'Environment update payload is too large' if raw.bytesize > limit

      raw
    end

    def normalize_set(values)
      return {} if values.nil?
      unless values.is_a?(Hash)
        raise EnvironmentOverrides::Invalid,
              'Environment updates must use set[NAME]=VALUE form fields'
      end

      values.transform_keys(&:to_s).transform_values(&:to_s)
    end

    def normalize_remove(values)
      case values
      when nil then []
      when String then [values]
      when Array then values.map(&:to_s)
      else raise EnvironmentOverrides::Invalid, 'Environment removals must use remove[]=NAME form fields'
      end
    end

    def proxy(id, request)
      return response(404, 'Unknown managed workspace') unless Worktree.new(id).exists?

      snapshot = @coordinator.snapshot(id, include_log: false)
      return unavailable(id, request) unless snapshot['status'] == 'ready' && !snapshot['active']

      forward(id, request)
    rescue IOError, SystemCallError, Timeout::Error => e
      response(502, "Workspace backend unavailable: #{e.class}")
    end

    def unavailable(id, request)
      return redirect(Config.dashboard_url(id)) if safe?(request)

      response(503, "Workspace not ready. Visit #{Config.dashboard_url(id)}")
    end

    def forward(id, request)
      uri = URI("http://127.0.0.1:#{Backend.new(id).port}#{request.fullpath}")
      upstream = upstream_request(id, request, uri)
      result = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 60) { |http| http.request(upstream) }
      [result.code.to_i, response_headers(result),
       request.head? ? [] : [result.body || '']]
    end

    def upstream_request(id, request, uri)
      upstream = Net::HTTPGenericRequest.new(request.request_method, !safe?(request), !request.head?, uri.request_uri)
      copy_request_headers(request, upstream)
      forwarding_headers(id).each { |key, value| upstream[key] = value }
      upstream.body = request.body.read unless safe?(request)
      upstream
    end

    def copy_request_headers(request, upstream)
      request.each_header do |key, value|
        next unless key.start_with?('HTTP_') || %w(CONTENT_TYPE CONTENT_LENGTH).include?(key)
        next if key == 'HTTP_FORWARDED' || key.start_with?('HTTP_X_FORWARDED_')

        upstream[key.delete_prefix('HTTP_').tr('_', '-')] = value
      end
    end

    def forwarding_headers(id)
      { 'Host' => Config.preview_host(id), 'X-Forwarded-Host' => Config.preview_host(id),
        'X-Forwarded-Port' => Config.public_uri.port.to_s, 'X-Forwarded-Proto' => Config.public_uri.scheme }
    end

    def response_headers(result)
      headers = result.each_header.to_h.reject { |key, _| %w(transfer-encoding connection).include?(key) }
      cookies = result.get_fields('set-cookie')
      headers['set-cookie'] = cookies if cookies
      headers
    end

    def safe?(request)
      %w(GET HEAD).include?(request.request_method)
    end

    def same_origin?(request)
      origin = request.get_header('HTTP_ORIGIN')
      return origin == Config.public_origin if origin

      uri = URI.parse(request.referer.to_s)
      uri.is_a?(URI::HTTP) && uri.userinfo.nil? && "#{uri.scheme}://#{uri.authority}" == Config.public_origin
    rescue URI::InvalidURIError
      false
    end

    def request_authority(request)
      host = request.get_header('HTTP_HOST').to_s
      return nil unless host.match?(/\A[a-zA-Z0-9.-]+(?::[0-9]+)?\z/)

      URI.parse("#{Config.public_uri.scheme}://#{host}")
    rescue URI::InvalidURIError
      nil
    end

    def valid_authority?(actual, expected)
      actual.host.casecmp?(expected.host) && actual.port == expected.port
    end

    def redirect(url)
      [303, headers('text/plain').merge('location' => url), ["See #{url}\n"]]
    end

    def response(status, body, type: 'text/plain', head: false)
      [status, headers(type), head ? [] : [body]]
    end

    def headers(type)
      { 'content-type' => "#{type}; charset=utf-8", 'cache-control' => 'no-store',
        'x-content-type-options' => 'nosniff', 'x-frame-options' => 'DENY',
        'content-security-policy' => "frame-ancestors 'none'" }
    end
  end
end
