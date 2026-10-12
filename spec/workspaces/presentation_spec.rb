require_relative 'spec_helper'

RSpec.describe Workspaces::Presentation do
  def present(overrides = {})
    described_class.new({ 'status' => 'idle', 'active' => false, 'steps' => [] }.merge(overrides)).to_h
  end

  def visible(view)
    view['sections'].select { |_name, shown| shown }.keys
  end

  it 'shows a brand new workspace only the environment editor, with a Start button' do
    view = present

    expect(view['state']).to eq('idle')
    expect(visible(view)).to eq(%w(environment))
    expect(view['environment_submit']).to eq('Start workspace')
    expect(view['actions']).to eq([{ 'key' => 'start', 'label' => 'Start workspace', 'primary' => true }])
    expect(view['hint']).to include('start the workspace')
  end

  it 'shows only progress and logs while the workspace is starting' do
    steps = [{ 'key' => 'deps', 'label' => 'Dependencies', 'state' => 'active' }]
    view = present('status' => 'preparing', 'active' => true, 'steps' => steps)

    expect(view['state']).to eq('busy')
    expect(visible(view)).to eq(%w(progress log))
    expect(view['actions']).to eq([])
    expect(view['hint']).to be_nil
  end

  it 'treats an active command on an otherwise ready workspace as busy' do
    view = present('status' => 'ready', 'active' => true)

    expect(view['state']).to eq('busy')
    expect(visible(view)).to eq(%w(log))
  end

  it 'offers every management section once the workspace is ready' do
    view = present('status' => 'ready', 'steps' => [{ 'key' => 'a', 'label' => 'A', 'state' => 'complete' }])

    expect(view['state']).to eq('ready')
    expect(visible(view)).to eq(%w(progress actions environment log details danger))
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
    expect(visible(view)).to include('progress', 'actions', 'environment', 'log')
    expect(view['environment_submit']).to eq('Save & retry')
    expect(view['actions'].map { |a| a['label'] }).to eq(['Retry setup'])
  end

  it 'lets a stopped workspace be started again without showing progress from the last run' do
    steps = [{ 'key' => 'a', 'label' => 'A', 'state' => 'complete' }]
    view = present('status' => 'stopped', 'steps' => steps)

    expect(view['state']).to eq('stopped')
    expect(visible(view)).to eq(%w(actions environment log details danger))
    expect(view['environment_submit']).to eq('Save & start')
  end

  it 'falls back to a minimal read-only view for unrecognised statuses' do
    view = present('status' => 'mystery')

    expect(view['state']).to eq('unknown')
    expect(visible(view)).to eq(%w(log details))
  end
end
