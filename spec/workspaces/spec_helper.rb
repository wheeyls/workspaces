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
                            'WORKSPACES_GITHUB_REPO' => 'fixture/example',
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
end

RSpec.configure { |config| config.include WorkspaceFixtures, :workspace_tool }
RSpec.configure { |config| config.include Workspaces::TlsPairFixture, :workspace_tool }
