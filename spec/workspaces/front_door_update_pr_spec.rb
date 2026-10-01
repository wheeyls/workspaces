require_relative 'spec_helper'

RSpec.describe Workspaces::FrontDoor do
  before { repository }

  let(:registry) { Workspaces::Registry.new }
  let(:workspace) do
    allow_any_instance_of(Workspaces::Worktree).to receive(:resolve_pr).and_return(
      'kind' => 'pr', 'repository' => 'example/project', 'number' => 43828,
      'branch' => 'feature', 'ref' => 'main'
    )
    registry.create(pr: '43828')
  end
  let(:app) { described_class.new(registry: registry) }

  def request(path, method: 'GET', origin: nil)
    env = Rack::MockRequest.env_for("http://localhost:4747#{path}", method: method)
    env['HTTP_ORIGIN'] = origin if origin
    app.call(env.merge('HTTP_HOST' => 'localhost:4747'))
  end

  it 'shows a PR-only source action and protects it from GET and foreign origins' do
    id = workspace.id
    html = request("/workspaces/#{id}").last.join
    expect(html).to include('Update from PR', "action=\"/workspaces/#{id}/update-pr\"")
    path = "/workspaces/#{id}/update-pr"
    expect(request(path).first).to eq(405)
    expect(request(path, method: 'POST', origin: 'https://elsewhere.test').first).to eq(403)
  end

  it 'updates a PR workspace without launching setup or restarting the backend' do
    id = workspace.id
    allow(registry).to receive(:update_pr).with(id).and_return('updated' => true)
    status, headers, = request("/workspaces/#{id}/update-pr", method: 'POST', origin: 'http://localhost:4747')
    expect(status).to eq(303)
    expect(headers['location']).to eq("http://localhost:4747/workspaces/#{id}")
    expect(registry).to have_received(:update_pr).with(id)
  end

  it 'redirects to the workspace with a persisted recovery message after an update conflict' do
    id = workspace.id
    allow(registry).to receive(:update_pr).with(id) do
      Workspaces::StateStore.new(Workspaces::Config.state_file).set(id, 'source_update_message' => 'Retained stash for recovery')
      raise Workspaces::Worktree::UpdateError, 'Retained stash for recovery'
    end
    expect(request("/workspaces/#{id}/update-pr", method: 'POST', origin: 'http://localhost:4747').first).to eq(303)
    expect(request("/workspaces/#{id}").last.join).to include('Retained stash for recovery')
  end

  it 'does not offer Update from PR for ordinary branch workspaces' do
    branch_workspace = registry.create(branch: 'main')
    expect(request("/workspaces/#{branch_workspace.id}").last.join).not_to include('Update from PR')
  end
end
