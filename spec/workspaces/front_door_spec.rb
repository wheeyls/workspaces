require_relative 'spec_helper'

RSpec.describe Workspaces::FrontDoor do
  before { repository }

  let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }
  let(:coordinator) { Workspaces::Coordinator.new }
  let(:app) { described_class.new(coordinator: coordinator) }

  def request(path, method: 'GET', host: 'localhost:4747', headers: {}, input: nil)
    env = Rack::MockRequest.env_for("http://#{host}#{path}", method: method, input: input)
    app.call(env.merge('HTTP_HOST' => host).merge(headers))
  end

  it 'renders a workspace dashboard without starting, fetching or preparing on GET' do
    allow(coordinator).to receive(:start)
    status, _, body = request("/workspaces/#{workspace.id}")
    expect(status).to eq(200)
    expect(body.join).to include(workspace.id, "ws-#{workspace.id}.localhost:4747")
    expect(coordinator).not_to have_received(:start)
    expect(request("/workspaces/#{workspace.id}/status").first).to eq(200)
  end

  it 'protects all mutating actions from foreign origins and GETs' do
    allow(coordinator).to receive(:restart).and_return(true)
    path = "/workspaces/#{workspace.id}/restart"
    expect(request(path).first).to eq(405)
    expect(request(path, method: 'POST', headers: { 'HTTP_ORIGIN' => 'https://evil.test' }).first).to eq(403)
    expect(coordinator).not_to have_received(:restart)
    expect(request(path, method: 'POST', headers: { 'HTTP_ORIGIN' => 'http://localhost:4747' }).first).to eq(303)
    expect(coordinator).to have_received(:restart).with(workspace.id)
  end

  it 'supports hosted workspace IDs under a one-label wildcard and rejects forwarded-host bypasses' do
    ClimateControl.modify('WORKSPACES_PUBLIC_ORIGIN' => 'https://previews.coolify.tools.g2.com',
                          'WORKSPACES_BASE_DOMAIN' => 'coolify.tools.g2.com') do
      host = "ws-#{workspace.id}.coolify.tools.g2.com"
      expect(Workspaces::Config.preview_url(workspace.id)).to eq("https://#{host}/")
      status, headers, = request('/', host: host)
      expect(status).to eq(303)
      expect(headers['location']).to eq("https://previews.coolify.tools.g2.com/workspaces/#{workspace.id}")
      forged_headers = { 'HTTP_X_FORWARDED_HOST' => 'previews.coolify.tools.g2.com' }
      expect(request('/workspaces', host: 'evil.test', headers: forged_headers).first).to eq(400)
      expect(request('/workspaces', host: 'previews.coolify.tools.g2.com').first).to eq(200)
    end
  end

  it 'never treats a PR number URL or unknown host ID as implicit workspace creation' do
    expect(request('/43828').first).to eq(404)
    expect(request('/', host: 'ws-unknown.localhost:4747').first).to eq(404)
    expect(Workspaces::Registry.new.list).to eq([])
  end

  it 'creates a managed workspace through the protected dashboard form' do
    form_headers = { 'HTTP_ORIGIN' => 'http://localhost:4747',
                     'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }
    status, headers, = request('/workspaces/create', method: 'POST', input: 'branch=main', headers: form_headers)
    expect(status).to eq(303)
    expect(headers['location']).to include('/workspaces/main-')
    expect(Workspaces::Registry.new.list.length).to eq(1)
  end

  it 'proxies warm workspace requests with canonical forwarding headers' do
    snapshot = workspace.describe.merge('status' => 'ready', 'active' => false)
    allow(coordinator).to receive(:snapshot).with(workspace.id).and_return(snapshot)
    backend = instance_double(Workspaces::Backend, port: 30123)
    allow(Workspaces::Backend).to receive(:new).with(workspace.id).and_return(backend)
    http = instance_double(Net::HTTP)
    response = instance_double(Net::HTTPResponse, code: '200', body: 'app', each_header: {}.each)
    allow(response).to receive(:get_fields).with('set-cookie').and_return(nil)
    allow(http).to receive(:request) do |upstream|
      expect(upstream['Host']).to eq(Workspaces::Config.preview_host(workspace.id))
      expect(upstream['X-Forwarded-Proto']).to eq('http')
      expect(upstream['Forwarded']).to be_nil
      response
    end
    allow(Net::HTTP).to receive(:start).and_yield(http)
    status, _, body = request('/products', host: Workspaces::Config.preview_host(workspace.id),
                                           headers: { 'HTTP_FORWARDED' => 'host=evil.test' })
    expect(status).to eq(200)
    expect(body).to eq(['app'])
  end

  it 'preserves repeated set-cookie headers exactly as independent values' do
    snapshot = workspace.describe.merge('status' => 'ready', 'active' => false)
    allow(coordinator).to receive(:snapshot).with(workspace.id).and_return(snapshot)
    backend = instance_double(Workspaces::Backend, port: 30123)
    allow(Workspaces::Backend).to receive(:new).with(workspace.id).and_return(backend)
    response = instance_double(
      Net::HTTPResponse,
      code: '200',
      body: 'app',
      each_header: { 'content-type' => 'text/html; charset=utf-8' }.each
    )
    session_cookie = '_workspaces_session=abc; Path=/; HttpOnly; ' \
                     'Expires=Wed, 21 Oct 2015 07:28:00 GMT'
    csrf_cookie = 'csrf_token=def; Path=/; Secure; SameSite=None; ' \
                  'Expires=Thu, 22 Oct 2015 07:28:00 GMT'
    allow(response).to receive(:get_fields).with('set-cookie').and_return([session_cookie, csrf_cookie])
    allow(Net::HTTP).to receive(:start).and_yield(instance_double(Net::HTTP, request: response))

    status, headers, body = request('/products', host: Workspaces::Config.preview_host(workspace.id))

    expect(status).to eq(200)
    expect(headers['set-cookie']).to eq([session_cookie, csrf_cookie])
    expect(body).to eq(['app'])
  end

  it 'forwards https public-origin metadata for hosted previews' do
    ClimateControl.modify('WORKSPACES_PUBLIC_ORIGIN' => 'https://previews.coolify.tools.g2.com',
                          'WORKSPACES_BASE_DOMAIN' => 'coolify.tools.g2.com') do
      snapshot = workspace.describe.merge('status' => 'ready', 'active' => false)
      allow(coordinator).to receive(:snapshot).with(workspace.id).and_return(snapshot)
      backend = instance_double(Workspaces::Backend, port: 30123)
      allow(Workspaces::Backend).to receive(:new).with(workspace.id).and_return(backend)
      response = instance_double(Net::HTTPResponse, code: '200', body: 'secure', each_header: {}.each)
      allow(response).to receive(:get_fields).with('set-cookie').and_return(nil)
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request) do |upstream|
        expect(upstream['Host']).to eq(Workspaces::Config.preview_host(workspace.id))
        expect(upstream['X-Forwarded-Host']).to eq(Workspaces::Config.preview_host(workspace.id))
        expect(upstream['X-Forwarded-Proto']).to eq('https')
        expect(upstream['X-Forwarded-Port']).to eq('443')
        response
      end
      allow(Net::HTTP).to receive(:start).and_yield(http)

      status, _, body = request('/products', host: Workspaces::Config.preview_host(workspace.id))

      expect(status).to eq(200)
      expect(body).to eq(['secure'])
    end
  end
end
