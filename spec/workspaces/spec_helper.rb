require 'rspec'
require 'tmpdir'
require 'fileutils'
require 'pathname'
require 'stringio'
require 'open3'
require 'climate_control'
require 'rack/mock'
require 'workspaces'
require_relative 'fixtures/tls_pair'

RSpec.configure do |config|
  config.define_derived_metadata(file_path: %r{/spec/workspaces/}) do |metadata|
    metadata[:workspace_tool] = true
  end

  config.around(:each, :workspace_tool) do |example|
    Dir.mktmpdir('managed-workspaces-test') do |dir|
      ClimateControl.modify('WORKSPACES_HOME' => File.join(dir, 'home'),
                            'WORKSPACES_REPO_ROOT' => File.join(dir, 'repo'),
                            'WORKSPACES_PUBLIC_ORIGIN' => 'http://localhost:4747',
                            'WORKSPACES_GITHUB_REPO' => 'example/project',
                            'WORKSPACE_CACHE_DIR' => File.join(dir, 'home'),
                            'WORKSPACES_SUBDOMAIN_PREFIX' => 'ws-', 'WORKSPACES_BASE_DOMAIN' => 'localhost') do
        Workspaces::Config.instance_variable_set(:@home, nil)
        example.run
      ensure
        Workspaces::Config.instance_variable_set(:@home, nil)
      end
    end
  end
end

module WorkspaceFixtures
  def git(*args, cwd: Workspaces::Config.repo_root)
    identity = { 'GIT_MASTER' => '1', 'GIT_AUTHOR_NAME' => 'Fixture',
                 'GIT_AUTHOR_EMAIL' => 'fixture@example.test', 'GIT_COMMITTER_NAME' => 'Fixture',
                 'GIT_COMMITTER_EMAIL' => 'fixture@example.test' }
    output, status = Open3.capture2e(identity, 'git', *args, chdir: cwd.to_s)
    raise output unless status.success?
    output.strip
  end

  def repository
    root = Workspaces::Config.repo_root
    root.mkpath
    git('init', '-b', 'main')
    File.write(root.join('tracked.txt'), 'baseline')
    File.write(root.join('.gitignore'), "node_modules/\n.yarn/\npublic/assets/\n")
    recipe = { 'version' => 1, 'steps' => [
      { 'id' => 'setup', 'name' => 'Fixture setup', 'run' => ['ruby', '-e', 'puts "setup"'] },
      { 'id' => 'app', 'name' => 'Fixture server', 'run' => ['ruby', '-e', 'sleep 60'], 'background' => true },
      { 'id' => 'ready', 'name' => 'Fixture readiness', 'run' => ['ruby', '-e', 'puts "ready"'] }
    ] }
    File.write(root.join('.workspaces.yml'), YAML.dump(recipe))
    git('add', '.')
    git('-c', 'core.hooksPath=/dev/null', 'commit', '-m', 'Fixture baseline')
    root
  end

  def write_path_marker_bundle(root:, marker:, include_workspaces: false)
    root.mkpath
    gem_dir = root.join('path_marker')
    FileUtils.mkdir_p(gem_dir.join('lib'))
    File.write(gem_dir.join('path_marker.gemspec'), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = 'path_marker'
        spec.version = '0.0.1'
        spec.summary = 'path marker'
        spec.authors = ['fixtures']
        spec.files = ['lib/path_marker.rb']
        spec.require_paths = ['lib']
      end
    RUBY
    File.write(gem_dir.join('lib/path_marker.rb'), <<~RUBY)
      module PathMarker
        def self.marker
          #{marker.inspect}
        end
      end
    RUBY
    File.write(root.join('Gemfile'), <<~RUBY)
      source 'https://rubygems.org'
      gem 'path_marker', path: './path_marker'
      #{"gem 'workspaces', path: #{File.expand_path('../..', __dir__).inspect}" if include_workspaces}
    RUBY

    env = Workspaces::ChildEnv.for_workspace(workspace_path: root)

    output, status = Open3.capture2e(env, 'bundle', 'lock', '--local', chdir: root.to_s, unsetenv_others: true)
    raise "bundle lock failed for #{root}:\n#{output}" unless status.success?

    root
  end

  def bundled_path_marker_command(output_path: nil)
    nested = "require 'bundler/setup'; require 'path_marker'; puts 'nested=' + PathMarker.marker"
    statements = [
      "require 'bundler/setup'",
      "require 'path_marker'",
      "puts 'marker=' + PathMarker.marker",
      "puts 'gemfile=' + ENV.fetch('BUNDLE_GEMFILE', '<unset>')",
      "puts 'lockfile=' + ENV.fetch('BUNDLE_LOCKFILE', '<unset>')",
      "puts 'app_keep=' + ENV.fetch('APP_KEEP', '<unset>')",
      "puts 'app_delete=' + (ENV.key?('APP_DELETE') ? ENV['APP_DELETE'] : '<unset>')",
      "puts 'bundle_credential=' + ENV.fetch('BUNDLE_RUBYGEMS__PKG__GITHUB__COM', '<unset>')",
      "print Bundler.with_original_env { IO.popen(['bundle', 'exec', 'ruby', '-e', #{nested.inspect}]).read }"
    ]
    if output_path
      report = [
        "'marker=' + PathMarker.marker",
        "'gemfile=' + ENV.fetch('BUNDLE_GEMFILE', '<unset>')",
        "'lockfile=' + ENV.fetch('BUNDLE_LOCKFILE', '<unset>')",
        "'app_keep=' + ENV.fetch('APP_KEEP', '<unset>')",
        "'app_delete=' + (ENV.key?('APP_DELETE') ? ENV['APP_DELETE'] : '<unset>')",
        "IO.popen(['ruby', '-e', #{nested.inspect}]).read.strip"
      ].join(', ')
      statements << "File.write(#{output_path.to_s.inspect}, [#{report}].join(\"\\n\") + \"\\n\")"
    end
    ['ruby', '-e', statements.join('; ')]
  end
end

RSpec.configure { |config| config.include WorkspaceFixtures, :workspace_tool }
RSpec.configure { |config| config.include Workspaces::TlsPairFixture, :workspace_tool }
