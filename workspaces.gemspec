require_relative 'lib/workspaces/version'

Gem::Specification.new do |spec|
  spec.name = 'workspaces'
  spec.version = Workspaces::VERSION
  spec.summary = 'Managed Git worktrees and browser previews for development'
  spec.authors = ['G2 Engineering']
  spec.required_ruby_version = '>= 3.3'
  spec.files = Dir['lib/**/*', 'exe/*', 'README.md', 'DESIGN.md']
  spec.bindir = 'exe'
  spec.executables = ['workspaces']
  spec.require_paths = ['lib']

  spec.add_dependency 'rack', '~> 3.2'
  spec.add_dependency 'rackup', '~> 2.2'
  spec.add_dependency 'puma', '>= 6', '< 8'
end
