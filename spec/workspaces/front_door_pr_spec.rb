require_relative 'spec_helper'

RSpec.describe Workspaces::FrontDoor do
  let(:registry) { instance_spy(Workspaces::Registry, list: []) }
  let(:coordinator) { instance_spy(Workspaces::Coordinator) }
  let(:app) { described_class.new(registry: registry, coordinator: coordinator) }

  def request(path = '/pr/43828', method: 'GET', origin: nil, host: 'localhost:4747')
    env = Rack::MockRequest.env_for("http://#{host}#{path}", method: method)
    env['HTTP_HOST'] = host
    env['HTTP_ORIGIN'] = origin if origin
    app.call(env)
  end

  it 'shows an empty PR page without creating or starting anything' do
    status, headers, body = request
    expect(registry).not_to have_received(:create)
    expect(coordinator).not_to have_received(:start)
    expect(status).to eq(200)
    expect(headers['cache-control']).to eq('no-store')
    expect(body.join).to include('PR #43828', 'No workspaces yet', 'Create and start workspace')
    expect(body.join).to include('method="post" action="/pr/43828"')
    expect(body.join).to include('button button--primary">Create and start workspace')
    expect(body.join).not_to include('<details')
    expect(registry).to have_received(:list).with(pr: '43828')
  end

  it 'lists all associated workspaces and escapes branch names' do
    allow(registry).to receive(:list).with(pr: '43828').and_return([
                                                                     { 'id' => 'first-123',
                                                                       'branch' => '<script>unsafe</script>' },
                                                                     { 'id' => 'second-456', 'branch' => 'agent/edits' }
                                                                   ])
    html = request.last.join
    expect(html).to include('/workspaces/first-123', '/workspaces/second-456', '&lt;script&gt;unsafe&lt;/script&gt;')
    expect(html).not_to include('<script>unsafe</script>')
    expect(html.index('id="existing-heading"')).to be < html.index('Create another workspace')
    expect(html.scan('class="button button--primary"').length).to eq(2)
    expect(html).to include('class="button button--subtle">Create and start workspace')
    expect(html).to include('<details class="status-panel">')
    expect(html).not_to include('<details class="status-panel" open')
  end

  it 'makes a single existing workspace the primary action' do
    allow(registry).to receive(:list).with(pr: '43828').and_return([{ 'id' => 'first-123', 'branch' => 'agent/edits' }])
    html = request.last.join
    expect(html).to include('href="/workspaces/first-123" class="button button--primary"')
    expect(html).to include('Open workspace')
    expect(html.scan('class="button button--primary"').length).to eq(1)
    expect(registry).not_to have_received(:create)
    expect(coordinator).not_to have_received(:start)
  end

  it 'creates and starts a fresh workspace on each same-origin POST' do
    first = instance_double(Workspaces::Worktree, id: 'first-123')
    second = instance_double(Workspaces::Worktree, id: 'second-456')
    allow(registry).to receive(:create).with(pr: '43828').and_return(first, second)
    allow(coordinator).to receive(:start).and_return(true)
    %w(first-123 second-456).each do |id|
      status, headers, = request(method: 'POST', origin: 'http://localhost:4747')
      expect(status).to eq(303)
      expect(headers['location']).to eq("http://localhost:4747/workspaces/#{id}")
      expect(coordinator).to have_received(:start).with(id)
    end
    expect(registry).to have_received(:create).with(pr: '43828').twice
  end

  it 'rejects missing or foreign POST origins without creating workspaces' do
    [nil, 'https://evil.test', 'http://ws-first-123.localhost:4747'].each do |origin|
      expect(request(method: 'POST', origin: origin).first).to eq(403)
    end
    expect(registry).not_to have_received(:create)
  end

  it 'supports HEAD and rejects unsupported methods and invalid PR numbers' do
    expect(request(method: 'HEAD').last).to eq([])
    expect(request(method: 'DELETE').first).to eq(405)
    %w(/pr/0 /pr/-1 /pr/nope /pr/43828/extra).each { |path| expect(request(path).first).to eq(404) }
  end

  it 'uses the configured public origin for hosted creation and redirects' do
    ClimateControl.modify('WORKSPACES_PUBLIC_ORIGIN' => 'https://previews.coolify.tools.g2.com') do
      allow(registry).to receive(:create).and_return(instance_double(Workspaces::Worktree, id: 'pr-43828-abc'))
      allow(coordinator).to receive(:start).and_return(true)
      status, headers, = request(method: 'POST', host: 'previews.coolify.tools.g2.com',
                                 origin: 'https://previews.coolify.tools.g2.com')
      expect(status).to eq(303)
      expect(headers['location']).to eq('https://previews.coolify.tools.g2.com/workspaces/pr-43828-abc')
    end
  end

  it 'returns creation failures without starting a backend' do
    allow(registry).to receive(:create).and_raise(Workspaces::Worktree::CommandFailedError, 'PR not found')
    status, _, body = request(method: 'POST', origin: 'http://localhost:4747')
    expect(coordinator).not_to have_received(:start)
    expect(status).to eq(422)
    expect(body.join).to include('PR not found')
  end

  it 'shows actionable Git authentication guidance without exposing command output' do
    allow(registry).to receive(:create).and_raise(Workspaces::Worktree::AuthenticationError, 'private-token')
    status, headers, body = request(method: 'POST', origin: 'http://localhost:4747')
    expect(status).to eq(422)
    expect(headers['content-type']).to include('text/html')
    expect(body.join).to include('GitHub access needs setup', 'gh auth setup-git --hostname github.com',
                                 'Retry checkout', 'action="/pr/43828"')
    expect(body.join).not_to include('private-token')
    expect(coordinator).not_to have_received(:start)
  end

  it 'shows authentication guidance for the generic creation form too' do
    allow(registry).to receive(:create).and_raise(Workspaces::Worktree::AuthenticationError)
    status, _, body = request('/workspaces/create', method: 'POST', origin: 'http://localhost:4747')
    expect(status).to eq(422)
    expect(body.join).to include('GitHub access needs setup', 'href="/workspaces"')
  end
end
