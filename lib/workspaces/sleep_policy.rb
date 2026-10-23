# frozen_string_literal: true

require_relative 'config'
require_relative 'recipe'

module Workspaces
  # Which preview requests count as someone using a workspace. Health probes and the paths a recipe
  # lists under `sleep.ignore_paths` are background traffic: they neither keep a workspace awake
  # nor wake a sleeping one.
  class SleepPolicy
    DEFAULT_IGNORED_PATHS = %w(/health /up).freeze

    def initialize(recipe_path: nil)
      @recipe_path = recipe_path
      @cached = nil
    end

    def ignored?(request_path)
      globs.any? { |glob| File.fnmatch?(glob, request_path.to_s, File::FNM_EXTGLOB) }
    end

    private

    def globs
      path = @recipe_path || Config.repo_root.join('.workspaces.yml')
      stamp = path.file? ? path.mtime : nil
      return @cached[1] if @cached && @cached[0] == [path, stamp]

      @cached = [[path, stamp], DEFAULT_IGNORED_PATHS + configured_globs(path)]
      @cached[1]
    end

    def configured_globs(path)
      Recipe.new(root: path.dirname).sleep_ignore_paths
    rescue Recipe::Invalid
      []
    end
  end
end
