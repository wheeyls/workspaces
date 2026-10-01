require_relative 'spec_helper'
require 'json'

RSpec.describe Workspaces::DashboardView do
  let(:snapshot) do
    { 'workspace_id' => 'agent-123', 'status' => 'idle', 'active' => false, 'branch' => '<script>alert(1)</script>',
      'log_tail' => '<img src=x>', 'path' => '/tmp/workspace' }
  end

  it 'escapes branch/log content and uses workspace action URLs' do
    html = described_class.render(snapshot)
    expect(html).to include('&lt;script&gt;', '&lt;img src=x&gt;', '/workspaces/agent-123/start')
    expect(html).not_to include('<script>alert(1)</script>')
  end

  it 'renders active progress without actionable lifecycle controls' do
    steps = [{ 'key' => 'assets', 'label' => 'Building assets', 'state' => 'active' }]
    html = described_class.render(snapshot.merge('active' => true, 'status' => 'preparing',
                                                 'message' => 'Building assets', 'last_error' => '<b>error</b>',
                                                 'steps' => steps))
    expect(html).to include('Building assets', 'aria-current="step"', '&lt;b&gt;error&lt;/b&gt;')
    expect(html).to include('action="/workspaces/agent-123/environment"')
    expect(html).not_to include('/workspaces/agent-123/start', '/workspaces/agent-123/stop',
                                '/workspaces/agent-123/restart')
  end

  it 'puts errors above logs and offers retry rather than ineffective start stop buttons' do
    steps = [{ 'key' => 'assets', 'label' => 'Build assets', 'state' => 'failed' }]
    html = described_class.render(snapshot.merge('status' => 'error', 'failed_phase' => 'assets',
                                                 'last_error' => 'Build failed', 'operation' => 'prepare',
                                                 'steps' => steps))
    expect(html).to include('What went wrong', 'Build failed', 'Retry setup', 'data-step-state="failed"')
    expect(html.index('What went wrong')).to be < html.index('Live setup log')
    expect(html).not_to include('Stop server', 'Restart server')
  end

  it 'shows per-step duration for completed and failed steps when numeric duration exists' do
    steps = [
      { 'key' => 'deps', 'label' => 'Dependencies', 'state' => 'complete', 'duration_seconds' => 12.345 },
      { 'key' => 'assets', 'label' => 'Assets', 'state' => 'failed', 'duration_seconds' => 0.5 }
    ]

    html = described_class.render(snapshot.merge('status' => 'error', 'failed_phase' => 'assets',
                                                 'last_error' => 'Build failed', 'operation' => 'prepare',
                                                 'steps' => steps))

    expect(html).to include('complete · 12.345s')
    expect(html).to include('failed · 0.500s')
  end

  it 'shows state only for active pending and missing durations' do
    steps = [
      { 'key' => 'deps', 'label' => 'Dependencies', 'state' => 'pending' },
      { 'key' => 'assets', 'label' => 'Assets', 'state' => 'active', 'duration_seconds' => nil },
      { 'key' => 'ready', 'label' => 'Ready', 'state' => 'complete', 'duration_seconds' => nil }
    ]

    html = described_class.render(snapshot.merge('active' => true, 'status' => 'preparing',
                                                 'message' => 'Building assets', 'steps' => steps))

    expect(html).to include('<span class="step-outcome">pending</span>')
    expect(html).to include('<span class="step-outcome">active</span>')
    expect(html).to include('<span class="step-outcome">complete</span>')
    expect(html).not_to include('complete ·')
    expect(html).not_to include('active ·')
    expect(html).not_to include('pending ·')
  end

  it 'shows state only for null and negative completed durations' do
    steps = [
      { 'key' => 'complete-null', 'label' => 'Complete null', 'state' => 'complete', 'duration_seconds' => nil },
      { 'key' => 'failed-negative', 'label' => 'Failed negative', 'state' => 'failed', 'duration_seconds' => -1.234 }
    ]

    html = described_class.render(snapshot.merge('status' => 'error', 'failed_phase' => 'failed-negative',
                                                 'last_error' => 'Build failed', 'operation' => 'prepare',
                                                 'steps' => steps))

    expect(html).to include('<span class="step-outcome">complete</span>')
    expect(html).to include('<span class="step-outcome">failed</span>')
    expect(html).not_to include('complete ·')
    expect(html).not_to include('failed ·')
  end

  it 'offers server restart retry without pretending dependencies were rebuilt' do
    html = described_class.render(snapshot.merge('status' => 'error', 'operation' => 'restart',
                                                 'failed_phase' => 'booting', 'last_error' => 'Boot failed'))
    expect(html).to include('Retry restart', '/workspaces/agent-123/restart')
    expect(html).not_to include('Dependencies &amp; database', 'Build assets')
  end

  it 'renders editable values as escaped line-based settings without exposing hidden overrides' do
    html = described_class.render(snapshot.merge('environment_keys' => %w(APP_VARIANT SECRET_TOKEN),
                                                 'editable_environment' => { 'APP_VARIANT' => '<admin>' }))

    expect(html).to include('Editable environment', '/workspaces/agent-123/environment')
    expect(html).to include('name="editable_env"', 'APP_VARIANT=&lt;admin&gt;')
    expect(html).not_to include('SECRET_TOKEN=')
  end

  it 'supports snapshots without environment keys for older fixtures' do
    html = described_class.render(snapshot.merge('environment_keys' => nil))

    expect(html).to include('name="editable_env"')
    expect(html).to include('/workspaces/agent-123/environment')
  end

  it 'executes client-side step duration formatting with runtime-safe guards' do
    app_js = File.read(File.join(__dir__, '../../lib/workspaces/dashboard/app.js'))
    match = app_js.match(/function stepOutcome\(step\) \{.*?\n  \}/m)
    expect(match).not_to be_nil

    script = <<~NODE
      const vm = require('node:vm');
      #{match[0]}
      const cases = [
        { step: { state: 'complete', duration_seconds: 12.3456 }, expected: 'complete · 12.346s' },
        { step: { state: 'failed', duration_seconds: 0.5 }, expected: 'failed · 0.500s' },
        { step: { state: 'complete', duration_seconds: null }, expected: 'complete' },
        { step: { state: 'failed', duration_seconds: -1 }, expected: 'failed' },
        { step: { state: 'complete', duration_seconds: Infinity }, expected: 'complete' },
        { step: { state: 'complete', duration_seconds: 'abc' }, expected: 'complete' },
        { step: { state: 'active', duration_seconds: 2 }, expected: 'active' }
      ];
      const actual = cases.map((c) => stepOutcome(c.step));
      process.stdout.write(JSON.stringify({ actual, expected: cases.map((c) => c.expected) }));
    NODE

    output, status = Open3.capture2('node', '-e', script)
    expect(status.success?).to eq(true)
    result = JSON.parse(output)
    expect(result['actual']).to eq(result['expected'])
  end

  it 'shows the future preview destination and one selected log at a time' do
    html = described_class.render(snapshot.merge('log_source' => 'backend', 'log_tail' => '<backend only>'))

    expect(html).to include('Preview URL', 'http://ws-agent-123.localhost:4747/')
    expect(html).to include('Available when ready', 'Live backend log', '&lt;backend only&gt;')
    expect(html).to include('href="?log=backend" data-log-source="backend" aria-current="page"')
    expect(html).not_to include('href="?log=setup" data-log-source="setup" aria-current="page"')
    expect(html).to include("'/status?log=' + selectedLog")
    expect(html).to include("busy || selectedLog === 'backend' ? 2000 : 10000")
    expect(html.scan('id="log"').length).to eq(1)
  end

  it 'defaults to setup log when no source is supplied' do
    html = described_class.render(snapshot)

    expect(html).to include('Live setup log', 'href="?log=setup" data-log-source="setup" aria-current="page"')
    expect(html).to include('aria-label="Setup log"')
  end

  it 'isolates force removal in a Danger Zone with a typed ID confirmation' do
    html = described_class.render(snapshot)
    expect(html).to include('Danger Zone', 'action="/workspaces/agent-123/remove"')
    expect(html).to include('name="confirm_id"', 'Discard uncommitted and untracked changes')
    expect(html).to include('Delete workspace')
  end

  it 'shows a read-only inventory with explicit running state and timestamps' do
    html = described_class.index([
      snapshot.merge('id' => 'agent-123', 'created_at' => '2026-10-01T11:00:00Z',
                     'started_at' => '2026-10-01T12:00:00Z', 'status' => 'ready', 'running' => true),
      snapshot.merge('id' => 'agent-456', 'status' => 'error', 'running' => false)
    ])

    expect(html).to include('Running', 'Not running', '2026-10-01T11:00:00Z', '2026-10-01T12:00:00Z')
    expect(html).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
    expect(html).not_to include('<script>alert(1)</script>', '/workspaces/agent-123/remove')
  end

  it 'keeps the delete form disabled during a busy setup, including on the initial HTML response' do
    html = described_class.render(snapshot.merge('status' => 'preparing', 'active' => true))
    expect(html).to include('action="/workspaces/agent-123/remove"')
    expect(html).to match(/name="confirm_id"[^>]*disabled/)
    expect(html).to include('disabled>Delete workspace')
  end
end
