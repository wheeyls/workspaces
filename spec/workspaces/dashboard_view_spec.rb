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

  it 'presents a brand new workspace with only the environment editor and a start button' do
    html = described_class.render(snapshot.merge('editable_environment' => { 'UE_APP' => 'www' }))
    hidden = ->(name) { html.match?(/data-section="#{name}"[^>]*\shidden/) }

    expect(hidden.call('technical')).to eq(true)
    expect(hidden.call('log')).to eq(true)
    expect(hidden.call('actions')).to eq(true)
    expect(hidden.call('details')).to eq(true)
    expect(hidden.call('danger')).to eq(true)
    expect(hidden.call('lead')).to eq(false)
    expect(hidden.call('environment')).to eq(false)
    expect(html).to include("Let&#39;s get your workspace running", 'Choose what to preview')
    expect(html).to match(/id="environment-disclosure"[^>]*\sopen/)
    expect(html).to match(/data-env-submit\s*>Start workspace<\/button>/)
  end

  it 'shows only the step logs while starting' do
    steps = [{ 'key' => 'deps', 'label' => 'Dependencies', 'state' => 'active' }]
    html = described_class.render(snapshot.merge('status' => 'preparing', 'active' => true, 'steps' => steps))
    hidden = ->(name) { html.match?(/data-section="#{name}"[^>]*\shidden/) }

    expect(hidden.call('log')).to eq(false)
    expect(html).to include('data-step-log="deps"')
    %w(actions environment details danger).each { |name| expect(hidden.call(name)).to eq(true) }
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

    expect(html).to include('complete · 12.3s')
    expect(html).to include('failed · 0.5s')
  end

  it 'shows state only for active pending and missing durations' do
    steps = [
      { 'key' => 'deps', 'label' => 'Dependencies', 'state' => 'pending' },
      { 'key' => 'assets', 'label' => 'Assets', 'state' => 'active', 'duration_seconds' => nil },
      { 'key' => 'ready', 'label' => 'Ready', 'state' => 'complete', 'duration_seconds' => nil }
    ]

    html = described_class.render(snapshot.merge('active' => true, 'status' => 'preparing',
                                                 'message' => 'Building assets', 'steps' => steps))

    expect(html).to include('<span class="step-log__outcome step-outcome">pending</span>')
    expect(html).to include('<span class="step-log__outcome step-outcome">active</span>')
    expect(html).to include('<span class="step-log__outcome step-outcome">complete</span>')
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

    expect(html).to include('<span class="step-log__outcome step-outcome">complete</span>')
    expect(html).to include('<span class="step-log__outcome step-outcome">failed</span>')
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

    expect(html).to include('Choose what to preview', '/workspaces/agent-123/environment')
    expect(html).to include('name="editable_env"', 'APP_VARIANT=&lt;admin&gt;')
    expect(html).not_to include('id="environment-preset"')
    expect(html).not_to include('SECRET_TOKEN=')
  end

  it 'renders escaped environment preset buttons and JSON data for client-side draft fill' do
    html = described_class.render(snapshot.merge(
                                  'environment_presets' => {
                                    '<Admin>' => { 'UE_APP' => 'admin', 'ROUTING_SUBDOMAIN' => 'admin' },
                                    'Vendor' => { 'UE_APP' => 'vendor', 'ROUTING_SUBDOMAIN' => 'vendors' }
                                  }
                                ))

    expect(html).to include('role="group" aria-labelledby="environment-preset-label"')
    expect(html).to include('type="button" class="button button--subtle env-preset-button" data-environment-preset="&lt;Admin&gt;" aria-pressed="false"')
    expect(html).to include('type="button" class="button button--subtle env-preset-button" data-environment-preset="Vendor" aria-pressed="false"')
    expect(html).to include('data-preset-controls hidden')
    expect(html).to include('data-environment-presets="')
    expect(html).to include('&quot;&lt;Admin&gt;&quot;')
    expect(html).to include('ROUTING_SUBDOMAIN=admin')
    expect(html).to include('UE_APP=admin')
    expect(html).to include('&quot;Vendor&quot;')
    expect(html).to include('ROUTING_SUBDOMAIN=vendors')
    expect(html).to include('UE_APP=vendor')
    expect(html).to include("'Preset loaded into draft only. Use ' + submitLabel() + ' to apply changes.'")
  end

  it 'supports snapshots without environment keys for older fixtures' do
    html = described_class.render(snapshot.merge('environment_keys' => nil))

    expect(html).to include('name="editable_env"')
    expect(html).to include('/workspaces/agent-123/environment')
  end

  it 'executes client-side step duration formatting with runtime-safe guards' do
    app_js = File.read(File.join(__dir__, '../../lib/workspaces/dashboard/app.js'))
    format_fn = app_js.match(/function formatDuration\(seconds\) \{.*?\n  \}\n/m)
    match = app_js.match(/function stepOutcome\(step\) \{.*?\n  \}/m)
    expect([format_fn, match]).to all(be_truthy)

    script = <<~NODE
      const vm = require('node:vm');
      #{format_fn[0]}
      #{match[0]}
      const cases = [
        { step: { state: 'complete', duration_seconds: 12.3456 }, expected: 'complete · 12.3s' },
        { step: { state: 'failed', duration_seconds: 0.5 }, expected: 'failed · 0.5s' },
        { step: { state: 'complete', duration_seconds: 137 }, expected: 'complete · 2m 17s' },
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
    expect(html).to match(/href="\?log=backend" id="backend-tab" data-log-source="backend" aria-current="page"/)
    expect(html).not_to include('href="?log=setup" data-log-source="setup" aria-current="page"')
    expect(html).to match(/id="steps"[^>]*\shidden/)
    expect(html).to include('aria-label="Web server log"')
    expect(html).to include("'/status?log=' + selectedLog")
    expect(html).to include("busy || selectedLog === 'backend' ? 2000 : 10000")
    expect(html.scan('id="log"').length).to eq(1)
  end

  it 'defaults to setup log when no source is supplied' do
    html = described_class.render(snapshot)

    expect(html).to include('Live setup log', 'href="?log=setup" data-log-source="setup" aria-current="page"', 'Setup steps')
    expect(html).to include('aria-label="Full setup log"')
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
    expect(html).not_to include('<script>alert(1)</script>', '/workspaces/agent-123/remove')
  end

  it 'lists workspaces in a table keyed by ID without repeating the branch' do
    html = described_class.index([
      snapshot.merge('id' => 'agent-123', 'status' => 'ready', 'running' => true, 'branch' => 'workspaces/agent-123')
    ])

    expect(html).to include('<table class="workspace-table">', '<th scope="row"><a href="/workspaces/agent-123">agent-123</a></th>')
    expect(html).to include('<th scope="col">Workspace</th>', '<th scope="col">Status</th>', 'Last startup')
    expect(html).not_to include('workspaces/agent-123</')
  end

  it 'shows an empty message instead of an empty table when there are no workspaces' do
    html = described_class.index([])

    expect(html).to include('No workspaces yet.')
    expect(html).not_to include('<table')
  end

  it 'keeps the delete form disabled during a busy setup, including on the initial HTML response' do
    html = described_class.render(snapshot.merge('status' => 'preparing', 'active' => true))
    expect(html).to include('action="/workspaces/agent-123/remove"')
    expect(html).to match(/name="confirm_id"[^>]*disabled/)
    expect(html).to include('disabled>Delete workspace')
  end

  it 'keeps required control ids and orders the page lead, then settings, then technical details' do
    html = described_class.render(snapshot.merge('status' => 'ready'))

    status_index = html.index('id="status"')
    settings_index = html.index('id="environment-disclosure"')
    technical_index = html.index('id="technical-disclosure"')
    log_index = html.index('id="log-title"')
    danger_index = html.index('Danger Zone')

    expect([status_index, settings_index, technical_index, log_index, danger_index]).to all(be_a(Integer))
    expect(status_index).to be < settings_index
    expect(settings_index).to be < technical_index
    expect(technical_index).to be < log_index
    expect(log_index).to be < danger_index
    expect(html).to include('id="actions"', 'id="preview"', 'id="environment-form"', 'id="remove-form"')
  end

  it 'leads a ready workspace with one Open button and keeps the scary parts inside collapsed technical details' do
    steps = [{ 'key' => 'deps', 'label' => 'Install Ruby dependencies', 'state' => 'complete' }]
    html = described_class.render(snapshot.merge('status' => 'ready', 'steps' => steps))
    technical = html[/<details[^>]*id="technical-disclosure".*<\/main>/m]

    expect(html).to include('Your workspace is ready')
    expect(html).to match(/id="preview"[^>]*href="http:\/\/ws-agent-123[^"]*"(?![^>]*\shidden)/)
    expect(html).not_to match(/id="technical-disclosure"[^>]*\sopen/)
    expect(html).not_to match(/id="environment-disclosure"[^>]*\sopen/)
    expect(technical).to include('Install Ruby dependencies', 'Live setup log', 'Danger Zone')
    expect(html.index('Install Ruby dependencies')).to be > html.index('id="technical-disclosure"')
  end

  describe 'build progress bar' do
    let(:started) { (Time.now.utc - 90).iso8601 }
    let(:steps) do
      [{ 'key' => 'gems', 'label' => 'Install gems', 'state' => 'complete', 'duration_seconds' => 30.0 },
       { 'key' => 'assets', 'label' => 'Build <assets>', 'state' => 'active', 'started_at' => (Time.now.utc - 20).iso8601 },
       { 'key' => 'ready', 'label' => 'Wait for readiness', 'state' => 'pending' }]
    end

    def render_busy(extra = {})
      described_class.render(snapshot.merge('status' => 'preparing', 'active' => true, 'steps' => steps,
                                            'prepare_started_at' => started, 'estimates' => { 'gems' => 30.0, 'assets' => 100.0, 'ready' => 20.0 })
                                      .merge(extra))
    end

    it 'leads a build with the headline and a progressbar that carries its value and a readable summary' do
      html = render_busy

      expect(html).to include('Setting things up…')
      expect(html).to match(/id="build-progress"(?![^>]*\shidden)/)
      expect(html).to match(/role="progressbar"[^>]*aria-valuemin="0"[^>]*aria-valuemax="100"[^>]*aria-valuenow="(\d+)"/)
      expect(html).to include('Step 2 of 3 · Build &lt;assets&gt;')
      expect(html).to match(/aria-valuetext="Step 2 of 3 · Build &lt;assets&gt;\. About [^"]*left"/)
      expect(html).not_to include('This usually takes a few minutes')
    end

    it 'sizes the fill to the percentage and shows it as text beside the elapsed time' do
      html = render_busy
      percent = html[/aria-valuenow="(\d+)"/, 1]

      expect(html).to include(%(style="inline-size: #{percent}%"), %(id="progress-percent">#{percent}%</span>))
      expect(html).to match(/id="elapsed">1m 3?\ds</).or match(/id="elapsed">1m \d+s</)
    end

    it 'says nothing about time without history, only which step it is on' do
      html = render_busy('estimates' => {})

      expect(html).to include('Step 2 of 3')
      expect(html).to include('id="progress-eta"></span>')
      expect(html).not_to include('left<')
    end

    it 'marks a slow step so it can be styled, and says it is taking longer than usual' do
      slow = steps.map { |s| s['key'] == 'assets' ? s.merge('started_at' => (Time.now.utc - 400).iso8601) : s }
      html = described_class.render(snapshot.merge('status' => 'preparing', 'active' => true, 'steps' => slow,
                                                   'prepare_started_at' => started, 'estimates' => { 'assets' => 100.0 }))

      expect(html).to include('data-slow="true"', 'Taking longer than usual')
    end

    it 'is in the page but hidden when no build is running, so a poll can reveal it' do
      html = described_class.render(snapshot.merge('status' => 'ready'))

      expect(html).to match(/id="build-progress"[^>]*\shidden/)
      expect(html).not_to include('role="progressbar"[^>]*aria-valuenow="[1-9]')
    end

    it 'no longer renders the old summary and subtitle lines for a build' do
      html = render_busy

      expect(html).not_to include('id="subtitle"', 'subtitle-text')
    end
  end

  describe 'current preset badge' do
    let(:presets) { { 'www' => { 'UE_APP' => 'www' }, '<Admin>' => { 'UE_APP' => 'admin' } } }

    def badge(html)
      html[/<span class="badge" id="environment-preset-badge"[^>]*>.*?<\/span>/m]
    end

    it 'shows which preset is active in the closed section header' do
      html = described_class.render(snapshot.merge('status' => 'ready', 'environment_presets' => presets,
                                                   'editable_environment' => { 'UE_APP' => 'www' }))

      expect(badge(html)).to eq('<span class="badge" id="environment-preset-badge" >Preset: www</span>')
      expect(html).not_to match(/id="environment-disclosure"[^>]*\sopen/)
      expect(html.index('id="environment-preset-badge"')).to be_between(html.index('id="environment-disclosure"'),
                                                                          html.index('id="environment-form"'))
    end

    it 'keeps the badge in the page but hidden when no preset matches, so a poll can reveal it' do
      html = described_class.render(snapshot.merge('environment_presets' => presets,
                                                   'editable_environment' => { 'UE_APP' => 'custom' }))

      expect(badge(html)).to match(/id="environment-preset-badge" hidden>\s*<\/span>/)
    end

    it 'escapes the preset name' do
      html = described_class.render(snapshot.merge('environment_presets' => presets,
                                                   'editable_environment' => { 'UE_APP' => 'admin' }))

      expect(badge(html)).to include('Preset: &lt;Admin&gt;')
      expect(html).not_to include('Preset: <Admin>')
    end
  end

  describe 'step logs' do
    let(:steps) do
      [{ 'key' => 'gems', 'label' => 'Install gems', 'state' => 'complete', 'duration_seconds' => 12.1 },
       { 'key' => 'app', 'label' => 'Start server', 'state' => 'failed', 'duration_seconds' => 0.5 },
       { 'key' => 'ready', 'label' => 'Wait for readiness', 'state' => 'pending' }]
    end
    let(:step_logs) do
      { 'gems' => { 'text' => "Bundle <complete>\n", 'truncated' => false },
        'app' => { 'text' => "boom\nERROR: exited\n", 'truncated' => false } }
    end

    def render_steps(extra = {})
      described_class.render(snapshot.merge('status' => 'error', 'operation' => 'prepare', 'steps' => steps,
                                            'step_logs' => step_logs, 'log_tail' => "==> Install gems\n").merge(extra))
    end

    def step_markup(html, key)
      html[/<details class="step-log"[^>]*data-step-log="#{key}".*?<\/details>/m]
    end

    it 'offers re-run controls inside a step only for the modes the server allows' do
      resume = { 'step_modes' => { 'gems' => %w(only from), 'ready' => %w(from) }, 'retry_from' => nil }
      html = render_steps('status' => 'ready', 'resume' => resume)

      expect(step_markup(html, 'gems')).to include('/workspaces/agent-123/resume?only=gems', 'Re-run this step',
                                                   '/workspaces/agent-123/resume?from=gems', 'Re-run from here')
      expect(step_markup(html, 'ready')).to include('resume?from=ready')
      expect(step_markup(html, 'ready')).not_to include('resume?only=')
    end

    it 'renders no re-run controls when nothing can be re-run' do
      expect(step_markup(render_steps, 'gems')).not_to include('resume?')
    end

    it 'renders each recipe step as its own accordion carrying only that step\'s output' do
      html = render_steps

      expect(step_markup(html, 'gems')).to include('Install gems', 'complete · 12.1s', 'Bundle &lt;complete&gt;')
      expect(step_markup(html, 'gems')).not_to include('boom')
      expect(step_markup(html, 'app')).to include('Start server', 'boom', 'ERROR: exited')
      expect(step_markup(html, 'app')).not_to include('Bundle')
      expect(html).not_to include('<ol class="stepper"')
    end

    it 'opens running and failed steps and leaves completed and waiting ones closed' do
      html = render_steps

      expect(step_markup(html, 'gems')).not_to match(/\sopen[\s>]/)
      expect(step_markup(html, 'app')).to match(/data-step-state="failed" open/)
      expect(step_markup(html, 'ready')).not_to match(/\sopen[\s>]/)
      active = described_class.render(snapshot.merge('status' => 'preparing', 'active' => true,
                                                     'steps' => [steps.first.merge('state' => 'active')]))
      expect(step_markup(active, 'gems')).to match(/data-step-state="active" open aria-current="step"/)
    end

    it 'keeps the full setup log reachable as a last, closed accordion after the steps' do
      html = render_steps

      expect(html.index('data-step-log="ready"')).to be < html.index('id="full-log"')
      expect(html).to match(/<details class="step-log step-log--full" id="full-log" data-step-log="full">/)
      expect(html).to include('Full setup log')
    end

    it 'shows an empty state for a step that has not written anything yet' do
      expect(step_markup(render_steps, 'ready')).to include('<pre tabindex="0" aria-label="Wait for readiness output"></pre>')
    end

    it 'offers the Web server log tab only when a backend log exists, and always when viewing it' do
      expect(render_steps).to match(/id="backend-tab"[^>]*\shidden/)
      expect(render_steps('backend_log_available' => true)).not_to match(/id="backend-tab"[^>]*\shidden/)
      expect(render_steps('log_source' => 'backend')).not_to match(/id="backend-tab"[^>]*\shidden/)
    end

    it 'shows the total run time on the Full setup log row once a run has finished' do
      all_complete = steps.map { |step| step.merge('state' => 'complete', 'duration_seconds' => 1.0) }
      done = render_steps('status' => 'ready', 'steps' => all_complete, 'total_seconds' => 137.4)
      failed = render_steps('total_seconds' => 61.2)

      expect(done).to include('<span class="step-log__outcome" id="full-log-outcome">complete · 2m 17s</span>')
      expect(failed).to include('id="full-log-outcome">failed · 1m 1s</span>')
    end

    it 'labels the Full setup log row "in progress" while running and falls back when no total exists' do
      running = described_class.render(snapshot.merge('status' => 'preparing', 'active' => true, 'total_seconds' => 9,
                                                      'steps' => [steps.first.merge('state' => 'active')]))

      expect(running).to include('id="full-log-outcome">in progress</span>')
      expect(render_steps).to include('id="full-log-outcome">everything, in order</span>')
    end

    it 'writes durations as minutes and seconds, never a large bare seconds count' do
      long = [{ 'key' => 'gems', 'label' => 'Gems', 'state' => 'complete', 'duration_seconds' => 240.0 },
              { 'key' => 'app', 'label' => 'App', 'state' => 'complete', 'duration_seconds' => 137.4 },
              { 'key' => 'ready', 'label' => 'Ready', 'state' => 'complete', 'duration_seconds' => 0.5 }]
      html = described_class.render(snapshot.merge('status' => 'ready', 'steps' => long, 'step_logs' => {}))

      expect(html).to include('complete · 4m 0s', 'complete · 2m 17s', 'complete · 0.5s')
      expect(html).not_to match(/complete · \d{3,}s/)
    end

    it 'escapes step names and output' do
      html = described_class.render(snapshot.merge(
        'steps' => [{ 'key' => 'x', 'label' => '<b>step</b>', 'state' => 'complete' }],
        'step_logs' => { 'x' => { 'text' => '<script>alert(1)</script>', 'truncated' => false } }
      ))

      expect(html).not_to include('<b>step</b>', '<script>alert(1)</script>')
      expect(html).to include('&lt;b&gt;step&lt;/b&gt;', '&lt;script&gt;alert(1)&lt;/script&gt;')
    end
  end

  it 'opens the technical details when setup has failed so the cause is visible' do
    html = described_class.render(snapshot.merge('status' => 'error', 'operation' => 'prepare',
                                                 'last_error' => 'Build failed'))

    expect(html).to match(/id="technical-disclosure"[^>]*\sopen/)
    expect(html).to include("Something didn&#39;t go to plan", 'Retry setup')
  end

  it 'offers a large Start button as the lead action for a stopped workspace' do
    html = described_class.render(snapshot.merge('status' => 'stopped'))

    expect(html).to include('Your workspace is paused')
    expect(html).to match(%r{id="lead-action"[^>]*><form method="post" action="/workspaces/agent-123/start"><button class="button button--primary button--large">Start workspace})
  end
end
