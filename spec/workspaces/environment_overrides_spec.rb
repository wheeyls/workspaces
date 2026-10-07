# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe Workspaces::EnvironmentOverrides do
  before { repository }

  let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }
  let(:store) { described_class.new(workspace.id) }

  it 'persists overrides outside the worktree with secure permissions and sorted keys' do
    store.apply_patch(set: { 'APP_CHANNEL' => 'foo', 'APP_VARIANT' => 'api' }, remove: [])

    path = Workspaces::Config.home.join('environment', "#{workspace.id}.json")
    expect(path).to exist
    expect(path.dirname).to exist
    expect(path.stat.mode & 0o777).to eq(0o600)
    expect(path.dirname.stat.mode & 0o777).to eq(0o700)
    expect(path.to_s).not_to start_with(workspace.path.to_s)
    expect(store.load).to eq('APP_CHANNEL' => 'foo', 'APP_VARIANT' => 'api')
    expect(store.keys).to eq(%w(APP_CHANNEL APP_VARIANT))
  end

  it 'patches saved values without touching unrelated keys and removing restores defaults' do
    store.apply_patch(set: { 'APP_VARIANT' => 'api', 'CUSTOM_ONE' => 'first' }, remove: [])
    store.apply_patch(set: { 'CUSTOM_ONE' => 'second' }, remove: ['APP_VARIANT'])

    expect(store.load).to eq('CUSTOM_ONE' => 'second')
  end

  it 'rejects invalid names, reserved names, conflicts, oversize values, nul bytes, and too many entries' do
    expect { store.apply_patch(set: { '1BAD' => 'x' }, remove: []) }
      .to raise_error(described_class::Invalid, /Environment names/)
    expect { store.apply_patch(set: { 'WORKSPACE_PORT' => '1234' }, remove: []) }
      .to raise_error(described_class::Invalid, /reserved/)
    expect { store.apply_patch(set: { 'PORT' => '1234' }, remove: []) }
      .to raise_error(described_class::Invalid, /reserved/)
    expect { store.apply_patch(set: { 'APP_VARIANT' => 'api' }, remove: ['APP_VARIANT']) }
      .to raise_error(described_class::Invalid, /same name/)
    expect { store.apply_patch(set: { 'APP_VARIANT' => "a\0b" }, remove: []) }
      .to raise_error(described_class::Invalid, /NUL/)
    expect { store.apply_patch(set: { 'APP_VARIANT' => 'a' * 8193 }, remove: []) }
      .to raise_error(described_class::Invalid, /8192 bytes or smaller/)

    too_many = 101.times.to_h { |index| ["KEY_#{index}", 'x'] }
    expect { store.apply_patch(set: too_many, remove: []) }
      .to raise_error(described_class::Invalid, /limited to 100 entries/)
  end

  it 'rejects symlinked storage paths' do
    environment_dir = Workspaces::Config.home.join('environment')
    environment_dir.dirname.mkpath
    target = Workspaces::Config.home.join('real-environment')
    target.mkpath
    File.symlink(target, environment_dir)

    expect { store.apply_patch(set: { 'APP_VARIANT' => 'api' }, remove: []) }
      .to raise_error(described_class::Invalid, /symlinks/)
  end

  it 'rejects a symlinked override file even when its target is missing' do
    directory = Workspaces::Config.home.join('environment')
    directory.mkpath
    File.symlink(directory.join('nonexistent-target'), directory.join("#{workspace.id}.json"))

    expect { store.load }.to raise_error(described_class::Invalid, /symlinks/)
    expect { store.apply_patch(set: { 'APP_VARIANT' => 'admin' }, remove: []) }
      .to raise_error(described_class::Invalid, /symlinks/)
  end

  it 'scrubs persisted secret values from logs and errors' do
    store.apply_patch(set: { 'APP_VARIANT' => 'top-secret-token' }, remove: [])

    expect(store.scrub('token=top-secret-token')).not_to include('top-secret-token')
    expect(store.scrub('token=top-secret-token')).to include('[FILTERED]')
  end

  it 'keeps workspaces isolated from each other' do
    other = described_class.new(Workspaces::Registry.new.create(branch: 'main').id)
    store.apply_patch(set: { 'APP_VARIANT' => 'first' }, remove: [])
    other.apply_patch(set: { 'APP_VARIANT' => 'second' }, remove: [])

    expect(store.load).to eq('APP_VARIANT' => 'first')
    expect(other.load).to eq('APP_VARIANT' => 'second')
  end

  it 'replaces editable text, restores omitted defaults, and preserves legacy hidden overrides' do
    defaults = { 'APP_VARIANT' => 'www', 'APP_CHANNEL' => 'www' }
    store.apply_patch(set: { 'SECRET_TOKEN' => 'hidden', 'APP_VARIANT' => 'legacy' }, remove: [])
    expect(store.editable_values(defaults)).to eq('APP_VARIANT' => 'legacy', 'APP_CHANNEL' => 'www')
    store.replace_editable("APP_VARIANT=admin=preview\nAPP_CHANNEL=admin\n", defaults: defaults)
    expect(store.editable_values(defaults)).to eq('APP_VARIANT' => 'admin=preview', 'APP_CHANNEL' => 'admin')
    expect(store.load).to include('SECRET_TOKEN' => 'hidden')
    store.replace_editable("APP_VARIANT=www\n", defaults: defaults)
    expect(store.editable_values(defaults)).to eq(defaults)
    expect(store.load).to include('SECRET_TOKEN' => 'hidden')
  end

  it 'rejects duplicate and unlisted names without replacing saved values' do
    defaults = { 'APP_VARIANT' => 'www' }
    store.replace_editable('APP_VARIANT=admin', defaults: defaults)
    ['APP_VARIANT=one\nAPP_VARIANT=two', 'WORKSPACE_PORT=1234', 'SECRET_TOKEN=bad', 'BROKEN'].each do |text|
      expect { store.replace_editable(text.gsub('\\n', "\n"), defaults: defaults) }
        .to raise_error(described_class::Invalid)
    end
    expect(store.editable_values(defaults)).to eq('APP_VARIANT' => 'admin')
  end

  it 'permits additional non-reserved names and removes them when omitted' do
    defaults = { 'APP_VARIANT' => 'www' }
    store.replace_editable("APP_VARIANT=www\nNEW_FLAG=enabled", defaults: defaults)
    expect(store.editable_values(defaults)).to include('NEW_FLAG' => 'enabled')
    store.replace_editable('APP_VARIANT=www', defaults: defaults)
    expect(store.editable_values(defaults)).to eq(defaults)
  end

  it 'keeps a previously saved non-editor override hidden when a new editor name is removed' do
    defaults = { 'APP_VARIANT' => 'www' }
    store.apply_patch(set: { 'SECRET_TOKEN' => 'hidden' }, remove: [])
    store.replace_editable('APP_VARIANT=www', defaults: defaults)
    expect(store.editable_values(defaults)).not_to have_key('SECRET_TOKEN')
    expect(store.load).to include('SECRET_TOKEN' => 'hidden')
  end

  it 'shows an editable override over an older value for the same default name' do
    defaults = { 'APP_VARIANT' => 'www' }
    store.apply_patch(set: { 'APP_VARIANT' => 'legacy' }, remove: [])
    path = Workspaces::Config.home.join('environment', "#{workspace.id}.editable.json")
    path.write(JSON.generate('APP_VARIANT' => 'preview'))

    expect(store.editable_values(defaults)).to eq('APP_VARIANT' => 'preview')
    expect(store.load).to eq('APP_VARIANT' => 'preview')
  end

  it 'applies a named preset as a replacement while preserving hidden legacy values' do
    root = Workspaces::Config.repo_root
    config = YAML.safe_load(root.join('.workspaces.yml').read)
    config['default_editable_env'] = { 'APP_VARIANT' => 'www', 'APP_CHANNEL' => 'www' }
    config['environment_presets'] = { 'Admin' => { 'APP_VARIANT' => 'admin' }, 'Vendor' => { 'APP_VARIANT' => 'my' } }
    root.join('.workspaces.yml').write(YAML.dump(config))
    store.apply_patch(set: { 'SECRET_TOKEN' => 'hidden' }, remove: [])
    store.replace_editable("APP_VARIANT=custom\nEXTRA=old", defaults: config['default_editable_env'])

    store.apply_preset('Admin')
    expect(store.editable_values(config['default_editable_env'])).to eq('APP_VARIANT' => 'admin', 'APP_CHANNEL' => 'www')
    expect(store.load).to include('SECRET_TOKEN' => 'hidden')
    store.apply_preset('Vendor')
    expect(store.editable_values(config['default_editable_env'])).to eq('APP_VARIANT' => 'my', 'APP_CHANNEL' => 'www')
    expect(store.load).not_to have_key('EXTRA')
    expect { store.apply_preset('Missing') }.to raise_error(described_class::Invalid, /Unknown environment preset/)
    expect(store.editable_values(config['default_editable_env'])['APP_VARIANT']).to eq('my')
  end

  it 'patches visible settings and composes them after a preset without leaking hidden values' do
    root = Workspaces::Config.repo_root
    config = YAML.safe_load(root.join('.workspaces.yml').read)
    config['default_editable_env'] = { 'APP_VARIANT' => 'www', 'APP_CHANNEL' => 'www' }
    config['environment_presets'] = { 'Admin' => { 'APP_VARIANT' => 'admin' } }
    root.join('.workspaces.yml').write(YAML.dump(config))
    store.apply_patch(set: { 'SECRET_TOKEN' => 'hidden' }, remove: [])
    store.apply_settings(set: { 'EXTRA' => 'one' })
    store.apply_settings(set: { 'APP_CHANNEL' => 'my=portal' })
    expect(store.editable_values(config['default_editable_env']))
      .to eq('APP_VARIANT' => 'www', 'APP_CHANNEL' => 'my=portal', 'EXTRA' => 'one')
    store.apply_settings(preset: 'Admin', set: { 'APP_CHANNEL' => 'preview' }, unset: ['APP_VARIANT'])
    expect(store.editable_values(config['default_editable_env']))
      .to eq('APP_VARIANT' => 'www', 'APP_CHANNEL' => 'preview')
    expect(store.load).to include('SECRET_TOKEN' => 'hidden')
    expect(store.load).not_to have_key('EXTRA')
  end

  it 'rejects conflicting and secret-like CLI settings without changing storage' do
    store.apply_settings(set: { 'APP_VARIANT' => 'admin' })
    original = store.load
    [{ set: { 'APP_VARIANT' => 'my' }, unset: ['APP_VARIANT'] },
     { set: { 'SECRET_TOKEN' => 'bad' }, unset: [] },
     { set: {}, unset: ['PASSWORD'] },
     { set: { 'WORKSPACE_PORT' => '1' }, unset: [] }].each do |options|
      expect { store.apply_settings(**options) }.to raise_error(described_class::Invalid)
      expect(store.load).to eq(original)
    end
  end
end
