# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe Workspaces::FrontDoor, 'the waiting card on a preview host' do
  before { repository }

  let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }
  let(:coordinator) { Workspaces::Coordinator.new }
  let(:tracker) { Workspaces::ActivityTracker.new }
  let(:app) { described_class.new(coordinator: coordinator, tracker: tracker) }
  let(:host) { Workspaces::Config.preview_host(workspace.id) }
  let(:own_origin) { Workspaces::Config.preview_url(workspace.id).chomp('/') }
  let(:html) { { 'HTTP_ACCEPT' => 'text/html,application/xhtml+xml' } }

  def request(path, method: 'GET', headers: {}, form: nil)
    env = Rack::MockRequest.env_for("http://#{host}#{path}", method: method, input: form)
    env['CONTENT_TYPE'] = 'application/x-www-form-urlencoded' if method == 'POST'
    app.call(env.merge('HTTP_HOST' => host).merge(headers))
  end

  def snapshot(extra = {})
    workspace.describe.merge('workspace_id' => workspace.id, 'active' => false).merge(extra)
  end

  def stub_state(status, sleep_phase: nil, extra: {})
    allow(coordinator).to receive(:sleep_phase).and_return(sleep_phase)
    allow(coordinator).to receive(:snapshot).with(workspace.id, include_log: false)
                                            .and_return(snapshot({ 'status' => status }.merge(extra)))
  end

  context 'when a browser opens a page of a workspace that is not running' do
    before { stub_state('stopped') }

    it 'serves the card at that address instead of redirecting, and tells the card to reload it' do
      status, headers, body = request('/products?id=7', headers: html)

      expect(status).to eq(200)
      expect(headers['content-type']).to start_with('text/html')
      expect(body.join).to include('class="card"', 'data-reload-when-ready="true"', 'data-base="/__workspaces"')
    end

    it 'points the card at the reserved endpoints and the shared settings page, never the shared dashboard actions' do
      page = request('/', headers: html).last.join

      expect(page).to include("action=\"/__workspaces/start\"", "href=\"#{Workspaces::Config.settings_url(workspace.id)}\"")
      expect(page).not_to include("action=\"/workspaces/#{workspace.id}/")
    end

    it 'keeps the old behaviour for requests that are not a browser opening a page' do
      expect(request('/api/things').first).to eq(303)
      expect(request('/products', headers: html.merge('HTTP_SEC_FETCH_MODE' => 'cors')).first).to eq(303)
      expect(request('/products', headers: html.merge('HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest')).first).to eq(303)
      expect(request('/products', method: 'POST', headers: html).first).to eq(503)
    end
  end

  context 'when a browser opens a page of a sleeping workspace' do
    before do
      stub_state('sleeping', sleep_phase: :sleeping)
      allow(coordinator).to receive(:wake)
    end

    it 'starts the wake and shows the card straight away, without holding the request' do
      status, _, body = request('/orders', headers: html)

      expect(status).to eq(200)
      expect(body.join).to include('class="card"')
      expect(coordinator).to have_received(:wake).with(workspace.id)
    end

    it 'does not start a second wake while it is already waking' do
      stub_state('preparing', sleep_phase: :waking)

      request('/orders', headers: html)

      expect(coordinator).not_to have_received(:wake)
    end

    it 'still holds and wakes ordinary requests as before' do
      allow(coordinator).to receive(:sleep_phase).and_return(:sleeping, nil)
      allow(coordinator).to receive(:status_of).and_return('ready')

      request('/api/things')

      expect(coordinator).to have_received(:wake).with(workspace.id)
    end
  end

  describe 'GET /__workspaces/status' do
    it 'reports only what the card draws, with no log, steps, environment or error text' do
      stub_state('error', extra: { 'last_error' => 'password=hunter2 boom', 'log_tail' => 'secret log',
                                   'editable_environment' => { 'A' => 'b' } })

      status, headers, body = request('/__workspaces/status')
      json = JSON.parse(body.join)

      expect(status).to eq(200)
      expect(headers['content-type']).to start_with('application/json')
      expect(json['presentation']).to include('state' => 'error', 'error' => 'Setup failed. Open settings for the full log.')
      expect(body.join).not_to include('hunter2', 'secret log', 'editable_environment', 'step_logs')
    end

    it 'does not count as activity, so polling cannot keep a workspace awake' do
      now = [0.0]
      clocked = Workspaces::ActivityTracker.new(clock: -> { now.first })
      door = described_class.new(coordinator: coordinator, tracker: clocked)
      stub_state('ready')
      clocked.touch(workspace.id)
      now[0] = 600

      door.call(Rack::MockRequest.env_for("http://#{host}/__workspaces/status").merge('HTTP_HOST' => host))

      expect(clocked.in_flight(workspace.id)).to eq(0)
      expect(clocked.idle_for(workspace.id)).to eq(600)
    end

    it 'is never forwarded to the workspace backend' do
      stub_state('ready')
      allow(Net::HTTP).to receive(:start)

      request('/__workspaces/status')

      expect(Net::HTTP).not_to have_received(:start)
    end

    it 'rejects methods other than GET and HEAD' do
      stub_state('ready')

      expect(request('/__workspaces/status', method: 'POST', headers: { 'HTTP_ORIGIN' => own_origin }).first).to eq(405)
    end

    it 'answers 404 for any other reserved path, so the prefix cannot reach settings or removal' do
      stub_state('ready')

      %w(remove environment settings keep-awake update-pr).each do |name|
        expect(request("/__workspaces/#{name}", method: 'POST', headers: { 'HTTP_ORIGIN' => own_origin }).first).to eq(404)
      end
    end
  end

  describe 'POST /__workspaces/:action' do
    before do
      stub_state('stopped')
      allow(coordinator).to receive(:start).and_return(true)
      allow(coordinator).to receive(:apply_environment_preset).and_return(true)
    end

    it 'starts the workspace from its own origin and returns the visitor to the page they were on' do
      status, headers, = request('/__workspaces/start', method: 'POST',
                                                       headers: { 'HTTP_ORIGIN' => own_origin,
                                                                  'HTTP_REFERER' => "#{own_origin}/products?id=7" })

      expect(status).to eq(303)
      expect(headers['location']).to eq("#{own_origin}/products?id=7")
      expect(coordinator).to have_received(:start).with(workspace.id)
    end

    it 'applies a chosen preset before starting' do
      request('/__workspaces/start', method: 'POST', form: 'preset=marketplace', headers: { 'HTTP_ORIGIN' => own_origin })

      expect(coordinator).to have_received(:apply_environment_preset).with(workspace.id, name: 'marketplace')
    end

    it 'falls back to the preview root when the referrer is missing, foreign or reserved' do
      [nil, 'https://evil.test/x', "#{own_origin}/__workspaces/start"].each do |referer|
        headers = { 'HTTP_ORIGIN' => own_origin }
        headers['HTTP_REFERER'] = referer if referer
        expect(request('/__workspaces/start', method: 'POST', headers: headers)[1]['location']).to eq("#{own_origin}/")
      end
    end

    it 'refuses the shared dashboard origin, another workspace and foreign sites' do
      other = Workspaces::Config.preview_url('someone-else').chomp('/')
      [Workspaces::Config.public_origin, other, 'https://evil.test'].each do |origin|
        expect(request('/__workspaces/start', method: 'POST', headers: { 'HTTP_ORIGIN' => origin }).first).to eq(403)
      end
      expect(request('/__workspaces/start', method: 'POST').first).to eq(403)
      expect(coordinator).not_to have_received(:start)
    end

    it 'refuses GET' do
      expect(request('/__workspaces/start').first).to eq(405)
    end
  end

  it 'still serves the workspace itself, untouched, when it is ready' do
    stub_state('ready')
    backend = instance_double(Workspaces::Backend, port: 30123)
    allow(Workspaces::Backend).to receive(:new).with(workspace.id).and_return(backend)
    upstream = instance_double(Net::HTTPResponse, code: '200', body: 'the app', each_header: {}.each)
    allow(upstream).to receive(:get_fields).with('set-cookie').and_return(nil)
    allow(Net::HTTP).to receive(:start).and_yield(instance_double(Net::HTTP, request: upstream))

    status, _, body = request('/products', headers: html)

    expect(status).to eq(200)
    expect(body.join).to eq('the app')
  end
end
