require_relative 'spec_helper'

RSpec.describe Workspaces::FrontDoor do
  before { repository }

  let(:registry) { Workspaces::Registry.new }
  let(:workspace) { registry.create(branch: 'main') }
  let(:app) { described_class.new(registry: registry) }

  def request(path, method: 'GET', input: nil, origin: nil)
    env = Rack::MockRequest.env_for("http://localhost:4747#{path}", method: method, input: input)
    env['HTTP_ORIGIN'] = origin if origin
    env['HTTP_HOST'] = 'localhost:4747'
    env['CONTENT_TYPE'] = 'application/x-www-form-urlencoded' if method == 'POST'
    app.call(env)
  end

  it 'requires a same-origin POST and exact workspace ID before discarding local edits' do
    id = workspace.id
    File.write(workspace.path.join('tracked.txt'), 'unsaved edit')
    File.write(workspace.path.join('untracked.txt'), 'unsaved file')
    path = "/workspaces/#{id}/remove"

    expect(request(path).first).to eq(405)
    expect(request(path, method: 'POST', input: "confirm_id=#{id}", origin: 'https://other.test').first).to eq(403)
    expect(request(path, method: 'POST', input: 'confirm_id=wrong', origin: 'http://localhost:4747').first).to eq(422)
    expect(workspace).to exist

    status, headers, = request(path, method: 'POST', input: "confirm_id=#{id}", origin: 'http://localhost:4747')
    expect(status).to eq(303)
    expect(headers['location']).to eq('http://localhost:4747/workspaces')
    expect(workspace).not_to exist
    expect(Workspaces::StateStore.new(Workspaces::Config.state_file).get(id)).to be_nil
  end

  it 'refuses removal while the workspace lock is held' do
    id = workspace.id
    registry.with_lock(id) do
      status, = request("/workspaces/#{id}/remove", method: 'POST', input: "confirm_id=#{id}",
                                                        origin: 'http://localhost:4747')
      expect(status).to eq(409)
    end
    expect(workspace).to exist
  end

  it 'does not delete the worktree or state if stopping the backend fails' do
    id = workspace.id
    allow_any_instance_of(Workspaces::Backend).to receive(:stop!).and_raise(Errno::EPERM)

    status, = request("/workspaces/#{id}/remove", method: 'POST', input: "confirm_id=#{id}",
                                                        origin: 'http://localhost:4747')
    expect(status).to eq(409)
    expect(workspace).to exist
    expect(Workspaces::StateStore.new(Workspaces::Config.state_file).get(id)).not_to be_nil
  end

  it 'renders live inventory state without deleting or preparing a workspace on GET' do
    id = workspace.id
    state = Workspaces::StateStore.new(Workspaces::Config.state_file)
    state.set(id, 'status' => 'ready', 'started_at' => '2026-10-01T12:00:00Z')
    allow_any_instance_of(Workspaces::Backend).to receive(:running?).and_return(true)

    status, _, body = request('/workspaces')
    expect(status).to eq(200)
    expect(body.join).to include(id, 'Running · ready', '2026-10-01T12:00:00Z', workspace.metadata['created_at'])
    expect(workspace).to exist
  end

  it 'does not accept JSON deletion requests or unknown workspace IDs' do
    id = workspace.id
    env = Rack::MockRequest.env_for("http://localhost:4747/workspaces/#{id}/remove", method: 'POST',
                                   input: JSON.generate(confirm_id: id), 'CONTENT_TYPE' => 'application/json')
    expect(app.call(env.merge('HTTP_HOST' => 'localhost:4747',
                              'HTTP_ORIGIN' => 'http://localhost:4747')).first).to eq(415)
    expect(request('/workspaces/not-managed/remove', method: 'POST', input: 'confirm_id=not-managed',
                                                      origin: 'http://localhost:4747').first).to eq(404)
    expect(workspace).to exist
  end
end
