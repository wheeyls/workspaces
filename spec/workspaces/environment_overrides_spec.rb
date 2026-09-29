# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe Workspaces::EnvironmentOverrides do
  before { repository }

  let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }
  let(:store) { described_class.new(workspace.id) }

  it 'persists overrides outside the worktree with secure permissions and sorted keys' do
    store.apply_patch(set: { 'ROUTING_SUBDOMAIN' => 'foo', 'UE_APP' => 'api' }, remove: [])

    path = Workspaces::Config.home.join('environment', "#{workspace.id}.json")
    expect(path).to exist
    expect(path.dirname).to exist
    expect(path.stat.mode & 0o777).to eq(0o600)
    expect(path.dirname.stat.mode & 0o777).to eq(0o700)
    expect(path.to_s).not_to start_with(workspace.path.to_s)
    expect(store.load).to eq('ROUTING_SUBDOMAIN' => 'foo', 'UE_APP' => 'api')
    expect(store.keys).to eq(%w(ROUTING_SUBDOMAIN UE_APP))
  end

  it 'patches saved values without touching unrelated keys and removing restores defaults' do
    store.apply_patch(set: { 'UE_APP' => 'api', 'CUSTOM_ONE' => 'first' }, remove: [])
    store.apply_patch(set: { 'CUSTOM_ONE' => 'second' }, remove: ['UE_APP'])

    expect(store.load).to eq('CUSTOM_ONE' => 'second')
  end

  it 'rejects invalid names, reserved names, conflicts, oversize values, nul bytes, and too many entries' do
    expect { store.apply_patch(set: { '1BAD' => 'x' }, remove: []) }
      .to raise_error(described_class::Invalid, /Environment names/)
    expect { store.apply_patch(set: { 'WORKSPACE_PORT' => '1234' }, remove: []) }
      .to raise_error(described_class::Invalid, /reserved/)
    expect { store.apply_patch(set: { 'PORT' => '1234' }, remove: []) }
      .to raise_error(described_class::Invalid, /reserved/)
    expect { store.apply_patch(set: { 'UE_APP' => 'api' }, remove: ['UE_APP']) }
      .to raise_error(described_class::Invalid, /same name/)
    expect { store.apply_patch(set: { 'UE_APP' => "a\0b" }, remove: []) }
      .to raise_error(described_class::Invalid, /NUL/)
    expect { store.apply_patch(set: { 'UE_APP' => 'a' * 8193 }, remove: []) }
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

    expect { store.apply_patch(set: { 'UE_APP' => 'api' }, remove: []) }
      .to raise_error(described_class::Invalid, /symlinks/)
  end

  it 'rejects a symlinked override file even when its target is missing' do
    directory = Workspaces::Config.home.join('environment')
    directory.mkpath
    File.symlink(directory.join('nonexistent-target'), directory.join("#{workspace.id}.json"))

    expect { store.load }.to raise_error(described_class::Invalid, /symlinks/)
    expect { store.apply_patch(set: { 'UE_APP' => 'admin' }, remove: []) }
      .to raise_error(described_class::Invalid, /symlinks/)
  end

  it 'scrubs persisted secret values from logs and errors' do
    store.apply_patch(set: { 'UE_APP' => 'top-secret-token' }, remove: [])

    expect(store.scrub('token=top-secret-token')).not_to include('top-secret-token')
    expect(store.scrub('token=top-secret-token')).to include('[FILTERED]')
  end

  it 'keeps workspaces isolated from each other' do
    other = described_class.new(Workspaces::Registry.new.create(branch: 'main').id)
    store.apply_patch(set: { 'UE_APP' => 'first' }, remove: [])
    other.apply_patch(set: { 'UE_APP' => 'second' }, remove: [])

    expect(store.load).to eq('UE_APP' => 'first')
    expect(other.load).to eq('UE_APP' => 'second')
  end
end
