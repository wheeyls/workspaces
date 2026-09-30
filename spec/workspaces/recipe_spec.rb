require_relative 'spec_helper'

RSpec.describe Workspaces::Recipe do
  before { repository }

  def configure(steps, extra = {})
    Workspaces::Config.repo_root.join('.workspaces.yml').write(YAML.dump({ 'version' => 1,
                                                                           'steps' => steps }.merge(extra)))
  end

  let(:steps) do
    [{ 'id' => 'setup', 'name' => 'Install', 'run' => 'echo setup' },
     { 'id' => 'app', 'name' => 'Start', 'run' => ['ruby', 'server.rb'], 'background' => true },
     { 'id' => 'ready', 'name' => 'Ready?', 'run' => ['ruby', 'ready.rb'], 'timeout' => 10 }]
  end

  it 'loads ordered run steps and restarts from the background command onward' do
    configure(steps)
    recipe = described_class.new
    expect(recipe.steps).to match([include('id' => 'setup'), include('id' => 'app'), include('id' => 'ready')])
    expect(recipe.for_operation(restart: true)).to match([include('id' => 'app'), include('id' => 'ready')])
    expect(recipe.command(recipe.steps.first, {})).to eq(['sh', '-c', 'echo setup'])
  end

  it 'expands explicit context without using a shell for argument arrays' do
    steps.first['run'] = ['echo', '${WORKSPACE_PATH}']
    configure(steps, 'env' => { 'APP_URL' => '${WORKSPACE_URL}', 'REMOVE_ME' => nil })
    recipe = described_class.new
    context = { 'WORKSPACE_PATH' => '/tmp/a;literal', 'WORKSPACE_URL' => 'https://ws-example.test' }
    expect(recipe.command(recipe.steps.first, context)).to eq(['echo', '/tmp/a;literal'])
    expect(recipe.env(recipe.steps.first,
                      context)).to include('APP_URL' => 'https://ws-example.test', 'REMOVE_ME' => nil)
  end

  it 'applies runtime environment overrides after recipe env while preserving runner context' do
    configure(steps, 'env' => { 'APP_VARIANT' => 'global-default', 'APP_CHANNEL' => 'routing-default' })
    recipe = described_class.new
    context = { 'WORKSPACE_PORT' => '30123', 'WORKSPACE_URL' => 'https://ws-example.test' }

    result = recipe.env(recipe.steps.first, context,
                        overrides: { 'APP_VARIANT' => 'override', 'APP_CHANNEL' => 'preview',
                                     'CUSTOM_APP' => 'value' })

    expect(result).to include('APP_VARIANT' => 'override', 'APP_CHANNEL' => 'preview', 'CUSTOM_APP' => 'value')
    expect(result['WORKSPACE_PORT']).to eq('30123')
  end

  it 'loads editable defaults and permits workspace overrides' do
    configure(steps, 'default_editable_env' => { 'APP_VARIANT' => 'www' })
    recipe = described_class.new

    expect(recipe.default_editable_env).to eq('APP_VARIANT' => 'www')
    expect(recipe.env(recipe.steps.first, {})).to include('APP_VARIANT' => 'www')
    expect(recipe.env(recipe.steps.first, {}, overrides: { 'APP_VARIANT' => 'admin' })).to include('APP_VARIANT' => 'admin')
  end

  it 'rejects duplicate recipe definitions for editable names' do
    configure(steps, 'default_editable_env' => { 'APP_VARIANT' => 'www' }, 'env' => { 'APP_VARIANT' => 'admin' })
    expect { described_class.new }.to raise_error(described_class::Invalid, /cannot also appear/)
  end

  it 'rejects malformed editable defaults' do
    [[], { 'WORKSPACE_PORT' => '1' }, { 'APP_VARIANT' => nil }, { '1BAD' => 'x' },
     { 'SECRET_TOKEN' => 'bad' },
     { 'APP_VARIANT' => "multiple\nlines" }].each do |invalid|
      configure(steps, 'default_editable_env' => invalid)
      expect { described_class.new }.to raise_error(described_class::Invalid)
    end
  end

  it 'rejects malformed commands, duplicate IDs, unknown settings and overwritten context' do
    [steps + [steps.first], steps.take(2), steps.map { |step| step.except('run') }].each do |invalid|
      configure(invalid)
      expect { described_class.new }.to raise_error(described_class::Invalid)
    end
    configure(steps, 'env' => { 'WORKSPACE_PORT' => '1234' })
    expect { described_class.new }.to raise_error(described_class::Invalid, /supplied/)
    configure(steps, 'server' => {})
    expect { described_class.new }.to raise_error(described_class::Invalid, /Unknown/)
  end

  it 'reads the trusted source configuration rather than files in a selected worktree' do
    configure(steps)
    workspace = Workspaces::Registry.new.create(branch: 'main')
    workspace.path.join('.workspaces.yml').write('invalid: selected branch')
    expect(described_class.new.steps.first['id']).to eq('setup')
  end

  it 'rejects YAML object construction and missing configuration' do
    Workspaces::Config.repo_root.join('.workspaces.yml').write('--- !ruby/object:Object {}')
    expect { described_class.new }.to raise_error(described_class::Invalid)
    File.unlink(Workspaces::Config.repo_root.join('.workspaces.yml'))
    expect { described_class.new }.to raise_error(described_class::Invalid, /Add .workspaces.yml/)
  end

  it 'fails before executing a command with an undefined environment placeholder' do
    configure(steps)
    ClimateControl.modify('ABSENT_WORKSPACE_FIXTURE_VARIABLE' => nil) do
      expect { described_class.new.command({ 'run' => ['echo', '${ABSENT_WORKSPACE_FIXTURE_VARIABLE}'] }, {}) }
        .to raise_error(described_class::Invalid, /Missing environment/)
    end
  end
end
