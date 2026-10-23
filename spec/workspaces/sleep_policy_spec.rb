require_relative 'spec_helper'

RSpec.describe Workspaces::SleepPolicy do
  before { repository }

  def configure(sleep_config)
    path = Workspaces::Config.repo_root.join('.workspaces.yml')
    recipe = YAML.safe_load(path.read)
    recipe['sleep'] = sleep_config unless sleep_config.nil?
    path.write(YAML.dump(recipe))
  end

  it 'always ignores health probes' do
    policy = described_class.new

    expect(policy.ignored?('/health')).to be(true)
    expect(policy.ignored?('/up')).to be(true)
    expect(policy.ignored?('/products')).to be(false)
  end

  it 'ignores the paths a recipe lists, as globs' do
    configure('ignore_paths' => ['/cable', '/api/poll/*'])
    policy = described_class.new

    expect(policy.ignored?('/cable')).to be(true)
    expect(policy.ignored?('/api/poll/status')).to be(true)
    expect(policy.ignored?('/api/other')).to be(false)
  end

  it 'picks up recipe changes without a restart' do
    configure(nil)
    policy = described_class.new
    expect(policy.ignored?('/cable')).to be(false)

    configure('ignore_paths' => ['/cable'])
    FileUtils.touch(Workspaces::Config.repo_root.join('.workspaces.yml'), mtime: Time.now + 5)

    expect(policy.ignored?('/cable')).to be(true)
  end

  it 'falls back to the built-in paths when the recipe is unreadable' do
    Workspaces::Config.repo_root.join('.workspaces.yml').write('not: [valid')

    expect(described_class.new.ignored?('/health')).to be(true)
  end
end

RSpec.describe Workspaces::Recipe, 'sleep settings' do
  before { repository }

  def configure(extra)
    path = Workspaces::Config.repo_root.join('.workspaces.yml')
    path.write(YAML.dump(YAML.safe_load(path.read).merge(extra)))
  end

  it 'defaults to no ignored paths' do
    expect(described_class.new.sleep_ignore_paths).to eq([])
  end

  it 'rejects malformed sleep settings' do
    configure('sleep' => { 'ignore_paths' => ['cable'] })
    expect { described_class.new }.to raise_error(described_class::Invalid, /starting with \//)

    configure('sleep' => { 'ignore_paths' => 'nope' })
    expect { described_class.new }.to raise_error(described_class::Invalid, /array/)

    configure('sleep' => { 'timeout' => 5 })
    expect { described_class.new }.to raise_error(described_class::Invalid, /Unknown configuration keys/)
  end

  it 'changes the preparation digest only when a step before the server changes' do
    path = Workspaces::Config.repo_root.join('.workspaces.yml')
    original = described_class.new.preparation_digest

    document = YAML.safe_load(path.read)
    document['steps'][2]['run'] = ['ruby', '-e', 'puts "other readiness"']
    path.write(YAML.dump(document))
    expect(described_class.new.preparation_digest).to eq(original)

    document['steps'][0]['run'] = ['ruby', '-e', 'puts "other setup"']
    path.write(YAML.dump(document))
    expect(described_class.new.preparation_digest).not_to eq(original)
  end
end

RSpec.describe Workspaces::Config, 'sleep settings' do
  it 'defaults to 30 minutes and accepts 15' do
    expect(described_class.sleep_after_seconds).to eq(1800)
    ClimateControl.modify('WORKSPACES_SLEEP_AFTER_MINUTES' => '15') do
      expect(described_class.sleep_after_seconds).to eq(900)
    end
  end

  it 'switches sleeping off with 0 and rejects nonsense' do
    ClimateControl.modify('WORKSPACES_SLEEP_AFTER_MINUTES' => '0') do
      expect(described_class.sleep_after_seconds).to be_nil
    end
    %w(-1 abc NaN).each do |value|
      ClimateControl.modify('WORKSPACES_SLEEP_AFTER_MINUTES' => value) do
        expect { described_class.sleep_after_seconds }.to raise_error(ArgumentError, /WORKSPACES_SLEEP_AFTER_MINUTES/)
      end
    end
  end

  it 'has a bounded wake timeout' do
    expect(described_class.wake_timeout_seconds).to eq(90)
    ClimateControl.modify('WORKSPACES_WAKE_TIMEOUT_SECONDS' => '0') do
      expect { described_class.wake_timeout_seconds }.to raise_error(ArgumentError)
    end
  end
end
