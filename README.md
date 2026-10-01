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

The front door is not an authentication boundary. Its host and same-origin checks
protect routing and POST actions, but a publicly reachable instance still needs
access control such as VPN or SSO. Do not expose workspace backend ports directly.

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
