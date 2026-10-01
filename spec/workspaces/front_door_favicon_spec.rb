require_relative 'spec_helper'

RSpec.describe Workspaces::FrontDoor do
  let(:app) { described_class.new }

  def request(path, method: 'GET', host: 'localhost:4747')
    env = Rack::MockRequest.env_for("http://#{host}#{path}", method: method)
    app.call(env.merge('HTTP_HOST' => host))
  end

  it 'serves a blue workspace icon for localhost and links it from the dashboard' do
    status, headers, body = request('/favicon.svg')
    expect(status).to eq(200)
    expect(headers['content-type']).to include('image/svg+xml')
    expect(body.join).to include('viewBox="0 0 64 64"', '#4f8dff')
    expect(request('/workspaces').last.join).to include('href="/favicon.svg"')
    expect(request('/favicon.svg', method: 'HEAD').last).to eq([])
    expect(request('/favicon.svg', method: 'POST').first).to eq(405)
  end

  it 'serves a gold icon on the hosted dashboard without treating it as a preview host' do
    ClimateControl.modify('WORKSPACES_PUBLIC_ORIGIN' => 'https://previews-ue.coolify.tools.g2.com',
                          'WORKSPACES_BASE_DOMAIN' => 'coolify.tools.g2.com') do
      status, _, body = request('/favicon.svg', host: 'previews-ue.coolify.tools.g2.com')
      expect(status).to eq(200)
      expect(body.join).to include('#f1bb53')
      expect(body.join).not_to include('#4f8dff')
      expect(request('/favicon.svg', host: 'other.coolify.tools.g2.com').first).to eq(400)
    end
  end
end
