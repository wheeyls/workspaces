# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe Workspaces::FrontDoor, '#update_environment' do
  before { repository }

  let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }
  let(:coordinator) { Workspaces::Coordinator.new }
  let(:app) { described_class.new(coordinator: coordinator) }

  def request(path, method: 'POST', form: '', host: 'localhost:4747', headers: {})
    env = Rack::MockRequest.env_for("http://#{host}#{path}", method: method, input: form)
    env['HTTP_HOST'] = host
    env['CONTENT_TYPE'] = 'application/x-www-form-urlencoded' if method == 'POST'
    app.call(env.merge(headers))
  end

  it 'requires same-origin POST and never mutates on GET or foreign origins' do
    path = "/workspaces/#{workspace.id}/environment"

    expect(request(path, method: 'GET').first).to eq(405)
    expect(request(path, headers: { 'HTTP_ORIGIN' => 'https://evil.test' }).first).to eq(403)
    expect(Workspaces::EnvironmentOverrides.new(workspace.id).load).to eq({})
  end

  it 'saves a patch then restarts and redirects without exposing values in the snapshot' do
    install_recipe_with_overrides

    status, headers, = request(
      "/workspaces/#{workspace.id}/environment",
      headers: { 'HTTP_ORIGIN' => 'http://localhost:4747' },
      form: Rack::Utils.build_nested_query('set' => { 'UE_APP' => 'override', 'ROUTING_SUBDOMAIN' => 'preview' })
    )

    expect(status).to eq(303)
    expect(headers['location']).to eq("http://localhost:4747/workspaces/#{workspace.id}")

    snapshot = coordinator.wait(workspace.id)
    expect(snapshot['status']).to eq('ready')
    expect(snapshot['environment_keys']).to eq(%w(ROUTING_SUBDOMAIN UE_APP))
    visible_fields = [snapshot['message'], snapshot['last_error'], snapshot['log_tail']].join("\n")
    expect(visible_fields).not_to include('override', 'preview')
    expect(Workspaces::EnvironmentOverrides.new(workspace.id).load).to eq(
      'UE_APP' => 'override',
      'ROUTING_SUBDOMAIN' => 'preview'
    )
  end

  it 'preserves untouched keys across patches and removing restores recipe defaults' do
    install_recipe_with_overrides
    origin = { 'HTTP_ORIGIN' => 'http://localhost:4747' }

    request(
      "/workspaces/#{workspace.id}/environment",
      headers: origin,
      form: Rack::Utils.build_nested_query('set' => { 'UE_APP' => 'override', 'ROUTING_SUBDOMAIN' => 'preview' })
    )
    coordinator.wait(workspace.id)

    request(
      "/workspaces/#{workspace.id}/environment",
      headers: origin,
      form: Rack::Utils.build_nested_query('set' => { 'ROUTING_SUBDOMAIN' => 'second' })
    )
    coordinator.wait(workspace.id)

    expect(Workspaces::EnvironmentOverrides.new(workspace.id).load).to eq(
      'UE_APP' => 'override',
      'ROUTING_SUBDOMAIN' => 'second'
    )

    request(
      "/workspaces/#{workspace.id}/environment",
      headers: origin,
      form: Rack::Utils.build_nested_query('remove' => %w(UE_APP ROUTING_SUBDOMAIN))
    )
    snapshot = coordinator.wait(workspace.id)

    expect(snapshot['environment_keys']).to eq([])
    expect(Workspaces::EnvironmentOverrides.new(workspace.id).load).to eq({})
  end

  it 'returns 409 without persistence when the workspace is already busy' do
    registry = Workspaces::Registry.new
    registry.with_lock(workspace.id) do
      status, = request(
        "/workspaces/#{workspace.id}/environment",
        headers: { 'HTTP_ORIGIN' => 'http://localhost:4747' },
        form: Rack::Utils.build_nested_query('set' => { 'UE_APP' => 'override' })
      )
      expect(status).to eq(409)
    end

    expect(Workspaces::EnvironmentOverrides.new(workspace.id).load).to eq({})
  end

  it 'returns 422 and does not persist invalid payloads or set/remove conflicts' do
    origin = { 'HTTP_ORIGIN' => 'http://localhost:4747' }

    status, _, body = request(
      "/workspaces/#{workspace.id}/environment",
      headers: origin,
      form: Rack::Utils.build_nested_query('set' => { 'WORKSPACE_PORT' => '9999' })
    )
    expect(status).to eq(422)
    expect(body.join).not_to include('9999')

    status, = request(
      "/workspaces/#{workspace.id}/environment",
      headers: origin,
      form: Rack::Utils.build_nested_query('set' => { 'UE_APP' => 'override' }, 'remove' => ['UE_APP'])
    )
    expect(status).to eq(422)
    expect(Workspaces::EnvironmentOverrides.new(workspace.id).load).to eq({})
  end

  it 'rejects oversized request bodies before mutation' do
    large = 'x' * (Workspaces::EnvironmentOverrides::MAX_BODY_BYTES + 1)

    status, = request(
      "/workspaces/#{workspace.id}/environment",
      headers: { 'HTTP_ORIGIN' => 'http://localhost:4747', 'CONTENT_LENGTH' => large.bytesize.to_s },
      form: large
    )

    expect(status).to eq(422)
    expect(Workspaces::EnvironmentOverrides.new(workspace.id).load).to eq({})
  end

  def install_recipe_with_overrides
    %w(server.rb ready.rb).each do |file|
      FileUtils.cp(File.join(__dir__, 'fixtures', file), Workspaces::Config.repo_root.join(file))
    end
    Workspaces::Config.repo_root.join('.workspaces.yml').write(YAML.dump(environment_recipe))
    git('add', '.workspaces.yml', 'server.rb', 'ready.rb')
    git('-c', 'core.hooksPath=/dev/null', 'commit', '-m', 'Fixture commands')
  end

  def environment_recipe
    provision = 'File.open("provisioned", "a") { |f| ' \
                'f.puts [ENV.fetch("UE_APP"), ENV.fetch("ROUTING_SUBDOMAIN")].join("|") }'
    { 'version' => 1,
      'env' => { 'UE_APP' => 'global-default', 'ROUTING_SUBDOMAIN' => 'routing-default' },
      'steps' => [
        {
          'id' => 'provision', 'name' => 'Provision fixture',
          'run' => ['ruby', '-e', provision], 'env' => { 'UE_APP' => 'fixture' }
        },
        { 'id' => 'app', 'name' => 'Run socket server', 'run' => ['ruby', 'server.rb'], 'background' => true },
        { 'id' => 'ready', 'name' => 'Verify fixture identity', 'run' => ['ruby', 'ready.rb'], 'timeout' => 15 }
      ] }
  end
end
