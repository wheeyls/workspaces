require_relative 'spec_helper'

RSpec.describe Workspaces::Progress do
  let(:now) { Time.utc(2026, 10, 19, 12, 0, 0) }
  let(:started_at) { (now - 100).iso8601 }

  def steps(*states, **starts)
    states.each_with_index.map do |state, index|
      key = "s#{index}"
      { 'key' => key, 'label' => "Step #{index}", 'state' => state, 'started_at' => starts[key.to_sym]&.iso8601 }
    end
  end

  def progress(step_list, estimates: {}, at: started_at)
    described_class.new(steps: step_list, estimates: estimates, started_at: at, now: now).to_h
  end

  describe 'with no history' do
    it 'weights every step equally and counts only finished steps' do
      expect(progress(steps('complete', 'active', 'pending', 'pending'))['percent']).to eq(25)
      expect(progress(steps('complete', 'complete', 'active', 'pending'))['percent']).to eq(50)
    end

    it 'offers no time estimate, because it has nothing to base one on' do
      result = progress(steps('active', 'pending'))

      expect(result['eta_text']).to be_nil
      expect(result['estimated']).to eq(false)
      expect(result['slow']).to eq(false)
    end
  end

  describe 'with history' do
    let(:estimates) { { 's0' => 10.0, 's1' => 70.0, 's2' => 20.0 } }

    it 'weights steps by how long they usually take' do
      expect(progress(steps('complete', 'pending', 'pending'), estimates: estimates)['percent']).to eq(10)
      expect(progress(steps('complete', 'complete', 'pending'), estimates: estimates)['percent']).to eq(80)
    end

    it 'counts the running step by how much of its usual time has passed' do
      list = steps('complete', 'active', 'pending', s1: now - 35)

      expect(progress(list, estimates: estimates)['percent']).to eq(10 + 35)
    end

    it 'holds a running step below done when it overruns, so the bar waits for it' do
      list = steps('complete', 'active', 'pending', s1: now - 500)

      expect(progress(list, estimates: estimates)['percent']).to eq(((10 + 70 * 0.95) / 100.0 * 100).floor)
    end

    it 'never reaches 100 while a run is still going' do
      list = steps('complete', 'complete', 'active', s2: now - 9999)

      expect(progress(list, estimates: estimates)['percent']).to be <= 99
    end

    it 'gives a step with no history the average weight of the ones that have it' do
      list = steps('complete', 'pending')

      expect(progress(list, estimates: { 's0' => 30.0 })['percent']).to eq(50)
    end

    it 'estimates the time left from what has not run yet and what remains of the current step' do
      list = steps('complete', 'active', 'pending', s1: now - 30)

      # 70s step, 30s in: 40s left on it, plus the 20s step that has not started.
      expect(progress(list, estimates: estimates)['eta_text']).to eq('About 1m 0s left')
    end

    it 'rounds the estimate so it does not flicker by single seconds' do
      expect(progress(steps('active', 'pending'), estimates: { 's0' => 200.0, 's1' => 183.0 })['eta_text']).to eq('About 6m 20s left')
    end

    it 'says it is almost done when little remains' do
      list = steps('complete', 'active', s1: now - 68)

      expect(progress(list, estimates: { 's0' => 5.0, 's1' => 70.0 })['eta_text']).to eq('Almost done')
    end

    it 'flags a step that is taking much longer than usual and stops promising a time' do
      list = steps('complete', 'active', 'pending', s1: now - 200)
      result = progress(list, estimates: estimates)

      expect(result['slow']).to eq(true)
      expect(result['eta_text']).to eq('Taking longer than usual')
    end

    it 'does not flag a step that is merely a little over' do
      list = steps('complete', 'active', 'pending', s1: now - 90)

      expect(progress(list, estimates: estimates)['slow']).to eq(false)
    end
  end

  it 'describes where the run is and how long it has been going' do
    result = progress(steps('complete', 'active', 'pending'))

    expect(result).to include('step_text' => 'Step 2 of 3', 'step_label' => 'Step 1', 'elapsed_seconds' => 100)
  end

  it 'points at the next step while one is pending between two steps' do
    expect(progress(steps('complete', 'pending', 'pending'))).to include('step_text' => 'Step 2 of 3', 'step_label' => 'Step 1')
  end

  it 'copes with missing timestamps, an unknown start and no steps at all' do
    expect(progress(steps('active', 'pending'), estimates: { 's0' => 10.0 })['percent']).to eq(0)
    expect(progress(steps('active'), at: nil)['elapsed_seconds']).to be_nil
    expect(progress(steps('active'), at: 'garbage')['elapsed_seconds']).to be_nil
    expect(progress([])).to be_nil
  end

  it 'treats a tiny recorded duration as at least a second so one step cannot own the whole bar' do
    expect(progress(steps('complete', 'pending'), estimates: { 's0' => 0.001, 's1' => 100.0 })['percent']).to eq(0)
  end
end
