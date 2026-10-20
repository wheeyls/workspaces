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
    expect(view['open']).to eq('environment' => true, 'technical' => false)
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
    expect(view['open']).to eq('environment' => false, 'technical' => true)
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

  it 'leads a ready workspace with one Open button and tucks everything else away' do
    view = present('status' => 'ready', 'steps' => [{ 'key' => 'a', 'label' => 'A', 'state' => 'complete' }])

    expect(view['state']).to eq('ready')
    expect(view['headline']).to eq('Your workspace is ready')
    expect(view['lead_action']).to eq('kind' => 'open', 'label' => 'Open workspace')
    expect(visible(view)).to eq(%w(lead actions environment technical log details danger))
    expect(view['open']).to eq('environment' => false, 'technical' => false)
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

  it 'opens the technical details on a failure so the cause is never hidden, and offers retry up front' do
    view = present('status' => 'error', 'operation' => 'restart', 'last_error' => 'boom',
                   'steps' => [{ 'key' => 'a', 'label' => 'A', 'state' => 'failed' }])

    expect(view['open']['technical']).to eq(true)
    expect(view['lead_action']).to include('kind' => 'post', 'key' => 'restart', 'label' => 'Retry restart')
    expect(present('status' => 'interrupted')['open']['technical']).to eq(true)
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
end
