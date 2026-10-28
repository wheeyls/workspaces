# Workspaces

Workspaces is a Ruby gem for managed Git worktrees, lifecycle commands, and browser previews.
It runs independently of Rails. Each project supplies its own `.workspaces.yml` recipe and
any setup or readiness scripts that recipe calls. Workspace state and logs are stored outside
the project under `WORKSPACES_HOME`.

## Usage

Install the gem in your project's bundle:

```ruby
# Gemfile
gem 'workspaces'
```

```sh
bundle install
bundle exec workspaces help
bundle exec workspaces create --branch main --json
bundle exec workspaces start <workspace-id> --json
```

Or install it into your Ruby environment without Bundler:

```sh
gem install workspaces
workspaces help
```

Run the commands from the project containing `.workspaces.yml`, or set
`WORKSPACES_REPO_ROOT` to its absolute path. The gem executable does not load Rails.
Gem installation requires a published release; until then, a project may reference a
tagged Git revision in its Gemfile instead of the RubyGems release.

`create` makes a managed worktree but does not start the application. `start` runs the
project's `.workspaces.yml` steps, starts its background server, and waits for readiness.
The returned JSON includes the workspace ID, dashboard URL, and preview URL. You can also
create from a pull request with `create --pr NUMBER`, or create a new branch with
`create --new-branch NAME --from REF`. Run `help` for lifecycle and other commands.

### Git LFS

If the project keeps large files in [Git LFS](https://git-lfs.com), a new workspace does not
copy them. Creating a workspace (and fast-forwarding a PR workspace to a newer head) leaves
those files as small pointer files, and `git status` stays clean. Without this, every
workspace would hold a full second copy of every LFS file, even though the source
checkout's LFS store is already shared.

List the paths a workspace actually needs in `.workspaces.yml`:

```yaml
lfs:
  fetch:
    - eval/amc/images/golden/**
    - spec/fixtures/images/**
```

That adds a first step, **Fetch Git LFS files**, which runs
`git lfs pull --include=<paths>` in the workspace. It appears in the step list with its own
log, time and place in the progress estimate like any other step, and it runs on `start` and
`prepare` but not on `restart`. Paths are repository-relative patterns; absolute paths,
`..`, a leading `-`, commas and control characters are rejected when the recipe loads.
Omit `lfs` and nothing changes except that files stay as pointers.

A few things worth knowing:

- Files are fetched from the objects the source repository already has when it can, and from
  the remote otherwise. If neither works (no network, or no credentials for LFS) the step
  fails and the workspace reports it, rather than silently leaving pointers.
- A file that is still a pointer reads as a ~130 byte text file starting with
  `version https://git-lfs`. If a test or build reads an LFS file, add its path to
  `lfs.fetch`.
- To fetch more by hand in an existing workspace:
  `workspaces exec <id> -- git lfs pull --include='path/**'`.
- Workspaces created before this behavior keep their real files; nothing is converted.

### Step timings

Per-step durations are persisted in seconds in workspace step status JSON, so they
remain available after the command exits, along with the wall-clock `total_seconds` of
the last run. Timings also appear in CLI progress, the workspace setup log, and the
dashboard. Everywhere they are shown as `0.5s`, `12.3s`, `1m 10s` or `1h 5m 3s`, never
as a large bare seconds count. The dashboard's Full setup log row shows the total
(`complete · 2m 17s`).

A background step measures only process launch, not the server's lifetime or
readiness. The following readiness step measures its own wait separately.
Interrupted steps have no recorded duration. Step timings are not the total
workflow wall-clock time; orchestration overhead can fall outside the steps, which is
why the total is measured separately and is usually a little larger than their sum.

### Build history and the progress bar

While a workspace is being prepared the dashboard shows a progress bar with the current step,
the percentage, the elapsed time and, once there is history, an estimate of what is left.

Every finished run is appended to `build-history.jsonl` in the Workspaces home, one JSON
object per line, shared by all workspaces of the project. It is written quietly and a failure
to write it never affects the build. Each record has the time, workspace, operation
(`prepare`, `restart` or `resume`), result (`complete` or `failed`), `total_seconds`, the Workspaces
version, and each step's id, state and seconds. To see which step is getting slower:

```sh
jq -r 'select(.result=="complete") | .at[:10] as $d | .steps[] | [$d, .id, .seconds] | @tsv' \
  "$WORKSPACES_HOME/build-history.jsonl"
```

Estimates are the mean of each step over its last 10 successful runs. Failed runs are
recorded for the trend but never count toward "usual". They are read once when a run starts,
so the bar does not shift while you watch it. Percentages weigh each step by how long it
usually takes, count the running step by how much of its usual time has passed, never reach
100% until the run finishes, and hold a step that overruns below done. A step more than 1.5
times its usual time is flagged as taking longer than usual. With no history yet, steps weigh
the same and no time estimate is shown. Delete the file to start the estimates over.

## Sleeping idle workspaces

A ready workspace that sees no preview traffic for a while is put to sleep: its server (the
managed process group, and nothing shared such as PostgreSQL or Redis) is stopped, and the
front door keeps answering on the same preview URL. The worktree, database, dependencies, built
assets, environment settings and build history are untouched. The first request to a sleeping
preview wakes it. A browser opening a page is shown the waiting card (below) at that address, and
the card reloads the page once the workspace is ready. Any other request (an API call, an asset, a
form post) waits for readiness and is then forwarded.

```sh
WORKSPACES_SLEEP_AFTER_MINUTES=30   # default; 15 also works; 0 switches sleeping off
WORKSPACES_WAKE_TIMEOUT_SECONDS=90  # how long the first request waits for a wake
WORKSPACES_SLEEP_SWEEP_SECONDS=30   # how often idle workspaces are looked for
bundle exec workspaces keep-awake <workspace-id>          # never sleep this workspace
bundle exec workspaces keep-awake <workspace-id> --off    # allow sleep again
```

The dashboard shows when a workspace sleeps, says "asleep" with a **Wake workspace** button, and has
**Keep awake** / **Allow sleep** under Workspace controls. The setting is stored with the workspace.

What counts as activity:

- Preview requests do. Dashboard and status polling never reach the preview and do not count.
- `/health` and `/up` never count and never wake a workspace. List more background polling under
  `sleep.ignore_paths` (globs on the request path) in `.workspaces.yml`:

  ```yaml
  sleep:
    ignore_paths:
      - /api/heartbeat
  ```

- A request in flight holds the workspace awake until its response body is finished. Streamed
  responses hold it until the body is closed. Streaming and upgraded connections are not newly
  supported by the proxy; this only means the ones it already serves are never cut off.
- Work the proxy cannot see (background jobs, scheduled tasks) is not activity. A workspace that
  runs such work needs `keep-awake`, or `WORKSPACES_SLEEP_AFTER_MINUTES=0`.

How waking behaves:

- Only an intentionally sleeping workspace wakes. A workspace stopped by hand, failed, or still
  preparing is never started by traffic. A browser opening a page is shown the waiting card; any
  other GET is redirected to the card on the dashboard host, and other methods get `503`.
- Simultaneous first requests share one wake and start one server. A request is sent upstream
  once, never replayed, and keeps its method and body.
- A wake runs only the server and readiness steps. If a step before the server changed in
  `.workspaces.yml` since the workspace was prepared, it runs the full preparation instead.
- A wake that fails or runs past the timeout answers `503` with `Retry-After`, a link to the
  dashboard, and the failure in the workspace's status and logs. It is not retried in a loop.
- Sleeping and waking use the same per-workspace lock as start, stop, restart and rebuild, so
  they cannot overlap. After a front-door restart a sleeping workspace stays asleep, a sleep cut
  short is finished, and a wake cut short shows as interrupted.
- Idle clocks live in the front door's memory, so a restart gives every workspace a fresh idle period.

## Serve the dashboard and previews

Run `serve` in a separate terminal using the **same project root and `WORKSPACES_HOME`**
as `create` and `start`:

```sh
bundle exec workspaces serve
```

For a global installation, omit `bundle exec` in every example.

By default, the front door listens on `127.0.0.1:4747`. Open
`http://localhost:4747/workspaces` for the dashboard. Preview URLs use
`http://ws-<workspace-id>.localhost:4747/`. Make sure the wildcard preview hosts
resolve to the machine running the front door; a DNS entry or local resolver may be
needed on your system. Set `WORKSPACES_BASE_DOMAIN` and
`WORKSPACES_SUBDOMAIN_PREFIX` to choose a different preview hostname pattern.

The front door is a reverse proxy. It accepts the dashboard host for workspace status
and lifecycle actions, recognizes `ws-<workspace-id>` preview hosts, checks that the
workspace is ready, and forwards requests (including cookies) to that workspace's
server on a reserved `127.0.0.1` port in the `30000–30999` range. The recipe's
`background: true` step must start the application on `127.0.0.1:$WORKSPACE_PORT`;
the following foreground readiness step must verify it is *this* boot (the runner
provides `WORKSPACE_RUN_ID`). The runner also supplies `WORKSPACE_URL` and
`WORKSPACE_HOST` for applications that need browser-facing URLs and host settings.
`serve` does **not** start workspace backends; use `start` or `restart` for those.

### The workspace card and the settings page

`/workspaces/<id>` is one small card in the middle of the screen: a headline, the progress bar
while something is running, the preset in use, and the single next action. That action is **Open
workspace** when ready, **Wake workspace** or **Start workspace** when asleep or stopped, and
**Retry failed step** or **Continue setup** after a failure. A gear links to
`/workspaces/<id>/settings`, which is the full page: environment variables and secrets, setup
steps and logs, workspace details, lifecycle controls and removal. A new workspace starts from the
card by choosing one preset (or the defaults); use the settings page to edit variables first.
Update from PR lives on the settings page and returns there. Nothing opens the preview for you;
the card only offers the button.

The `/workspaces` list and the PR page are unchanged.

#### The waiting card on a preview host

When a browser opens a page of a workspace that is not serving (stopped, preparing, failed or
asleep), the preview host answers `200` with the same card instead of redirecting to the
dashboard, so the address in the bar is the one the visitor asked for. A sleeping workspace is
woken at once. The card polls its status and, when the workspace is ready, reloads the page, so the
visitor lands where they meant to go, query string included.

- Only browser navigations see it: a `GET` that accepts `text/html`, is not an `XMLHttpRequest`
  and, when the browser says, has `Sec-Fetch-Mode: navigate`. API calls, assets and other methods
  behave as before.
- The preview origin also serves the workspace's own app, so the card is deliberately small. Its
  endpoints are `GET /__workspaces/status` and `POST /__workspaces/start|prepare|restart|resume`.
  The prefix is reserved: any other path under it answers `404`, and it is never forwarded to the
  app. Settings, environment, secrets, logs and removal are not reachable from it.
- The posts accept only the workspace's own preview origin (the `Origin`, or `Referer`, must match
  `ws-<id>…`); the shared dashboard origin and other workspaces are refused. After a post the
  visitor returns to the page they were on.
- The status payload carries no logs, steps, environment values or error text. A failure reads
  "Setup failed. Open settings for the full log.", with the gear and link going to the shared
  settings page.
- Polling the card is not preview traffic, so it never keeps a workspace awake.

### Re-running part of a run

When a run fails, or is interrupted, you do not have to start over. `resume` continues from the
first step that did not finish and keeps every earlier step's state, time and log:

```sh
bin/workspaces resume ID                  # retry from the first unfinished step
bin/workspaces resume ID --from STEP      # re-run STEP and every step after it
bin/workspaces resume ID --only STEP      # re-run exactly one step
```

The dashboard offers the same: **Retry failed step** (or **Continue setup** after an
interruption) with **Re-run all steps** beside it, and, inside each step, **Re-run this step**
and **Re-run from here** where they are allowed. `POST /workspaces/ID/resume` takes optional
`from=STEP` or `only=STEP` query parameters.

A failed run stops the server, so a failure at or after the `background: true` step retries from
that step, exactly like a restart: the server is started again with a fresh `WORKSPACE_RUN_ID`
and readiness is checked against it. A failure before the server step retries that step and
everything after it. Re-running steps *after* the server step, on a workspace whose server is
still up, reuses that server's port and `WORKSPACE_RUN_ID`, and leaves it running even if
the step fails.

A re-run never leaves an unfinished step behind (`--from` cannot skip one, `--only` needs every
other step finished), so a successful one always means a complete workspace. It is refused, in
plain words, when `.workspaces.yml`'s steps no longer match the ones recorded, when the server
step is asked for on its own, or when a step after the server is asked for and the server is not
running. The build history records only the steps that re-ran, with operation `resume`.

The `/workspaces` dashboard lists each managed workspace's setup status, whether its
backend is running, creation time, and last backend startup. On a workspace's detail
page, the Danger Zone lets an operator delete that one workspace after typing its
exact ID. Deletion stops the backend and force-removes the worktree, including
uncommitted and untracked files; the branch and committed changes are preserved.
Busy workspaces cannot be removed until their current operation finishes. This
action is protected by the dashboard's same-origin POST check, but that check is
not authentication—keep hosted deployments behind VPN or SSO.

The dashboard favicon is blue for localhost and gold for hosted origins, helping
distinguish local and hosted tabs.

PR workspaces also offer **Update from PR** on their detail page. It fetches the
latest PR head and fast-forwards the workspace branch only when the new head is
a descendant of its current commit. Local tracked and untracked changes are
temporarily stashed and restored (including staged state). On a restore conflict,
the stash is retained for manual recovery. Updating the checkout does not run
setup or restart the already-running backend; use Rebuild & restart afterward.

### Environment variables and secrets

A workspace's settings are rows of **name** and **value**, with a **Secret**
checkbox on each. Add and remove rows as needed; **Save & restart** applies them.

A *secret* is an environment variable that is write-only. Its value goes to a
vault, is handed to the workspace's setup steps and server as an ordinary
environment variable, and is never shown again: not in the dashboard, the status
API, the logs (any output that contains it is filtered) or error messages. A saved
secret appears as its name with an empty, password-style field that says a value is
stored. Leave that field blank to keep the stored value, type a new one to replace
it, or remove the row to delete the secret. A stored secret cannot be turned back
into a visible variable. Names that look like secrets (`*_TOKEN`, `*_SECRET`,
`*_PASSWORD`, `*_API_KEY`, ...) cannot be saved as visible variables; tick **Secret**.
Presets only ever change visible variables.

Which vault is used is set where `serve` runs, with `WORKSPACES_VAULT` (default
`file`). The built-in `file` vault keeps one AES-256-GCM encrypted file per workspace
in `$WORKSPACES_HOME/vault/`, with a key derived per workspace from a master key you
provide:

```sh
export WORKSPACES_MASTER_KEY="$(openssl rand -base64 32)"   # keep this; it cannot be recovered
bin/workspaces serve --secure
```

Without `WORKSPACES_MASTER_KEY` the settings page says secrets are turned off, and
everything else works as before. With the wrong key a run fails with a plain reason
rather than starting without its secrets, and saving is refused so stored secrets are
never overwritten. The master key is read only by the front door: it is removed from
the environment of every step, server and `exec` command.

Removing a workspace (`remove`, or the dashboard's Remove button) deletes its secrets
too. The file vault is always asked to delete its own files, even if `WORKSPACES_VAULT`
has since been changed. A secret that cannot be deleted is reported rather than hidden:
`remove` exits non-zero and lists it under `secrets_left`, and the dashboard says the
workspace was removed but its secrets were not. Secrets live outside the workspace's
checkout, in `$WORKSPACES_HOME/vault/<workspace-id>.enc`, with no other record of the
link, so a workspace deleted some other way (by hand, or `git worktree remove`) leaves
its file behind. Clean those up with:

```sh
bin/workspaces purge-secrets --dry-run   # list secrets whose workspace no longer exists
bin/workspaces purge-secrets             # delete them
```

It refuses to run if the workspaces directory cannot be read, so an unmounted volume is
never mistaken for "every workspace is gone".

Another store can be added behind the same small interface (`available?`/`problem`,
`read(scope)`, `write(scope, entries)`, `purge(scope)`, and optionally `scopes` to
list what it holds so `purge-secrets` can find orphans): subclass
`Workspaces::Vault::Provider` and call `Workspaces::Vault.register('name', YourClass)`
from a file loaded with `serve --require`, then set `WORKSPACES_VAULT=name`.

### Editable environment presets

Recipes can define editable environment defaults and named presets in
`.workspaces.yml`:

```yaml
default_editable_env:
  DEMO_MODE: "false"

environment_presets:
  Demo:
    DEMO_MODE: "true"
  Demo off:
    DEMO_MODE: "false"
```

Each preset maps editable variable names to values. In the workspace settings,
choosing a preset replaces the visible variable rows rather than merging with
them (secret rows are left alone). Selection does not save or restart the
workspace; choose **Save & restart** to apply the draft. Presets are not applied automatically,
and defining them requires no JavaScript edits. Preset keys must be declared in
`default_editable_env`; recipes reject undeclared keys and secret-like values.
Hidden environment values are never exposed in the settings or preset choices.

Use `create --branch main --preset Demo` to save a preset for a new, still-idle
workspace. `start ID --preset Demo` applies it before preparing a stopped
workspace; `restart ID --preset 'Demo off'` switches a running workspace and
restarts its server. `prepare ID --preset Demo` switches and rebuilds. An
unknown name is rejected without changing saved settings. Selecting a preset
replaces the editable settings (including custom rows) but preserves
hidden legacy overrides. A running workspace requires `restart --preset` or
`prepare --preset`, not `start --preset`.

For one-off non-secret tweaks, add repeatable `--set NAME=VALUE` and
`--unset NAME` flags to `create`, `start`, `prepare`, or `restart`. For example,
`restart ID --preset Demo --set DEMO_FEATURE=on` applies the preset first,
then the individual changes, and restarts. Without `--preset`, these flags
patch current editable settings. Names reserved for the runner and names
suggesting secrets are rejected; values on the command line may be visible
in process listings and shell history. Use a secret store, not `--set`, for
credentials.

The front door is not an authentication boundary. Its host and same-origin checks
protect routing and POST actions, but a publicly reachable instance still needs
access control such as VPN or SSO. Do not expose workspace backend ports directly.

### Proxy middleware

The front door can run Rack middleware around traffic that is forwarded to a workspace
backend. The gem knows nothing about what a middleware does: the container or host
that runs `serve` registers its own. Typical uses are injecting a script tag, adding a
header, or logging.

```ruby
# my_middleware.rb
Workspaces.configure_proxy do
  use MyMiddleware, option: 'value'
end
```

Load it with `serve --require FILE` (repeatable) or by setting `WORKSPACES_REQUIRE` to
one or more paths separated like `PATH` entries. Environment entries load first, then
`--require` files in order. A missing file or an error while loading stops `serve` with
a non-zero exit instead of silently running without it. These files are executed with
the front door's privileges, so only name files the operator controls. With nothing
registered, the front door behaves exactly as before.

Blocks run in registration order and the first `use` is outermost. The stack wraps only
the step that forwards a request to a ready workspace backend. The dashboard, redirects
for workspaces that are not ready, and error pages never pass through it. For each
proxied request, two Rack env keys are available:

| Key | Value |
| --- | --- |
| `workspaces.workspace_id` | The workspace ID, such as `main-1ae4815f` |
| `workspaces.workspace` | The workspace snapshot hash (branch, status, related PR, and so on) |

Two details matter when rewriting response bodies. The proxy passes the browser's
`Accept-Encoding` to the backend, so a compressed response arrives compressed; set
`env['HTTP_ACCEPT_ENCODING'] = 'identity'` before calling the app, or skip responses
with a `Content-Encoding` header. If you change the body, drop the stale `Content-Length`
header. An example that appends a script tag to HTML pages:

```ruby
class ScriptInjector
  TAG = '<script src="https://example.test/widget.js" data-thread-id="%<id>s"></script>'

  def initialize(app)
    @app = app
  end

  def call(env)
    env['HTTP_ACCEPT_ENCODING'] = 'identity'
    status, headers, body = @app.call(env)
    return [status, headers, body] unless headers['content-type'].to_s.start_with?('text/html')

    html = body.each.to_a.join.sub('</body>', format(TAG, id: env['workspaces.workspace_id']) + '</body>')
    [status, headers.reject { |key, _| key.casecmp?('content-length') }, [html]]
  end
end

Workspaces.configure_proxy { use ScriptInjector }
```

### Local HTTPS

To serve TLS directly, install/trust a local CA and create a certificate covering
`workspaces.localhost` and `*.workspaces.localhost`. For example, with `mkcert`:

```sh
mkcert -install
mkdir -p ~/.workspaces/certs
mkcert -cert-file ~/.workspaces/certs/workspaces.pem \
  -key-file ~/.workspaces/certs/workspaces-key.pem \
  workspaces.localhost '*.workspaces.localhost'
chmod 600 ~/.workspaces/certs/workspaces-key.pem
```

Keep the private key out of Git and readable only by the service user. Then run:

```sh
bundle exec workspaces serve --secure
```

Without explicit settings, `--secure` serves the dashboard at
`https://workspaces.localhost:4747/workspaces` and previews at
`https://ws-<workspace-id>.workspaces.localhost:4747/`. The shortcut sets these
host/origin defaults **only in the `serve` process**. For correct URLs in separate
`create`, `show`, `start`, or `restart` invocations, export the same settings there:

```sh
export WORKSPACES_PUBLIC_ORIGIN=https://workspaces.localhost:4747
export WORKSPACES_BASE_DOMAIN=workspaces.localhost
```

Alternatively, pass both `--tls-cert PATH` and `--tls-key PATH` to `serve`, and set
`WORKSPACES_PUBLIC_ORIGIN` to an HTTPS origin and `WORKSPACES_BASE_DOMAIN` to the
matching preview domain. TLS startup fails for missing, unreadable, invalid, or
mismatched files; it does not fall back to HTTP. TLS flags apply to `serve` only.

### HTTPS behind a reverse proxy

When an ingress terminates HTTPS, keep the front door on HTTP internally. Set
`WORKSPACES_BIND=0.0.0.0` if it must listen outside the container, set
`WORKSPACES_PUBLIC_ORIGIN` to the external HTTPS dashboard origin, and set
`WORKSPACES_BASE_DOMAIN` to the domain used for preview hosts. Route both the
dashboard hostname and the wildcard preview hostnames to the front door, **preserving
the original Host header**. The configured public origin determines generated URLs
and forwarded scheme/host headers; it does not change the internal listener to TLS.

| Setting | Default | Purpose |
| --- | --- | --- |
| `WORKSPACES_REPO_ROOT` | Nearest ancestor Git checkout with `.workspaces.yml` | Trusted recipe and source repository |
| `WORKSPACES_HOME` | `~/.workspaces/<repository-path-hash>` | Per-project worktrees, state, locks, and logs |
| `WORKSPACES_BIND` | `127.0.0.1` | Front-door bind address |
| `WORKSPACES_PORT` | `4747` | Front-door listener port |
| `WORKSPACES_PUBLIC_ORIGIN` | `http://localhost:4747` | Browser-facing dashboard origin and scheme |
| `WORKSPACES_BASE_DOMAIN` | `localhost` | Preview hostname suffix |
| `WORKSPACES_SUBDOMAIN_PREFIX` | `ws-` | Prefix before the workspace ID on preview hosts |
| `WORKSPACES_REQUIRE` | none | Ruby files, separated like `PATH`, loaded by `serve` to register proxy middleware |

Keep the project root, public origin, preview domain, and storage settings consistent
across CLI and server processes. Changing the browser-facing origin requires restarting
workspace backends that need updated `WORKSPACE_URL` or `WORKSPACE_HOST` values.

## Development

Use Ruby 3.3.10. To run the standalone test suite from a source checkout, install and
use its test bundle:

```sh
BUNDLE_GEMFILE=Gemfile.test bundle install
BUNDLE_GEMFILE=Gemfile.test bundle exec rspec spec/workspaces
```

## License

MIT. See [LICENSE](LICENSE).
