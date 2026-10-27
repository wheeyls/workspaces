require_relative 'spec_helper'

RSpec.describe Workspaces::Vault do
  let(:key) { ['k' * 32].pack('m0') }
  let(:other_key) { ['z' * 32].pack('m0') }

  def file_vault(env = { 'WORKSPACES_MASTER_KEY' => key })
    Workspaces::Vault::FileVault.new(home: Workspaces::Config.home, env: env)
  end

  describe '.provider' do
    it 'defaults to the file vault and picks another by name' do
      expect(described_class.provider(nil)).to be_a(Workspaces::Vault::FileVault)
      expect(described_class.provider('file').name).to eq('file')
    end

    it 'lets another provider register behind the same interface' do
      memory = Class.new(Workspaces::Vault::Provider) do
        STORE = {}
        def name = 'memory'
        def read(scope) = STORE.fetch(scope, {})
        def write(scope, entries) = entries.empty? ? STORE.delete(scope) : STORE[scope] = entries
        def purge(scope) = STORE.delete(scope)
      end
      described_class.register('memory', memory)
      provider = described_class.provider('memory')
      provider.write('ws-1', 'A' => '1')

      expect(provider.read('ws-1')).to eq('A' => '1')
      expect(provider.status).to eq('provider' => 'memory', 'available' => true, 'problem' => nil)
    end

    it 'reports an unknown provider as unavailable instead of raising' do
      provider = described_class.provider('nope')

      expect(provider.status).to include('available' => false, 'problem' => /Unknown secret vault provider "nope"/)
      expect(provider.read('ws-1')).to eq({})
      expect { provider.write('ws-1', 'A' => '1') }.to raise_error(Workspaces::Vault::Unavailable)
    end

    it 'does not echo an unbounded provider name' do
      expect(described_class.provider('x' * 500).problem.length).to be < 120
    end
  end

  describe Workspaces::Vault::FileVault do
    it 'round-trips values and writes only ciphertext, readable by its owner alone' do
      file_vault.write('ws-1', 'STRIPE_KEY' => 'sk_live_abc123', 'OTHER' => 'two')
      path = Workspaces::Config.home.join('vault', 'ws-1.enc')

      expect(file_vault.read('ws-1')).to eq('STRIPE_KEY' => 'sk_live_abc123', 'OTHER' => 'two')
      expect(path.read).not_to include('sk_live_abc123', 'STRIPE_KEY', 'two')
      expect(path.stat.mode & 0o777).to eq(0o600)
      expect(path.dirname.stat.mode & 0o777).to eq(0o700)
    end

    it 'uses a fresh nonce for every write' do
      file_vault.write('ws-1', 'A' => '1')
      first = Workspaces::Config.home.join('vault', 'ws-1.enc').read
      file_vault.write('ws-1', 'A' => '1')

      expect(Workspaces::Config.home.join('vault', 'ws-1.enc').read).not_to eq(first)
    end

    it 'returns nothing for a workspace without secrets, even with no key at all' do
      expect(file_vault({}).read('ws-1')).to eq({})
    end

    it 'removes the file when the set becomes empty, and on purge' do
      file_vault.write('ws-1', 'A' => '1')
      file_vault.write('ws-1', {})
      expect(Workspaces::Config.home.join('vault', 'ws-1.enc')).not_to exist

      file_vault.write('ws-1', 'A' => '1')
      file_vault.purge('ws-1')
      expect(Workspaces::Config.home.join('vault', 'ws-1.enc')).not_to exist
      expect { file_vault.purge('ws-1') }.not_to raise_error
    end

    describe 'without a usable master key' do
      it 'says what to do when the key is missing' do
        vault = file_vault({})

        expect(vault.available?).to be(false)
        expect(vault.problem).to include('WORKSPACES_MASTER_KEY', 'openssl rand -base64 32')
        expect { vault.write('ws-1', 'A' => '1') }.to raise_error(Workspaces::Vault::Unavailable, /WORKSPACES_MASTER_KEY/)
      end

      it 'rejects a key that is not 32 bytes of base64, without repeating it' do
        ['short', ['k' * 16].pack('m0'), '!!!not-base64!!!'].each do |bad|
          vault = file_vault('WORKSPACES_MASTER_KEY' => bad)

          expect(vault.available?).to be(false)
          expect(vault.problem).to include('32 random bytes')
          expect(vault.problem).not_to include(bad)
        end
      end
    end

    describe '#scopes' do
      it 'lists the workspace ids that have a secrets file, by name alone and without the key' do
        file_vault.write('ws-1', 'A' => '1')
        file_vault.write('ws-2', 'A' => '1')

        expect(file_vault({}).scopes).to eq(%w(ws-1 ws-2))
      end

      it 'lists nothing for a missing directory' do
        expect(file_vault.scopes).to eq([])
      end

      it 'skips anything that is not a workspace secrets file' do
        file_vault.write('ws-1', 'A' => '1')
        dir = Workspaces::Config.home.join('vault')
        File.write(dir.join('notes.txt'), 'x')
        File.write(dir.join('Bad_Name.enc'), 'x')
        File.write(dir.join('..sneaky.enc'), 'x')
        File.write(dir.join("#{'a' * 49}.enc"), 'x')
        File.write(dir.join('.ws-9.enc.123.tmp'), 'x')
        FileUtils.mkdir_p(dir.join('dir-1.enc'))
        File.symlink(dir.join('ws-1.enc'), dir.join('link-1.enc'))

        expect(file_vault.scopes).to eq(%w(ws-1))
      end

      it 'does not follow a symlinked directory' do
        file_vault.write('ws-1', 'A' => '1')
        dir = Workspaces::Config.home.join('vault')
        moved = Workspaces::Config.home.join('vault-real')
        File.rename(dir, moved)
        File.symlink(moved, dir)

        expect(file_vault.scopes).to eq([])
      end
    end

    describe 'what it refuses to do' do
      before { file_vault.write('ws-1', 'A' => 'sensitive') }

      it 'does not decrypt with the wrong key, and says so without exposing anything' do
        wrong = file_vault('WORKSPACES_MASTER_KEY' => other_key)

        expect { wrong.read('ws-1') }.to raise_error(Workspaces::Vault::Unavailable, /wrong WORKSPACES_MASTER_KEY, or the file is damaged/)
      end

      it 'does not decrypt a file copied to another workspace' do
        dir = Workspaces::Config.home.join('vault')
        FileUtils.cp(dir.join('ws-1.enc'), dir.join('ws-2.enc'))

        expect { file_vault.read('ws-2') }.to raise_error(Workspaces::Vault::Unavailable)
      end

      it 'detects a tampered file' do
        path = Workspaces::Config.home.join('vault', 'ws-1.enc')
        document = JSON.parse(path.read)
        data = document['data'].unpack1('m0')
        data.setbyte(0, data.getbyte(0) ^ 1)
        path.write(JSON.generate(document.merge('data' => [data].pack('m0'))))

        expect { file_vault.read('ws-1') }.to raise_error(Workspaces::Vault::Unavailable, /damaged/)
      end

      it 'reports garbage and an unknown format as unreadable, not as a crash' do
        path = Workspaces::Config.home.join('vault', 'ws-1.enc')
        path.write('not json')
        expect { file_vault.read('ws-1') }.to raise_error(Workspaces::Vault::Unavailable)

        path.write(JSON.generate('v' => 99))
        expect { file_vault.read('ws-1') }.to raise_error(Workspaces::Vault::Unavailable, /unknown format/)
      end

      it 'refuses a symlinked vault directory or file' do
        dir = Workspaces::Config.home.join('vault')
        target = Workspaces::Config.home.join('elsewhere')
        target.mkpath
        FileUtils.rm_rf(dir)
        File.symlink(target, dir)

        expect { file_vault.read('ws-1') }.to raise_error(Workspaces::Vault::Unavailable, /symlinks/)
      end

      it 'rejects a scope that is not a workspace id' do
        expect { file_vault.write('../escape', 'A' => '1') }.to raise_error(ArgumentError)
      end
    end
  end
end
