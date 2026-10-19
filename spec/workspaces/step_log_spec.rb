require_relative 'spec_helper'

RSpec.describe Workspaces::StepLog do
  let(:id) { 'step-log-fixture' }
  let(:combined) { StringIO.new }
  let(:log) { described_class.new(combined, id) }

  def step_file(step)
    Workspaces::Config.step_log_path(id, step).read
  end

  it 'writes each step\'s output to its own file and everything to the combined log' do
    log.begin_step('gems')
    log.puts '==> Install gems'
    log.print "Bundle complete\n"
    log.begin_step('assets')
    log.puts '==> Build assets'
    log.print "compiled\n"
    log.finish_step

    expect(step_file('gems')).to eq("==> Install gems\nBundle complete\n")
    expect(step_file('assets')).to eq("==> Build assets\ncompiled\n")
    expect(combined.string).to eq("==> Install gems\nBundle complete\n==> Build assets\ncompiled\n")
  end

  it 'writes only to the combined log when no step is current' do
    log.puts '==> preparing workspace'

    expect(combined.string).to eq("==> preparing workspace\n")
    expect(Workspaces::Config.step_logs_dir(id, create: false).glob('*.log')).to be_empty
  end

  it 'truncates a step\'s file when the same step begins again' do
    log.begin_step('gems')
    log.puts 'first run'
    log.begin_step('gems')
    log.puts 'second run'
    log.finish_step

    expect(step_file('gems')).to eq("second run\n")
  end

  it 'copies exactly what the wrapped log wrote, so secrets are filtered in step files too' do
    tee = Workspaces::TeeLog.new(id, StringIO.new)
    Workspaces::EnvironmentOverrides.new(id).apply_patch(set: { 'API_VALUE' => 'hunter2-private' }, remove: [])
    wrapped = described_class.new(tee, id)
    allow($stdout).to receive(:puts)

    wrapped.begin_step('gems')
    wrapped.puts 'using hunter2-private here'
    wrapped.finish_step

    expect(step_file('gems')).to eq("using [FILTERED] here\n")
  end

  it 'removes every step file on reset, leaving other logs alone' do
    log.begin_step('gems')
    log.puts 'x'
    log.finish_step
    other = Workspaces::Config.setup_log_path(id)
    other.write('keep')

    described_class.reset(id)

    expect(Workspaces::Config.step_log_path(id, 'gems', create: false)).not_to exist
    expect(other.read).to eq('keep')
  end

  it 'refuses step ids that could escape the log directory' do
    expect { log.begin_step('../evil') }.to raise_error(ArgumentError, /Unsafe step id/)
    expect { log.begin_step('Has Caps') }.to raise_error(ArgumentError, /Unsafe step id/)
  end

  it 'is safe to finish when no step is open' do
    expect { log.finish_step }.not_to raise_error
  end
end
