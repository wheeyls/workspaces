require_relative 'spec_helper'

RSpec.describe 'environment secrets' do
  before do
    repository
    ENV['WORKSPACES_MASTER_KEY'] = ['k' * 32].pack('m0')
  end

  after { ENV.delete('WORKSPACES_MASTER_KEY') }

  let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }
  let(:store) { Workspaces::EnvironmentOverrides.new(workspace.id) }
  let(:secret) { 'sk_live_Zx9-very-secret-value' }

  def row(name, value, secret: false)
    { 'name' => name, 'value' => value, 'secret' => secret ? '1' : nil }.compact
  end

  describe Workspaces::EnvironmentOverrides do
    it 'stores a secret in the vault and nowhere else, and gives it to steps through load' do
      store.replace_rows([row('UE_APP', 'www'), row('STRIPE_KEY', secret, secret: true)], defaults: {})

      expect(store.load).to eq('UE_APP' => 'www', 'STRIPE_KEY' => secret)
      expect(store.load_plain).to eq('UE_APP' => 'www')
      expect(store.secret_names).to eq(%w(STRIPE_KEY))
      expect(store.keys).to eq(%w(STRIPE_KEY UE_APP))
      Dir.glob(Workspaces::Config.home.join('**/*').to_s).select { |path| File.file?(path) }.each do |path|
        next if path.include?('/vault/')

        expect(File.binread(path)).not_to include(secret)
      end
    end

    it 'keeps a stored secret when its row is saved with no value' do
      store.replace_rows([row('STRIPE_KEY', secret, secret: true)], defaults: {})
      store.replace_rows([row('STRIPE_KEY', '', secret: true), row('A', '1')], defaults: {})

      expect(store.load).to eq('STRIPE_KEY' => secret, 'A' => '1')
    end

    it 'replaces a secret only when a new value is given' do
      store.replace_rows([row('STRIPE_KEY', secret, secret: true)], defaults: {})
      store.replace_rows([row('STRIPE_KEY', 'sk_live_new', secret: true)], defaults: {})

      expect(store.load).to eq('STRIPE_KEY' => 'sk_live_new')
    end

    it 'removes a secret that is no longer listed, and the file when none are left' do
      store.replace_rows([row('A_KEY', 'one', secret: true), row('B_KEY', 'two', secret: true)], defaults: {})
      store.replace_rows([row('A_KEY', '', secret: true)], defaults: {})
      expect(store.secret_names).to eq(%w(A_KEY))

      store.replace_rows([], defaults: {})
      expect(store.secret_names).to eq([])
      expect(Workspaces::Config.home.join('vault', "#{workspace.id}.enc")).not_to exist
    end

    it 'refuses a new secret with no value' do
      expect { store.replace_rows([row('NEW_KEY', '', secret: true)], defaults: {}) }
        .to raise_error(described_class::Invalid, /NEW_KEY is a new secret and needs a value/)
    end

    it 'keeps secret-like names out of the visible variables, telling the person what to do' do
      expect { store.replace_rows([row('API_TOKEN', 'x')], defaults: {}) }
        .to raise_error(described_class::Invalid, /API_TOKEN looks like a secret: tick Secret/)
    end

    it 'allows any valid name to be a secret, and still blocks the runner\'s own names' do
      store.replace_rows([row('PLAIN_NAME', 'v', secret: true)], defaults: {})
      expect(store.secret_names).to eq(%w(PLAIN_NAME))
      expect { store.replace_rows([row('WORKSPACE_PORT', 'v', secret: true)], defaults: {}) }
        .to raise_error(described_class::Invalid, /reserved/)
    end

    it 'saves nothing at all when any row is invalid' do
      store.replace_rows([row('GOOD', '1')], defaults: {})

      expect { store.replace_rows([row('GOOD', '2'), row('K_SECRET', secret, secret: true), row('1BAD', 'x')], defaults: {}) }
        .to raise_error(described_class::Invalid)
      expect(store.load).to eq('GOOD' => '1')
    end

    it 'rejects repeated names, including across plain and secret rows, without repeating a value' do
      expect { store.replace_rows([row('A', '1'), row('A', secret, secret: true)], defaults: {}) }
        .to raise_error(described_class::Invalid) { |error| expect(error.message).to eq('A is listed more than once') }
    end

    it 'ignores blank rows and rejects multi-line visible values' do
      store.replace_rows([row('', ''), row('A', '1')], defaults: {})
      expect(store.load).to eq('A' => '1')
      expect { store.replace_rows([row('B', "x\ny")], defaults: {}) }.to raise_error(described_class::Invalid, /single line/)
    end

    it 'does not touch the default values the recipe already provides' do
      store.replace_rows([row('UE_APP', 'www')], defaults: { 'UE_APP' => 'www' })

      expect(store.load_plain).to eq({})
    end

    it 'refuses to save secrets without a usable vault, and still saves everything else' do
      ENV.delete('WORKSPACES_MASTER_KEY')

      expect { store.replace_rows([row('A_KEY', 'x', secret: true)], defaults: {}) }
        .to raise_error(Workspaces::Vault::Unavailable, /WORKSPACES_MASTER_KEY/)
      store.replace_rows([row('A', '1')], defaults: {})
      expect(store.load).to eq('A' => '1')
    end

    it 'never overwrites stored secrets when the key is wrong' do
      store.replace_rows([row('A_KEY', secret, secret: true)], defaults: {})
      ENV['WORKSPACES_MASTER_KEY'] = ['z' * 32].pack('m0')

      expect { store.replace_rows([row('A_KEY', 'other', secret: true)], defaults: {}) }
        .to raise_error(Workspaces::Vault::Unavailable)
      ENV['WORKSPACES_MASTER_KEY'] = ['k' * 32].pack('m0')
      expect(store.load).to eq('A_KEY' => secret)
    end

    it 'still hides a secret from logs when the vault later cannot be read' do
      store.replace_rows([row('A_KEY', secret, secret: true)], defaults: {})
      scrubber = described_class.new(workspace.id)

      expect(scrubber.scrub("value #{secret} here")).to eq('value [FILTERED] here')
      ENV.delete('WORKSPACES_MASTER_KEY')
      expect(scrubber.secret_names).to eq([])
      expect(scrubber.load_plain).to eq({})
    end

    it 'purges secrets when a workspace is cleared' do
      store.replace_rows([row('A_KEY', secret, secret: true)], defaults: {})
      store.clear!

      expect(Workspaces::Config.home.join('vault', "#{workspace.id}.enc")).not_to exist
    end
  end

  describe Workspaces::Registry do
    it 'purges a removed workspace\'s secrets' do
      store.replace_rows([row('A_KEY', secret, secret: true)], defaults: {})

      described_class.new.remove(workspace.id, force: true)

      expect(Dir.glob(Workspaces::Config.home.join('vault', '*').to_s)).to be_empty
    end
  end

  describe Workspaces::Coordinator do
    let(:coordinator) { described_class.new }

    it 'puts secret names, a vault status and never a value in the snapshot' do
      store.replace_rows([row('UE_APP', 'www'), row('A_KEY', secret, secret: true)], defaults: {})
      snapshot = coordinator.snapshot(workspace.id)

      expect(snapshot['secret_names']).to eq(%w(A_KEY))
      expect(snapshot['vault']).to eq('provider' => 'file', 'available' => true, 'problem' => nil)
      expect(snapshot['editable_environment']).to eq('UE_APP' => 'www')
      expect(snapshot.to_json).not_to include(secret)
    end

    it 'reports an unusable vault without exposing anything' do
      ENV.delete('WORKSPACES_MASTER_KEY')

      expect(coordinator.snapshot(workspace.id)['vault']).to include('available' => false, 'problem' => /WORKSPACES_MASTER_KEY/)
    end
  end

  describe Workspaces::FrontDoor do
    let(:coordinator) { Workspaces::Coordinator.new }
    let(:app) { described_class.new(coordinator: coordinator) }

    def post(form)
      env = Rack::MockRequest.env_for("http://localhost:4747/workspaces/#{workspace.id}/environment", method: 'POST',
                                      input: Rack::Utils.build_nested_query(form))
      env['HTTP_HOST'] = 'localhost:4747'
      env['HTTP_ORIGIN'] = 'http://localhost:4747'
      env['CONTENT_TYPE'] = 'application/x-www-form-urlencoded'
      app.call(env)
    end

    it 'saves rows, restarts, and answers with a redirect that carries no value' do
      status, headers, body = post('env' => { '0' => { 'name' => 'UE_APP', 'value' => 'www' },
                                                '1' => { 'name' => 'A_KEY', 'value' => secret, 'secret' => '1' } })

      expect(status).to eq(303)
      expect(headers.values.join + body.join).not_to include(secret)
      expect(store.load).to eq('UE_APP' => 'www', 'A_KEY' => secret)
      coordinator.wait(workspace.id)
    end

    it 'orders rows by their numbers, not by arrival' do
      post('env' => { '10' => { 'name' => 'B', 'value' => '2' }, '2' => { 'name' => 'A', 'value' => '1' } })
      coordinator.wait(workspace.id)

      expect(store.load_plain).to eq('A' => '1', 'B' => '2')
    end

    it 'answers an invalid row with 422 and never echoes a submitted value' do
      status, _, body = post('env' => { '0' => { 'name' => 'API_TOKEN', 'value' => secret } })

      expect(status).to eq(422)
      expect(body.join).to include('API_TOKEN looks like a secret')
      expect(body.join).not_to include(secret)
    end

    it 'answers an unusable vault with 422, naming the key and not any value' do
      ENV.delete('WORKSPACES_MASTER_KEY')
      status, _, body = post('env' => { '0' => { 'name' => 'A_KEY', 'value' => secret, 'secret' => '1' } })

      expect(status).to eq(422)
      expect(body.join).to include('WORKSPACES_MASTER_KEY')
      expect(body.join).not_to include(secret)
    end

    it 'rejects rows that are not a numbered list of name and value fields' do
      expect(post('env' => 'oops').first).to eq(422)
      expect(post('env' => { 'x' => { 'name' => 'A', 'value' => '1' } }).first).to eq(422)
      expect(post('env' => { '0' => { 'name' => ['A'], 'value' => '1' } }).first).to eq(422)
    end

    it 'still accepts the older single-textarea post, leaving stored secrets alone and refusing secret-like names' do
      store.replace_rows([row('A_KEY', secret, secret: true)], defaults: {})

      expect(post('editable_env' => "FOO=bar\n").first).to eq(303)
      coordinator.wait(workspace.id)
      expect(store.load).to include('FOO' => 'bar', 'A_KEY' => secret)

      status, _, body = post('editable_env' => "MY_TOKEN=x\n")
      expect(status).to eq(422)
      expect(body.join).to include('Secret-like')
    end

    it 'does not leak a secret through the status endpoint' do
      store.replace_rows([row('A_KEY', secret, secret: true)], defaults: {})
      env = Rack::MockRequest.env_for("http://localhost:4747/workspaces/#{workspace.id}/status")
      env['HTTP_HOST'] = 'localhost:4747'

      expect(app.call(env)[2].join).not_to include(secret)
    end
  end

  describe 'a real run' do
    let(:coordinator) { Workspaces::Coordinator.new }
    let(:marks) { Workspaces::Config.home.join('marks') }

    before do
      FileUtils.mkdir_p(marks)
      recipe = { 'version' => 1, 'steps' => [
        { 'id' => 'setup', 'name' => 'Setup',
          'run' => ['ruby', '-e', %(File.write("#{marks}/seen", ENV["STRIPE_KEY"].to_s); File.write("#{marks}/master", ENV["WORKSPACES_MASTER_KEY"].to_s); puts "key=" + ENV["STRIPE_KEY"].to_s)] },
        { 'id' => 'app', 'name' => 'Server', 'run' => ['ruby', '-e', 'sleep 60'], 'background' => true },
        { 'id' => 'ready', 'name' => 'Ready', 'run' => ['ruby', '-e', 'puts "ready"'] }
      ] }
      File.write(Workspaces::Config.repo_root.join('.workspaces.yml'), YAML.dump(recipe))
    end

    after { Workspaces::Backend.new(workspace.id).stop! }

    it 'gives the secret to the step, keeps the master key out of it, and shows neither in any log or snapshot' do
      coordinator.replace_environment_rows(workspace.id, rows: [row('STRIPE_KEY', secret, secret: true)])
      snapshot = coordinator.wait(workspace.id)

      expect(snapshot['status']).to eq('ready')
      expect(marks.join('seen').read).to eq(secret)
      expect(marks.join('master').read).to eq('')
      expect(snapshot.to_json).not_to include(secret)
      logs = Dir.glob(Workspaces::Config.home.join('**/*.log').to_s).map { |path| File.read(path) }.join
      expect(logs).to include('key=[FILTERED]')
      expect(logs).not_to include(secret)
      expect(logs).not_to include(ENV.fetch('WORKSPACES_MASTER_KEY'))
      expect(Workspaces::Config.home.join('state.json').read).not_to include(secret) if Workspaces::Config.home.join('state.json').exist?
    end

    it 'fails a run with a plain reason, rather than starting without its secrets, when the key is wrong' do
      store.replace_rows([row('STRIPE_KEY', secret, secret: true)], defaults: {})
      ENV['WORKSPACES_MASTER_KEY'] = ['z' * 32].pack('m0')

      coordinator.start(workspace.id, force: true)
      snapshot = coordinator.wait(workspace.id)

      expect(snapshot['status']).to eq('error')
      expect(snapshot['last_error']).to include('could not be decrypted')
      expect(snapshot.to_json).not_to include(secret)
      expect(marks.join('seen')).not_to exist
    end
  end
end
