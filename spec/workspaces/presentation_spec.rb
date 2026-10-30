require_relative 'spec_helper'

RSpec.describe Workspaces::Presentation do
  def present(overrides = {})
    described_class.new({ 'status' => 'idle', 'active' => false, 'steps' => [] }.merge(overrides)).to_h
  end

  def visible(view)
    view['sections'].select { |_name, shown| shown }.keys
  end

  it 'leads a brand new workspace with a friendly headline and only the settings, no technical detail' do
    view = present

    expect(view['state']).to eq('idle')
    expect(visible(view)).to eq(%w(lead environment))
    expect(view['headline']).to eq("Let's get your workspace running")
    expect(view['summary']).to include('then start')
    expect(view['environment_submit']).to eq('Start workspace')
    expect(view).not_to have_key('open')
    expect(view['lead_action']).to be_nil
    expect(view['actions']).to eq([{ 'key' => 'start', 'label' => 'Start workspace', 'primary' => true }])
  end

  it 'shows only progress and logs while the workspace is starting' do
    steps = [{ 'key' => 'deps', 'label' => 'Dependencies', 'state' => 'active' }]
    view = present('status' => 'preparing', 'active' => true, 'steps' => steps)

    expect(view['state']).to eq('busy')
    expect(visible(view)).to eq(%w(lead technical log))
    expect(view['actions']).to eq([])
    expect(view['lead_action']).to be_nil
  end

  it 'has a friendly headline while busy, with the detail carried by the progress bar instead' do
    busy = present('status' => 'preparing', 'active' => true,
                   'steps' => [{ 'key' => 'gems', 'label' => 'Install Ruby dependencies', 'state' => 'active' }])

    expect(busy['headline']).to eq('Setting things up…')
    expect(busy['progress']['step_label']).to eq('Install Ruby dependencies')
    expect(present('status' => 'ready', 'steps' => [{ 'key' => 'gems', 'label' => 'G', 'state' => 'complete' }])['progress']).to be_nil
  end

  it 'treats an active command on an otherwise ready workspace as busy' do
    view = present('status' => 'ready', 'active' => true)

    expect(view['state']).to eq('busy')
    expect(visible(view)).to eq(%w(lead technical log))
  end

  it 'leads a ready workspace with one Open button and every section available' do
    view = present('status' => 'ready', 'steps' => [{ 'key' => 'a', 'label' => 'A', 'state' => 'complete' }])

    expect(view['state']).to eq('ready')
    expect(view['headline']).to eq('Your workspace is ready')
    expect(view['lead_action']).to eq('kind' => 'open', 'label' => 'Open workspace')
    expect(visible(view)).to eq(%w(lead actions environment technical log details danger))
    expect(view['environment_submit']).to eq('Save & restart')
    expect(view['ready']).to eq(true)
  end

  it 'hides the progress section when there are no steps to show' do
    expect(visible(present('status' => 'ready'))).not_to include('progress')
  end

  it 'offers retry and the environment editor after a failure' do
    steps = [{ 'key' => 'a', 'label' => 'A', 'state' => 'failed' }]
    view = present('status' => 'error', 'operation' => 'prepare', 'last_error' => 'boom', 'steps' => steps)

    expect(view['state']).to eq('error')
    expect(visible(view)).to include('lead', 'technical', 'actions', 'environment', 'log')
    expect(view['environment_submit']).to eq('Save & retry')
    expect(view['actions'].map { |a| a['label'] }).to eq(['Retry setup'])
  end

  describe 'retrying from the failed step' do
    let(:steps) do
      [{ 'key' => 'gems', 'label' => 'Install gems', 'state' => 'complete' },
       { 'key' => 'ready', 'label' => 'Readiness', 'state' => 'failed' }]
    end
    let(:resume) do
      { 'retry_from' => 'ready', 'retry_label' => 'Readiness',
        'step_modes' => { 'gems' => %w(from), 'ready' => %w(from) } }
    end

    it 'leads with the retry, keeps a full re-run as the second choice, and names the step' do
      view = present('status' => 'error', 'operation' => 'prepare', 'last_error' => 'boom', 'steps' => steps, 'resume' => resume)

      expect(view['lead_action']).to include('kind' => 'post', 'key' => 'resume', 'label' => 'Retry failed step')
      expect(view['actions']).to eq([{ 'key' => 'resume', 'label' => 'Retry failed step', 'primary' => true },
                                     { 'key' => 'prepare', 'label' => 'Re-run all steps', 'primary' => false }])
      expect(view['summary']).to include('"Readiness" didn\'t finish', 'keeps everything that already finished')
    end

    it 'says where a retry really begins when it has to start earlier than the failed step' do
      resume['retry_label'] = 'Start server'
      view = present('status' => 'error', 'operation' => 'prepare', 'steps' => steps, 'resume' => resume)

      expect(view['summary']).to include('"Readiness" didn\'t finish', 'from "Start server"')
    end

    it 'calls a retry after an interruption "Continue setup"' do
      view = present('status' => 'interrupted', 'operation' => 'prepare', 'steps' => steps, 'resume' => resume)

      expect(view['lead_action']).to include('key' => 'resume', 'label' => 'Continue setup')
      expect(view['summary']).to include('interrupted during')
    end

    it 'falls back to the full re-run when nothing can be resumed' do
      view = present('status' => 'error', 'operation' => 'prepare', 'steps' => steps, 'resume' => nil)

      expect(view['lead_action']).to include('key' => 'prepare', 'label' => 'Retry setup')
      expect(view['actions'].map { |action| action['key'] }).to eq(%w(prepare))
    end

    it 'exposes per-step re-run modes only while idle' do
      ready = present('status' => 'ready', 'running' => true, 'steps' => steps.map { |s| s.merge('state' => 'complete') },
                      'resume' => resume.merge('retry_from' => nil, 'step_modes' => { 'gems' => %w(only from) }))
      busy = present('status' => 'preparing', 'active' => true, 'steps' => steps, 'resume' => resume)

      expect(ready['resume']['step_modes']).to eq('gems' => %w(only from))
      expect(busy['resume']).to be_nil
    end
  end

  it 'shows the technical section on a failure so the cause is never hidden, and offers retry up front' do
    view = present('status' => 'error', 'operation' => 'restart', 'last_error' => 'boom',
                   'steps' => [{ 'key' => 'a', 'label' => 'A', 'state' => 'failed' }])

    expect(visible(view)).to include('technical', 'log')
    expect(view['lead_action']).to include('kind' => 'post', 'key' => 'restart', 'label' => 'Retry restart')
    expect(visible(present('status' => 'interrupted'))).to include('technical', 'log')
  end

  it 'offers Start as the lead action for a stopped workspace' do
    view = present('status' => 'stopped')

    expect(view['headline']).to eq('Your workspace is paused')
    expect(view['lead_action']).to include('kind' => 'post', 'key' => 'start', 'label' => 'Start workspace')
  end

  it 'lets a stopped workspace be started again without showing progress from the last run' do
    steps = [{ 'key' => 'a', 'label' => 'A', 'state' => 'complete' }]
    view = present('status' => 'stopped', 'steps' => steps)

    expect(view['state']).to eq('stopped')
    expect(visible(view)).to eq(%w(lead actions environment technical log details danger))
    expect(view['environment_submit']).to eq('Save & start')
  end

  describe 'current preset' do
    let(:presets) do
      { 'www' => { 'UE_APP' => 'www', 'STRICT' => 'true' }, 'admin' => { 'UE_APP' => 'admin', 'STRICT' => 'true' } }
    end

    it 'names the preset whose values exactly match the saved settings' do
      view = present('environment_presets' => presets, 'editable_environment' => { 'UE_APP' => 'admin', 'STRICT' => 'true' })

      expect(view['current_preset']).to eq('admin')
    end

    it 'is nil when the settings match none, such as after a hand edit or an added variable' do
      edited = present('environment_presets' => presets, 'editable_environment' => { 'UE_APP' => 'admin', 'STRICT' => 'false' })
      extra = present('environment_presets' => presets,
                      'editable_environment' => { 'UE_APP' => 'www', 'STRICT' => 'true', 'EXTRA' => '1' })

      expect([edited['current_preset'], extra['current_preset']]).to eq([nil, nil])
    end

    it 'is nil without presets or without settings, and tolerates non-string values and older snapshots' do
      expect(present('editable_environment' => { 'UE_APP' => 'www' })['current_preset']).to be_nil
      expect(present('environment_presets' => presets, 'editable_environment' => {})['current_preset']).to be_nil
      expect(present('environment_presets' => nil, 'editable_environment' => nil)['current_preset']).to be_nil
      numeric = present('environment_presets' => { 'on' => { 'LEVEL' => '1' } }, 'editable_environment' => { 'LEVEL' => 1 })
      expect(numeric['current_preset']).to eq('on')
    end

    it 'breaks a tie by the recipe\'s order when two presets have identical values' do
      same = { 'first' => { 'A' => '1' }, 'second' => { 'A' => '1' } }

      expect(present('environment_presets' => same, 'editable_environment' => { 'A' => '1' })['current_preset']).to eq('first')
    end
  end

  describe 'total run time' do
    it 'reports how a finished run ended and how long it took' do
      done = present('status' => 'ready', 'total_seconds' => 137.4)
      failed = present('status' => 'error', 'total_seconds' => 61, 'steps' => [{ 'key' => 'a', 'label' => 'A', 'state' => 'failed' }])

      expect(done['total']).to eq('state' => 'complete', 'seconds' => 137.4)
      expect(failed['total']).to eq('state' => 'failed', 'seconds' => 61)
    end

    it 'has no total while a run is in progress, when none was recorded, or for interrupted runs' do
      expect(present('status' => 'preparing', 'active' => true, 'total_seconds' => 5)['total']).to be_nil
      expect(present('status' => 'ready')['total']).to be_nil
      expect(present('status' => 'interrupted', 'total_seconds' => nil)['total']).to be_nil
    end
  end

  it 'falls back to a minimal read-only view for unrecognised statuses' do
    view = present('status' => 'mystery')

    expect(view['state']).to eq('unknown')
    expect(visible(view)).to eq(%w(lead technical log details))
  end

  describe 'sleeping' do
    let(:steps) { [{ 'key' => 'app', 'label' => 'Server', 'state' => 'complete' }] }

    it 'explains that an asleep workspace keeps its work and offers to wake it' do
      view = present('status' => 'sleeping', 'sleep_after_seconds' => 1800, 'steps' => steps)

      expect(view['state']).to eq('sleeping')
      expect(view['headline']).to eq('Your workspace is asleep')
      expect(view['summary']).to include('files and data are kept', 'wakes')
      expect(view['lead_action']).to eq('kind' => 'post', 'key' => 'start', 'label' => 'Wake workspace')
      expect(view['actions'].map { |a| a['key'] }).to eq(%w(start keep-awake))
      expect(view['ready']).to be(false)
      expect(view['sleep']).to eq('keep_awake' => false, 'after_seconds' => 1800)
    end

    it 'offers keep-awake on a ready workspace and allow-sleep once it is on' do
      ready = present('status' => 'ready', 'sleep_after_seconds' => 900, 'steps' => steps)
      kept = present('status' => 'ready', 'sleep_after_seconds' => 900, 'keep_awake' => true, 'steps' => steps)

      expect(ready['actions'].map { |a| a['key'] }).to eq(%w(prepare restart stop keep-awake))
      expect(kept['actions'].map { |a| a['key'] }).to eq(%w(prepare restart stop allow-sleep))
      expect(kept['sleep']).to eq('keep_awake' => true, 'after_seconds' => 900)
    end

    it 'says nothing about sleeping when sleeping is switched off' do
      view = present('status' => 'ready', 'sleep_after_seconds' => nil, 'steps' => steps)

      expect(view['sleep']).to be_nil
      expect(view['actions'].map { |a| a['key'] }).to eq(%w(prepare restart stop))
    end

    it 'shows a waking workspace as busy, like any start' do
      view = present('status' => 'preparing', 'active' => true, 'steps' => steps)

      expect(view['state']).to eq('busy')
      expect(view['sleep']).to be_nil
    end
  end
end
