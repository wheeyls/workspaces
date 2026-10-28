# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe Workspaces::FrontDoor, 'the workspace card' do
  before { repository }

  let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }
  let(:coordinator) { Workspaces::Coordinator.new }
  let(:app) { described_class.new(coordinator: coordinator) }
  let(:origin) { { 'HTTP_ORIGIN' => 'http://localhost:4747' } }

  def request(path, method: 'GET', form: '', headers: {})
    env = Rack::MockRequest.env_for("http://localhost:4747#{path}", method: method, input: form)
    env['HTTP_HOST'] = 'localhost:4747'
    env['CONTENT_TYPE'] = 'application/x-www-form-urlencoded' if method == 'POST'
    app.call(env.merge(headers))
  end

  def page(path)
    status, headers, body = request(path)
    [status, headers, body.join]
  end

  def stub_snapshot(extra = {})
    allow(coordinator).to receive(:snapshot).and_return(workspace.describe.merge('workspace_id' => workspace.id, 'active' => false).merge(extra))
  end

  describe 'GET /workspaces/:id' do
    it 'serves the small card, with a link to settings and without the full page' do
      status, headers, html = page("/workspaces/#{workspace.id}")

      expect(status).to eq(200)
      expect(headers['content-type']).to start_with('text/html')
      expect(html).to include('class="card"', "href=\"/workspaces/#{workspace.id}/settings\"")
      expect(html).not_to include('id="environment-form"', 'id="remove-form"', 'id="steps"')
    end

    it 'shows the preview link only when the workspace is ready' do
      stub_snapshot('status' => 'ready')
      _, _, ready = page("/workspaces/#{workspace.id}")
      stub_snapshot('status' => 'stopped')
      _, _, stopped = page("/workspaces/#{workspace.id}")

      expect(ready).not_to match(/id="preview"[^>]*hidden/)
      expect(stopped).to match(/id="preview"[^>]*hidden/)
    end

    it 'offers a single start form while idle and the lifecycle action once it has been started' do
      stub_snapshot('status' => 'idle')
      _, _, idle = page("/workspaces/#{workspace.id}")
      stub_snapshot('status' => 'stopped')
      _, _, stopped = page("/workspaces/#{workspace.id}")

      expect(idle).to match(/class="card__start[^"]*"[^>]*data-only-state="idle"(?![^>]*hidden)/)
      expect(stopped).to match(/class="card__start[^"]*"[^>]*data-only-state="idle"[^>]*hidden/)
      expect(stopped).to include("action=\"/workspaces/#{workspace.id}/start\"")
    end

    it 'does not start, fetch or prepare anything' do
      allow(coordinator).to receive(:start)

      page("/workspaces/#{workspace.id}")

      expect(coordinator).not_to have_received(:start)
    end

    it 'puts the preset on the card as a badge, and the error with a way to the full log' do
      stub_snapshot('status' => 'error', 'message' => 'boom')
      allow_any_instance_of(Workspaces::Presentation).to receive(:to_h).and_wrap_original do |original|
        original.call.merge('current_preset' => 'marketplace', 'error' => 'bundle install failed')
      end

      _, _, html = page("/workspaces/#{workspace.id}")

      expect(html).to include('Preset: marketplace', 'bundle install failed', "href=\"/workspaces/#{workspace.id}/settings\"")
    end
  end

  describe 'GET /workspaces/:id/settings' do
    it 'serves the full page, with a way back to the card' do
      status, _, html = page("/workspaces/#{workspace.id}/settings")

      expect(status).to eq(200)
      expect(html).to include('id="environment-form"', 'id="remove-form"', "href=\"/workspaces/#{workspace.id}\"")
      expect(html).not_to include('class="card"')
    end

    it 'is read-only and answers HEAD' do
      expect(request("/workspaces/#{workspace.id}/settings", method: 'POST', headers: origin).first).to eq(405)
      status, _, body = request("/workspaces/#{workspace.id}/settings", method: 'HEAD')

      expect(status).to eq(200)
      expect(body).to eq([])
    end
  end

  describe 'starting from the card' do
    let(:path) { "/workspaces/#{workspace.id}/environment" }

    it 'applies the chosen preset and starts the workspace' do
      allow(coordinator).to receive(:apply_environment_preset).and_return(true)

      status, headers, = request(path, method: 'POST', form: 'preset=marketplace', headers: origin)

      expect(status).to eq(303)
      expect(headers['location']).to eq(Workspaces::Config.dashboard_url(workspace.id))
      expect(coordinator).to have_received(:apply_environment_preset).with(workspace.id, name: 'marketplace')
    end

    it 'starts with the defaults when the preset is left blank' do
      allow(coordinator).to receive(:start).and_return(true)
      allow(coordinator).to receive(:apply_environment_preset)

      status, = request(path, method: 'POST', form: 'preset=', headers: origin)

      expect(status).to eq(303)
      expect(coordinator).to have_received(:start).with(workspace.id)
      expect(coordinator).not_to have_received(:apply_environment_preset)
    end

    it 'rejects an unknown preset without starting anything' do
      status, _, body = request(path, method: 'POST', form: 'preset=nope', headers: origin)

      expect(status).to eq(422)
      expect(body.join).to include('nope')
      expect(coordinator.status_of(workspace.id)).not_to eq('preparing')
    end

    it 'still refuses a foreign origin' do
      expect(request(path, method: 'POST', form: 'preset=x', headers: { 'HTTP_ORIGIN' => 'https://evil.test' }).first).to eq(403)
    end
  end
end
