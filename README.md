# Workspaces

Standalone Ruby gem for managed Git worktrees, lifecycle commands, and browser previews.

This repository currently lives locally next to UE. There is no remote or published gem yet;
the UE integration relies on a sibling checkout (or `WORKSPACES_TOOL_ROOT`).

## Intended boundary

- This repository owns the generic workspace CLI, front door, lifecycle, and tests.
- A consuming repository owns its `.workspaces.yml` recipe and repository-specific
  setup/readiness scripts (for UE, `.workspaces/`).
- UE's `bin/workspaces` uses this repository's own Gemfile, installs its dependencies on
  first use, and forwards the same command-line arguments without loading Rails.
- Runtime data remains outside either Git repository under `WORKSPACES_HOME`.

## Development

Use Ruby 3.3.10. Run `bundle install` for the runtime CLI dependencies, then
`BUNDLE_GEMFILE=Gemfile.test bundle install` and
`BUNDLE_GEMFILE=Gemfile.test bundle exec rspec spec/workspaces` for standalone tests.
From a sibling UE checkout, `bin/workspaces help` and `bin/workspaces list --json`
use this gem. To work elsewhere, set `WORKSPACES_TOOL_ROOT` to the checkout of this repo.
Direct use of `exe/workspaces` also requires `WORKSPACES_REPO_ROOT` to point at the
consuming repository, or a working directory inside one containing `.workspaces.yml`.

UE retains its `.workspaces.yml`, `.workspaces/` scripts, and their UE-specific tests.
Its Workspaces operator guide remains at `.claude/skills/workspaces/SKILL.md`.
Do not remove or change the existing hosted front door until distribution and CI
for this gem are in place and the deployment has been tested against the external code.
