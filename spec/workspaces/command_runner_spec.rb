require_relative 'spec_helper'

RSpec.describe Workspaces::CommandRunner do
  let(:log) { StringIO.new }
  let(:runner) { described_class.new(Workspaces::Config.home.tap(&:mkpath), log) }

  it 'streams output and reports nonzero exit status' do
    expect { runner.run!(['ruby', '-e', 'puts "failure detail"; exit 4'], env: {}, timeout: 5) }
      .to raise_error(described_class::Failed, /status 4/)
    expect(log.string).to include('failure detail')
  end

  it 'bounds the whole process lifetime even after stdout is closed' do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { runner.run!(['ruby', '-e', 'STDOUT.close; STDERR.close; sleep 30'], env: {}, timeout: 1) }
      .to raise_error(described_class::Failed, /timeout/)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be < 5
  end

  it 'streams scrubbed output through the tee log' do
    workspace_id = 'fixture-1234'
    file = StringIO.new
    log = Workspaces::TeeLog.new(workspace_id, file)
    Workspaces::EnvironmentOverrides.new(workspace_id).apply_patch(set: { 'UE_APP' => 'top-secret-token' }, remove: [])

    described_class.new(Workspaces::Config.home.tap(&:mkpath), log)
      .run!(['ruby', '-e', 'puts "token=top-secret-token"'], env: {}, timeout: 5)

    expect(file.string).to include('[FILTERED]')
    expect(file.string).not_to include('top-secret-token')
  end
end
