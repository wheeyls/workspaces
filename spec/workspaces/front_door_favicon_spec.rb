require_relative 'spec_helper'

RSpec.describe Workspaces::FrontDoor, 'favicon' do
  before { repository }

  let(:app) { described_class.new }
  let(:vendored) { Pathname.new(File.expand_path('../../lib/workspaces/dashboard/arb-previews-favicon.svg', __dir__)) }

  def request(path, method: 'GET', host: 'localhost:4747')
    env = Rack::MockRequest.env_for("http://#{host}#{path}", method: method)
    app.call(env.merge('HTTP_HOST' => host))
  end

  it 'serves the Arb Previews icon and links it from the dashboard' do
    status, headers, body = request('/favicon.svg')

    expect(status).to eq(200)
    expect(headers['content-type']).to include('image/svg+xml')
    expect(body.join).to eq(vendored.read)
    expect(body.join).to include('<title id="title">Arb Previews</title>', 'viewBox="0 0 16 16"')
    expect(request('/workspaces').last.join).to include('href="/favicon.svg"')
  end

  it 'is the design system file unchanged, with its approved palette and no extra colour' do
    svg = vendored.read

    expect(svg.scan(/#[0-9A-Fa-f]{6}/).map(&:upcase).uniq.sort).to eq(%w(#123A3D #58D9C4 #F4F1E8))
    expect(Digest::SHA256.hexdigest(svg)).to eq('bbcb07f23e47b01fa0edd26dde1b9634b3ca73fe36e4402461359b5a23e730c9')
  end

  it 'is the same icon on a hosted dashboard, because the mark is not recoloured or badged by environment' do
    ClimateControl.modify('WORKSPACES_PUBLIC_ORIGIN' => 'https://previews-ue.coolify.tools.g2.com',
                          'WORKSPACES_BASE_DOMAIN' => 'coolify.tools.g2.com') do
      status, _, body = request('/favicon.svg', host: 'previews-ue.coolify.tools.g2.com')

      expect(status).to eq(200)
      expect(body.join).to eq(vendored.read)
    end
  end

  it 'answers HEAD without a body, refuses other methods, and refuses an unknown host' do
    expect(request('/favicon.svg', method: 'HEAD').last).to eq([])
    expect(request('/favicon.svg', method: 'POST').first).to eq(405)
    ClimateControl.modify('WORKSPACES_PUBLIC_ORIGIN' => 'https://previews-ue.coolify.tools.g2.com',
                          'WORKSPACES_BASE_DOMAIN' => 'coolify.tools.g2.com') do
      expect(request('/favicon.svg', host: 'other.coolify.tools.g2.com').first).to eq(400)
    end
  end
end
