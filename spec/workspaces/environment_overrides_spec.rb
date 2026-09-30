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
end
