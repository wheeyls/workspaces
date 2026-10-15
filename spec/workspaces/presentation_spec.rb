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
    expect(visible(view)).to eq(%w(lead progress technical log))
    expect(view['actions']).to eq([])
    expect(view['lead_action']).to be_nil
    expect(view['open']).to eq('environment' => false, 'technical' => true)
  end

  it 'names the current step quietly under the headline while busy, and nowhere else' do
    busy = present('status' => 'preparing', 'active' => true, 'message' => 'Install Ruby dependencies')

    expect(busy['headline']).to eq('Setting things up…')
    expect(busy['subtitle']).to eq('Install Ruby dependencies')
    expect(present('status' => 'ready', 'message' => 'Workspace ready')['subtitle']).to be_nil
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
    expect(visible(view)).to eq(%w(lead progress actions environment technical log details danger))
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
    expect(visible(view)).to include('lead', 'technical', 'progress', 'actions', 'environment', 'log')
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

  it 'falls back to a minimal read-only view for unrecognised statuses' do
    view = present('status' => 'mystery')

    expect(view['state']).to eq('unknown')
    expect(visible(view)).to eq(%w(lead technical log details))
  end
end
