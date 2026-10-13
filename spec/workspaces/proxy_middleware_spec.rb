require_relative 'spec_helper'
require 'socket'
require 'zlib'

RSpec.describe Workspaces::ProxyMiddleware do
  around do |example|
    described_class.reset!
    example.run
  ensure
    described_class.reset!
  end

  let(:endpoint) { ->(env) { [200, { 'content-type' => 'text/plain' }, ["endpoint #{env['PATH_INFO']}"]] } }

  def tag(name)
    Class.new do
      define_singleton_method(:name) { "Tag#{name}" }
      define_method(:initialize) { |app| @app = app }
      define_method(:call) do |env|
        status, headers, body = @app.call(env)
        [status, headers.merge("x-seen-#{name}" => '1', 'x-order' => [headers['x-order'], name].compact.join(',')), body]
      end
    end
  end

  it 'returns the endpoint itself when nothing is registered, so behavior is unchanged' do
    expect(described_class.any?).to be(false)
    expect(described_class.build(endpoint)).to equal(endpoint)
  end

  it 'replays registered blocks into a Rack stack with the first use outermost' do
    first = tag('a')
    second = tag('b')
    Workspaces.configure_proxy { use first }
    Workspaces.configure_proxy { use second }

    status, headers, body = described_class.build(endpoint).call(Rack::MockRequest.env_for('/x'))

    expect(status).to eq(200)
    expect(body).to eq(['endpoint /x'])
    expect(headers).to include('x-seen-a' => '1', 'x-seen-b' => '1')
    expect(headers['x-order']).to eq('b,a')
  end

  it 'passes constructor arguments through use' do
    greeter = Class.new do
      def initialize(app, greeting:)
        @app = app
        @greeting = greeting
      end

      def call(env)
        status, headers, body = @app.call(env)
        [status, headers.merge('x-greeting' => @greeting), body]
      end
    end
    Workspaces.configure_proxy { use greeter, greeting: 'hello' }

    headers = described_class.build(endpoint).call(Rack::MockRequest.env_for('/')).fetch(1)

    expect(headers['x-greeting']).to eq('hello')
  end

  it 'requires a block' do
    expect { Workspaces.configure_proxy }.to raise_error(described_class::ConfigurationError, /requires a block/)
  end

  describe '.env_paths' do
    it 'splits WORKSPACES_REQUIRE like PATH and ignores blanks' do
      ClimateControl.modify('WORKSPACES_REQUIRE' => ['/a.rb', ' ', '/b.rb'].join(File::PATH_SEPARATOR)) do
        expect(described_class.env_paths).to eq(['/a.rb', '/b.rb'])
      end
    end

    it 'is empty when unset' do
      ClimateControl.modify('WORKSPACES_REQUIRE' => nil) { expect(described_class.env_paths).to eq([]) }
    end
  end

  describe '.load_files' do
    it 'executes files so they can register middleware' do
      Dir.mktmpdir do |dir|
        file = File.join(dir, 'arb.rb')
        File.write(file, "Workspaces.configure_proxy { use(Class.new { def initialize(a); @a = a; end; def call(e); s, h, b = @a.call(e); [s, h.merge('x-loaded' => 'yes'), b]; end }) }\n")

        described_class.load_files([file])

        headers = described_class.build(endpoint).call(Rack::MockRequest.env_for('/')).fetch(1)
        expect(headers['x-loaded']).to eq('yes')
      end
    end

    it 'reports a missing file clearly' do
      expect { described_class.load_files(['/nope/missing.rb']) }
        .to raise_error(described_class::ConfigurationError, %r{not found: /nope/missing.rb})
    end

    it 'reports an error raised while loading, including syntax errors' do
      Dir.mktmpdir do |dir|
        boom = File.join(dir, 'boom.rb')
        syntax = File.join(dir, 'syntax.rb')
        File.write(boom, "raise 'kaboom'\n")
        File.write(syntax, "def (\n")

        expect { described_class.load_files([boom]) }
          .to raise_error(described_class::ConfigurationError, /Could not load.*boom.rb.*kaboom/)
        expect { described_class.load_files([syntax]) }
          .to raise_error(described_class::ConfigurationError, /Could not load.*syntax.rb/)
      end
    end
  end

  # The pixel from the feature request: injected before </body> of HTML responses.
  # This is the shape of middleware a remote container would register.
  describe 'injecting a script tag through the real front door' do
    let(:injector) do
      Class.new do
        def initialize(app)
          @app = app
        end

        def call(env)
          env['HTTP_ACCEPT_ENCODING'] = 'identity'
          status, headers, body = @app.call(env)
          return [status, headers, body] unless headers['content-type'].to_s.start_with?('text/html')

          html = body.each.to_a.join
          tag = %(<script src="https://arb.g2.com/embed/comments.js" data-thread-id="#{env['workspaces.workspace_id']}"></script>)
          html = html.sub('</body>', "#{tag}</body>")
          headers = headers.reject { |key, _| key.casecmp?('content-length') }
          [status, headers, [html]]
        end
      end
    end

    before { repository }

    let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }
    let(:coordinator) { Workspaces::Coordinator.new }

    # A tiny upstream that records what it was asked and serves canned responses.
    def with_upstream(responses)
      server = TCPServer.new('127.0.0.1', 0)
      seen = []
      thread = Thread.new do
        loop do
          client = server.accept
          lines = []
          while (line = client.gets) && line != "\r\n"
            lines << line
          end
          seen << lines
          path = lines.first.split[1]
          status, headers, payload = responses.fetch(path)
          head = headers.merge('content-length' => payload.bytesize.to_s, 'connection' => 'close')
          client.print "HTTP/1.1 #{status} OK\r\n#{head.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n#{payload}"
          client.close
        end
      rescue IOError
        nil
      end
      yield server.addr[1], seen
    ensure
      server&.close
      thread&.join(2)
    end

    def serve(app, path)
      host = Workspaces::Config.preview_host(workspace.id)
      env = Rack::MockRequest.env_for("http://#{host}#{path}").merge('HTTP_HOST' => host)
      app.call(env)
    end

    def stub_backend(port)
      snapshot = workspace.describe.merge('status' => 'ready', 'active' => false)
      allow(coordinator).to receive(:snapshot).with(workspace.id, include_log: false).and_return(snapshot)
      allow(Workspaces::Backend).to receive(:new).with(workspace.id).and_return(instance_double(Workspaces::Backend, port: port))
    end

    it 'injects the tag into HTML, leaves other content alone, and exposes the workspace id' do
      middleware = injector
      Workspaces.configure_proxy { use middleware }
      html = '<html><body><h1>hi</h1></body></html>'
      responses = {
        '/page' => [200, { 'content-type' => 'text/html; charset=utf-8' }, html],
        '/data.json' => [200, { 'content-type' => 'application/json' }, '{"a":1}']
      }

      with_upstream(responses) do |port, seen|
        stub_backend(port)
        app = Workspaces::FrontDoor.new(coordinator: coordinator)

        status, headers, body = serve(app, '/page')
        expect(status).to eq(200)
        expect(body.join).to include(%(data-thread-id="#{workspace.id}"></script></body>))
        expect(body.join).to include('src="https://arb.g2.com/embed/comments.js"')
        expect(headers['content-length']).to be_nil

        _, _, json = serve(app, '/data.json')
        expect(json.join).to eq('{"a":1}')

        expect(seen.first.grep(/accept-encoding/i).first).to match(/identity/i)
      end
    end

    it 'does not run middleware for the dashboard or for workspaces that are not ready' do
      calls = []
      probe = Class.new do
        define_method(:initialize) { |app| @app = app }
        define_method(:call) { |env| calls << env['PATH_INFO']; @app.call(env) }
      end
      Workspaces.configure_proxy { use probe }
      app = Workspaces::FrontDoor.new(coordinator: coordinator)

      dashboard = Rack::MockRequest.env_for('http://localhost:4747/workspaces').merge('HTTP_HOST' => 'localhost:4747')
      expect(app.call(dashboard).first).to eq(200)

      idle = workspace.describe.merge('status' => 'idle', 'active' => false)
      allow(coordinator).to receive(:snapshot).with(workspace.id, include_log: false).and_return(idle)
      status, headers, = serve(app, '/page')
      expect(status).to eq(303)
      expect(headers['location']).to eq(Workspaces::Config.dashboard_url(workspace.id))

      expect(calls).to be_empty
    end

    it 'does not set workspace env keys on dashboard requests' do
      seen_env = nil
      probe = Class.new do
        define_method(:initialize) { |app| @app = app }
        define_method(:call) { |env| seen_env = env; @app.call(env) }
      end
      Workspaces.configure_proxy { use probe }
      app = Workspaces::FrontDoor.new(coordinator: coordinator)

      app.call(Rack::MockRequest.env_for('http://localhost:4747/workspaces').merge('HTTP_HOST' => 'localhost:4747'))

      expect(seen_env).to be_nil
    end
  end
end
