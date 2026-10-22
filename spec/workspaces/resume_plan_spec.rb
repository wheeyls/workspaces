require_relative 'spec_helper'

RSpec.describe Workspaces::ResumePlan do
  let(:recipe) do
    [{ 'id' => 'setup' }, { 'id' => 'assets' }, { 'id' => 'app', 'background' => true }, { 'id' => 'ready' }]
  end

  def steps(*states, keys: %w(setup assets app ready))
    keys.zip(states).map do |key, state|
      { 'key' => key, 'label' => key.capitalize, 'state' => state, 'duration_seconds' => 1.5, 'started_at' => 'then' }
    end
  end

  def build(persisted, **options)
    described_class.build(recipe_steps: recipe, persisted: persisted, **options)
  end

  describe 'retry' do
    it 'continues from the first step that did not finish, keeping what finished' do
      plan = build(steps('complete', 'failed', 'pending', 'pending'), mode: :retry)

      expect(plan.run_keys).to eq(%w(assets app ready))
      expect(plan.steps.first).to include('state' => 'complete', 'duration_seconds' => 1.5)
      expect(plan.steps[1]).to include('state' => 'pending', 'duration_seconds' => nil)
      expect(plan.steps[1]).not_to include('started_at')
      expect(plan).to have_attributes(touches_server: true, after_server: false)
    end

    it 'restarts from the server step when readiness failed, because a failed run stops the server' do
      plan = build(steps('complete', 'complete', 'complete', 'failed'), mode: :retry)

      expect(plan.run_keys).to eq(%w(app ready))
      expect(plan.touches_server).to be(true)
    end

    it 'treats an interrupted step like a failed one' do
      expect(build(steps('complete', 'active', 'pending', 'pending'), mode: :retry).run_keys).to eq(%w(assets app ready))
    end

    it 'refuses when every step already completed' do
      expect { build(steps('complete', 'complete', 'complete', 'complete'), mode: :retry) }
        .to raise_error(described_class::Refused, /nothing to retry/)
    end

    it 'works on the shorter step list a restart records' do
      plan = build(steps('complete', 'failed', keys: %w(app ready)), mode: :retry)

      expect(plan.run_keys).to eq(%w(app ready))
    end
  end

  describe 'from' do
    it 'allows re-running from any step once nothing before it is unfinished' do
      plan = build(steps('complete', 'complete', 'complete', 'complete'), mode: :from, key: 'assets')

      expect(plan.run_keys).to eq(%w(assets app ready))
    end

    it 'refuses to skip an unfinished step' do
      expect { build(steps('complete', 'failed', 'pending', 'pending'), mode: :from, key: 'app') }
        .to raise_error(described_class::Refused, /"Assets" has not finished/)
    end

    it 'needs a live server to re-run only steps after it' do
      persisted = steps('complete', 'complete', 'complete', 'complete')

      expect { build(persisted, mode: :from, key: 'ready') }.to raise_error(described_class::Refused, /not running/)
      expect(build(persisted, mode: :from, key: 'ready', server_live: true))
        .to have_attributes(run_keys: %w(ready), touches_server: false, after_server: true)
    end
  end

  describe 'only' do
    it 're-runs exactly one step before the server and leaves the server alone' do
      plan = build(steps('complete', 'complete', 'complete', 'complete'), mode: :only, key: 'setup', server_live: true)

      expect(plan).to have_attributes(run_keys: %w(setup), touches_server: false, after_server: false)
    end

    it 'refuses the server step on its own, since restarting it means re-running what follows' do
      expect { build(steps('complete', 'complete', 'complete', 'complete'), mode: :only, key: 'app') }
        .to raise_error(described_class::Refused, /re-run from that step/)
    end

    it 'refuses while another step is unfinished, so a success always means a finished workspace' do
      expect { build(steps('complete', 'complete', 'failed', 'pending'), mode: :only, key: 'setup') }
        .to raise_error(described_class::Refused, /"App" has not finished/)
    end
  end

  describe 'refusals' do
    it 'refuses an unknown step without echoing an unbounded name' do
      expect { build(steps('complete', 'complete', 'complete', 'complete'), mode: :from, key: 'x' * 500) }
        .to raise_error(described_class::Refused) { |error| expect(error.message.length).to be < 120 }
    end

    it 'refuses when the recorded steps no longer match the recipe' do
      persisted = steps('complete', 'failed', 'pending', keys: %w(setup other app))

      expect { build(persisted, mode: :retry) }.to raise_error(described_class::Refused, /no longer match/)
    end

    it 'refuses when nothing was recorded' do
      expect { build([], mode: :retry) }.to raise_error(described_class::Refused, /no longer match/)
    end

    it 'rejects an unknown mode' do
      expect { build(steps('complete', 'complete', 'complete', 'complete'), mode: :bogus) }
        .to raise_error(ArgumentError, /Unknown re-run mode/)
    end
  end

  describe 'describe' do
    it 'names the step a retry would begin at and lists the modes each step accepts' do
      info = described_class.describe(recipe_steps: recipe, persisted: steps('complete', 'complete', 'complete', 'failed'),
                                      server_live: false)

      expect(info).to include('retry_from' => 'app', 'retry_label' => 'App', 'server_key' => 'app')
      # Earlier steps can be re-run from, but never alone (readiness is unfinished), and readiness
      # itself needs a server that is not running.
      expect(info['step_modes']).to eq('setup' => %w(from), 'assets' => %w(from), 'app' => %w(from), 'ready' => [])
    end

    it 'offers single-step and from-here re-runs for a finished workspace with a live server' do
      info = described_class.describe(recipe_steps: recipe, persisted: steps('complete', 'complete', 'complete', 'complete'),
                                      server_live: true)

      expect(info['retry_from']).to be_nil
      expect(info['step_modes']).to include('setup' => %w(only from), 'app' => %w(from), 'ready' => %w(only from))
    end

    it 'is nil when the recorded steps cannot be trusted' do
      expect(described_class.describe(recipe_steps: recipe, persisted: [])).to be_nil
    end
  end
end
