require_relative 'spec_helper'

RSpec.describe Workspaces::FrontDoor, 'sleeping previews' do
  before { repository }

  let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }
  let(:coordinator) { Workspaces::Coordinator.new }
  let(:tracker) { Workspaces::ActivityTracker.new }
  let(:app) { described_class.new(coordinator: coordinator, tracker: tracker) }
  let(:host) { Workspaces::Config.preview_host(workspace.id) }
  let(:origin) { { 'HTTP_ORIGIN' => 'http://localhost:4747' } }

  def request(path, method: 'GET', host: self.host, headers: {}, input: nil)
    env = Rack::MockRequest.env_for("http://#{host}#{path}", method: method, input: input)
    app.call(env.merge('HTTP_HOST' => host).merge(headers))
  end

  def ready_snapshot
    workspace.describe.merge('status' => 'ready', 'active' => false)
  end

  def stub_upstream(body: 'app', seen: nil)
    backend = instance_double(Workspaces::Backend, port: 30123)
    allow(Workspaces::Backend).to receive(:new).with(workspace.id).and_return(backend)
    response = instance_double(Net::HTTPResponse, code: '200', body: body, each_header: {}.each)
    allow(response).to receive(:get_fields).with('set-cookie').and_return(nil)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:request) do |upstream|
      seen&.call(upstream)
      response
    end
    allow(Net::HTTP).to receive(:start).and_yield(http)
  end

  context 'with an awake workspace' do
    before do
      allow(coordinator).to receive(:snapshot).with(workspace.id, include_log: false).and_return(ready_snapshot)
      allow(coordinator).to receive(:sleep_phase).and_return(nil)
      stub_upstream
    end

    it 'counts preview traffic as activity and releases its lease when the response is done' do
      expect(request('/products').first).to eq(200)

      expect(tracker.in_flight(workspace.id)).to eq(0)
      expect(tracker.idle_for(workspace.id)).to be < 1
    end

    it 'holds a lease while a streamed response body is still open' do
      streaming = Class.new { def each; yield 'x'; end; def close; end }.new
      middleware = Class.new do
        define_method(:initialize) { |inner| @inner = inner }
        define_method(:call) { |env| @inner.call(env).then { |status, headers, _| [status, headers, streaming] } }
      end
      Workspaces::ProxyMiddleware.reset!
      Workspaces.configure_proxy { use middleware }
      door = described_class.new(coordinator: coordinator, tracker: tracker)

      _, _, body = door.call(Rack::MockRequest.env_for("http://#{host}/stream").merge('HTTP_HOST' => host))

      expect(tracker.in_flight(workspace.id)).to eq(1)
      body.close
      expect(tracker.in_flight(workspace.id)).to eq(0)
    ensure
      Workspaces::ProxyMiddleware.reset!
    end

    it 'does not let probes and configured polling reset the idle clock' do
      now = [0.0]
      clocked = Workspaces::ActivityTracker.new(clock: -> { now.first })
      door = described_class.new(coordinator: coordinator, tracker: clocked)
      clocked.touch(workspace.id)
      now[0] = 600
      %w(/health /up).each do |path|
        door.call(Rack::MockRequest.env_for("http://#{host}#{path}").merge('HTTP_HOST' => host))
      end

      expect(clocked.idle_for(workspace.id)).to eq(600)
      door.call(Rack::MockRequest.env_for("http://#{host}/products").merge('HTTP_HOST' => host))
      expect(clocked.idle_for(workspace.id)).to eq(0)
    end

    it 'does not hold a lease past an upstream failure' do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)

      expect(request('/products').first).to eq(502)
      expect(tracker.in_flight(workspace.id)).to eq(0)
    end
  end

  context 'with a sleeping workspace' do
    let(:state) { Workspaces::StateStore.new(Workspaces::Config.state_file) }

    before do
      allow(coordinator).to receive(:sleep_phase).and_return(:sleeping)
      allow(coordinator).to receive(:wake).and_return(true)
    end

    it 'wakes it, waits for readiness and then forwards the original request' do
      statuses = %w(preparing preparing ready)
      phases = [:sleeping, :waking, nil, nil, nil]
      allow(coordinator).to receive(:sleep_phase) { phases.length > 1 ? phases.shift : phases.first }
      allow(coordinator).to receive(:status_of) { statuses.length > 1 ? statuses.shift : statuses.first }
      allow(coordinator).to receive(:snapshot).with(workspace.id, include_log: false).and_return(ready_snapshot)
      forwarded = []
      stub_upstream(seen: ->(upstream) { forwarded << [upstream.method, upstream.body] })

      status, _, body = request('/orders', method: 'POST', input: 'a=1',
                                           headers: { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' })

      expect(status).to eq(200)
      expect(body).to eq(['app'])
      expect(coordinator).to have_received(:wake).with(workspace.id).once
      expect(forwarded).to eq([['POST', 'a=1']])
    end

    it 'answers a clear retryable 503 when it does not become ready in time' do
      allow(coordinator).to receive(:status_of).and_return('preparing')
      ClimateControl.modify('WORKSPACES_WAKE_TIMEOUT_SECONDS' => '0.3') do
        status, headers, body = request('/products')

        expect(status).to eq(503)
        expect(headers['retry-after']).to eq('5')
        expect(body.join).to include('waking up', Workspaces::Config.dashboard_url(workspace.id))
      end
      expect(tracker.in_flight(workspace.id)).to eq(0)
    end

    it 'answers a retryable 503 when the wake fails instead of waiting or retrying' do
      allow(coordinator).to receive(:sleep_phase).and_return(:sleeping, nil)
      allow(coordinator).to receive(:status_of).and_return('error')

      status, headers, body = request('/products')

      expect(status).to eq(503)
      expect(headers['retry-after']).to eq('5')
      expect(body.join).to include('could not wake')
      expect(coordinator).to have_received(:wake).once
    end

    it 'never wakes it for health probes or configured polling' do
      status, _, body = request('/health')

      expect(status).to eq(503)
      expect(body.join).to include('asleep')
      expect(coordinator).not_to have_received(:wake)
    end

    it 'shares one wake between simultaneous first requests' do
      real = Workspaces::Coordinator.new
      door = described_class.new(coordinator: real, tracker: tracker)
      allow(Workspaces::Backend).to receive(:new).and_call_original
      allow(real).to receive(:sleep_phase).and_return(:sleeping, :waking, :waking, nil)
      allow(real).to receive(:wake).and_return(true, false, false)
      allow(real).to receive(:status_of).and_return('ready')
      allow(real).to receive(:snapshot).with(workspace.id, include_log: false).and_return(ready_snapshot)
      stub_upstream

      results = Array.new(3) do
        Thread.new { door.call(Rack::MockRequest.env_for("http://#{host}/a").merge('HTTP_HOST' => host)).first }
      end.map(&:value)

      expect(results).to all(eq(200))
    end
  end

  it 'does not count dashboard and status polling as preview traffic' do
    now = [0.0]
    clocked = Workspaces::ActivityTracker.new(clock: -> { now.first })
    door = described_class.new(coordinator: coordinator, tracker: clocked)
    allow(coordinator).to receive(:snapshot).and_call_original
    clocked.touch(workspace.id)
    now[0] = 600

    door.call(Rack::MockRequest.env_for("http://localhost:4747/workspaces/#{workspace.id}/status")
                .merge('HTTP_HOST' => 'localhost:4747'))

    expect(clocked.idle_for(workspace.id)).to eq(600)
  end

  it 'does not wake a workspace that was stopped by hand, and sends a GET to the dashboard as before' do
    allow(coordinator).to receive(:sleep_phase).and_return(nil)
    allow(coordinator).to receive(:wake)
    allow(coordinator).to receive(:snapshot).with(workspace.id, include_log: false)
                                            .and_return(workspace.describe.merge('status' => 'stopped', 'active' => false))

    status, headers, = request('/products')

    expect(status).to eq(303)
    expect(headers['location']).to eq(Workspaces::Config.dashboard_url(workspace.id))
    expect(coordinator).not_to have_received(:wake)
    expect(request('/products', method: 'POST').first).to eq(503)
  end

  describe 'keep-awake controls' do
    it 'turns keep-awake on and off through protected form posts' do
      path = "/workspaces/#{workspace.id}/keep-awake"
      public_host = 'localhost:4747'

      expect(request(path, host: public_host).first).to eq(405)
      expect(request(path, host: public_host, method: 'POST', headers: { 'HTTP_ORIGIN' => 'https://evil.test' }).first).to eq(403)
      expect(coordinator.snapshot(workspace.id)['keep_awake']).to be(false)

      expect(request(path, host: public_host, method: 'POST', headers: origin).first).to eq(303)
      expect(coordinator.snapshot(workspace.id)['keep_awake']).to be(true)

      request("/workspaces/#{workspace.id}/allow-sleep", host: public_host, method: 'POST', headers: origin)
      expect(coordinator.snapshot(workspace.id)['keep_awake']).to be(false)
    end

    it 'survives a front door restart because it is recorded with the workspace' do
      coordinator.keep_awake(workspace.id, true)

      expect(Workspaces::Coordinator.new.snapshot(workspace.id)['keep_awake']).to be(true)
    end
  end

  it 'forgets a workspace that is removed' do
    tracker.touch(workspace.id)
    allow(app).to receive(:same_origin?).and_return(true)
    request("/workspaces/#{workspace.id}/remove", host: 'localhost:4747', method: 'POST',
                                                  headers: origin.merge('CONTENT_TYPE' => 'application/x-www-form-urlencoded'),
                                                  input: "confirm_id=#{workspace.id}")

    expect(tracker.in_flight(workspace.id)).to eq(0)
  end
end
