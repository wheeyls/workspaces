# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe Workspaces::StateStore do
  it 'reads missing state without creating the file' do
    store = described_class.new(Workspaces::Config.state_file)

    result = store.get(123)

    expect(result).to be_nil
    expect(Workspaces::Config.state_file).not_to exist
  end

  it 'merges updates while preserving existing fields' do
    store = described_class.new(Workspaces::Config.state_file)

    store.set(123, 'fingerprint' => 'abc', 'backend' => { 'pid' => 7 })
    store.set(123, 'status' => 'ready')

    expect(store.get(123)).to eq(
      'fingerprint' => 'abc',
      'backend' => { 'pid' => 7 },
      'status' => 'ready'
    )
  end

  it 'returns copies from get and all' do
    store = described_class.new(Workspaces::Config.state_file)
    store.set(123, 'status' => 'ready')

    snapshot = store.get(123)
    all = store.all
    snapshot['status'] = 'changed'
    all['123']['status'] = 'changed-again'

    expect(store.get(123)).to eq('status' => 'ready')
  end

  it 'does not rewrite state file when reading' do
    store = described_class.new(Workspaces::Config.state_file)
    store.set(123, 'status' => 'ready')
    path = Workspaces::Config.state_file
    before = File.mtime(path)

    sleep 1
    store.get(123)
    store.all

    expect(File.mtime(path)).to eq(before)
  end

  it 'treats non-hash json roots as empty state' do
    path = Workspaces::Config.state_file
    FileUtils.mkdir_p(path.dirname)
    File.write(path, "null\n")

    store = described_class.new(path)

    expect(store.get(123)).to be_nil
    expect(store.all).to eq({})
  end
end
