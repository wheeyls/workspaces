require_relative 'spec_helper'

RSpec.describe Workspaces::BuildHistory do
  def record(result: 'complete', steps: [], total: 10.0, id: 'ws-1', operation: 'prepare', at: Time.utc(2026, 10, 19, 12))
    described_class.record(workspace_id: id, operation: operation, result: result, total_seconds: total,
                           steps: steps, now: at)
  end

  def step(id, seconds, state = 'complete')
    { 'key' => id, 'state' => state, 'duration_seconds' => seconds }
  end

  it 'appends one JSON object per finished run to a file under the home' do
    record(steps: [step('gems', 12.5), step('app', 0.4)])
    record(result: 'failed', id: 'ws-2', steps: [step('gems', 3.0, 'failed')], total: 3.2)

    lines = Workspaces::Config.build_history_path.read.lines.map { |line| JSON.parse(line) }

    expect(lines.length).to eq(2)
    expect(lines.first).to include('at' => '2026-10-19T12:00:00Z', 'workspace_id' => 'ws-1', 'operation' => 'prepare',
                                   'result' => 'complete', 'total_seconds' => 10.0,
                                   'workspaces_version' => Workspaces::VERSION)
    expect(lines.first['steps']).to eq([{ 'id' => 'gems', 'state' => 'complete', 'seconds' => 12.5 },
                                        { 'id' => 'app', 'state' => 'complete', 'seconds' => 0.4 }])
    expect(lines.last).to include('result' => 'failed', 'workspace_id' => 'ws-2')
  end

  it 'never raises when the history cannot be written, so a build is never broken by its own bookkeeping' do
    Workspaces::Config.build_history_path.dirname.mkpath
    Workspaces::Config.build_history_path.mkdir

    expect { expect(record).to be(false) }.to output(/build history not recorded/).to_stderr
  end

  describe '.estimates' do
    it 'is the mean of each step across successful runs' do
      record(steps: [step('gems', 10), step('assets', 100)])
      record(steps: [step('gems', 20), step('assets', 200)])

      expect(described_class.estimates(%w(gems assets))).to eq('gems' => 15.0, 'assets' => 150.0)
    end

    it 'ignores failed runs and steps that did not complete, so a bad build cannot skew what usual means' do
      record(steps: [step('gems', 10)])
      record(result: 'failed', steps: [step('gems', 500)])
      record(steps: [step('gems', 900, 'failed')])

      expect(described_class.estimates(%w(gems))).to eq('gems' => 10.0)
    end

    it 'uses only the last ten completions, so old slow builds age out' do
      12.times { |i| record(steps: [step('gems', i < 2 ? 1000 : 10)]) }

      expect(described_class.estimates(%w(gems))).to eq('gems' => 10.0)
    end

    it 'covers only the steps asked for, and omits steps never seen' do
      record(steps: [step('gems', 10), step('other', 5)])

      expect(described_class.estimates(%w(gems new))).to eq('gems' => 10.0)
    end

    it 'handles a restart that ran only some steps' do
      record(steps: [step('gems', 10), step('app', 1)])
      record(operation: 'restart', steps: [step('app', 3)])

      expect(described_class.estimates(%w(gems app))).to eq('gems' => 10.0, 'app' => 2.0)
    end

    it 'skips unreadable lines and non-numeric or negative durations instead of failing' do
      record(steps: [step('gems', 10)])
      Workspaces::Config.build_history_path.open('a') { |file| file.puts('not json {', '[1,2]', '') }
      record(steps: [step('gems', 'abc'), step('app', -1)])

      expect(described_class.estimates(%w(gems app))).to eq('gems' => 10.0)
    end

    it 'is empty with no history' do
      expect(described_class.estimates(%w(gems))).to eq({})
    end

    it 'reads only the tail of a very long history' do
      path = Workspaces::Config.build_history_path
      path.dirname.mkpath
      filler = JSON.generate('result' => 'complete', 'steps' => [{ 'id' => 'gems', 'state' => 'complete', 'seconds' => 9999 }]) + "\n"
      path.write(filler * ((Workspaces::BuildHistory::READ_BYTES / filler.bytesize) * 3))
      record(steps: [step('gems', 10)])

      expect(described_class.estimates(%w(gems))['gems']).to be < 9999
    end
  end
end
