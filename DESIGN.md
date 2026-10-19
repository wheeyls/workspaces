# Managed Workspace Dashboard Design Tokens

## Scope

Workspace list/create screen and per-workspace setup/status screen. Workspace identity is independent of PR provenance.

GET is read-only. All creation and lifecycle controls submit same-origin POST forms. Workspace IDs, branches and filesystem paths wrap on narrow screens. Native labelled inputs and buttons are keyboard accessible; polling announces status without replacing form focus or making the entire log an ARIA live region.

## Visual direction

Restrained tooling UI: dark elevated panels, compact spacing rhythm, clear status affordances, and no decorative animation.

## Tokens used

### Color

- `--bg`: shell background
- `--bg-elevated`: panel surface
- `--border`: panel/control borders
- `--text`: primary text
- `--muted`: secondary/supporting text
- `--accent`: active status and primary action
- `--success`: completed/ready states
- `--danger`: failed/error states
- `--warning`: retry/connection warning text

### Radius and depth

- `--radius`: 12px panel corners
- `--shadow`: single elevated panel shadow

### Spacing scale

- `--space-1` to `--space-8` (4px base multiples)

### Typography

- System sans stack for body/content
- System mono stack for logs/error text

## Component primitives

- **Creation form**: labelled branch, PR, and new-branch inputs with a primary create action
- **Workspace inventory**: one row per managed workspace with a status distinct from backend running state, creation and last startup times, and a link to its detail page. Unknown timestamps are shown as unavailable, not inferred from recent setup.
- **Status pill**: current workspace status as text
- **Setup progress**: names and ordered states come from repository run steps; failures are highlighted. Restart shows the background launch and later readiness commands.
- **Actions by state**: idle/stopped offers Start; active operations show progress without lifecycle buttons; failure offers Retry; ready offers Open workspace plus rebuild/restart/stop.
- **PR source update**: a secondary Update from PR form only for PR-sourced workspaces; it fetches the latest PR head, fast-forwards the checkout, and preserves local edits without rebuilding or restarting. A persistent result message explains when rebuild is needed or when a retained stash needs manual recovery.
- **Failure panel**: prominently above the log, with escaped error details and a matching retry action.
- **PR page**: existing workspaces are primary; creating another is a collapsed secondary disclosure. Creation is primary only when none exist.
- **Three layers**: the workspace page leads with the friendly, the deliberate, then the technical. Each layer is shown or collapsed by lifecycle state, driven by `Presentation::STATES`:
  1. **Lead** (always visible): a plain-language headline, one sentence, and at most one primary action (a large button). The setup steps never appear here.
  2. **Settings** (a `<details>` titled *Change settings*, with a *Preset: name* badge in its header whenever the saved settings exactly match a preset, so the choice is visible while it is closed, or *Choose what to preview* on a brand new workspace): presets first, as buttons, then the environment variables. The one submit button names what it does (Start workspace, Save & restart, Save & start, Save & retry). It starts open only for a new workspace.
  3. **Technical details** (one `<details>`): setup step logs with timings, the web server log, workspace controls (rebuild, restart, stop, update from PR), preview URL, branch and path, and the Danger Zone. It starts collapsed, and opens by itself while setup runs or after a failure so a cause is never hidden.
- **Lead by state**:
  - `idle`: "Let's get your workspace running", with the settings open and *Start workspace* in the form.
  - `busy`: "Setting things up…", with the current step as a quiet line and the elapsed time. Technical details open so progress and the log can be watched.
  - `ready`: "Your workspace is ready" with a large **Open workspace** button. Everything else is collapsed.
  - `stopped`: "Your workspace is paused" with a large **Start workspace** button.
  - `error`/`interrupted`: a plain "Something didn't go to plan" with a large **Retry** button, the error shown, and technical details open.
  - `unknown`: a minimal view with technical details open.
- **Disclosure behavior**: the server renders the initial open state and the polling script re-applies it from `presentation.open`, but only when the state changes. A section the user opened or closed is left alone on later polls. Sections that are not meaningful in a state are hidden, never shown disabled.
- **Action buttons**: start, prepare/rebuild, restart server, stop server, and refresh
- **Open workspace**: success-styled link available when the server is ready
- **Lifecycle controls**: hidden while busy (see state machine); helper text distinguishes rebuilding from server-only restart
- **Step logs (GitHub Actions style)**: setup output is split by recipe step. Each step is a `<details>` row with a status icon (ring, pulsing ring, check or cross), its name, how long it took and a chevron; opening it shows only that step's output. A step that is running or has failed starts open and a completed or waiting one starts closed. The script updates rows in place by step id, and applies the open preference only when a step's state changes, so a row the reader toggled is never reopened or reclosed and what they are reading is never rebuilt.
  - **Capture**: `StepLog` wraps the combined log. Every line still goes to the combined `<id>.setup.log`; while a step is current the same scrubbed text also goes to `logs/<id>.steps/<step-id>.log`. A step's file is truncated when it begins, the files are cleared when a run starts, and a failing step records its error message in its own file.
  - **Read**: the snapshot carries `step_logs` (the tail of each step that has output, with a `truncated` flag) for the setup view only, and `backend_log_available`.
  - **Tabs**: *Setup steps* (the accordions) and *Web server log*. The server tab appears only once the backend log has content. The combined log stays reachable as a final, collapsed *Full setup log* row, which also covers workspaces set up before step files existed.
- **Bounded log panel**: monospace text, fixed max height, manual-scroll-safe updates
- **Log source switcher**: two native links inside one log panel (Setup steps, Web server log), with current selection announced through `aria-current`; only the selected view is loaded and refreshed. Setup steps is the default.
- **Preview destination**: a small muted URL in Technical details, visible before readiness; the large Open workspace button is reserved for ready servers.
- **Editable environment**: labelled monospace multiline `NAME=value` control for non-secret recipe defaults and added workspace settings; busy state disables the fieldset and save button, values are escaped in HTML, other legacy overrides remain hidden. Omitted default names revert to recipe defaults; omitted added names are unset.
- **Environment presets (JS-enhanced)**: optional preset selector is hidden by default and revealed only when JavaScript is active and presets exist. Selecting a preset replaces the entire draft editor content and announces unsaved state without submitting. Draft edits remain local until Save & restart.
- **Danger Zone**: isolated section on the detail page with explicit loss-of-uncommitted-and-untracked-work copy, an exact-workspace-ID confirmation field, and a destructive action. Deletion remains possible without JavaScript, is disabled while setup is busy, and never appears as a list-row action.
- **Workspace favicon**: a small two-pane workspace mark served by the dashboard host. Use `--accent` blue for localhost and `--warning` gold for hosted origins so browser tabs signal the environment without relying on page text. The icon contains no workspace-specific data.

## Accessibility constraints

- Semantic sections/headings for all regions
- Focus-visible outlines on actionable controls
- `aria-live` limited to phase-change and connection warnings (not full log stream)
- No-JS refresh path always available

## Responsive behavior

- Single-column layout with intrinsic grid sections
- Panel padding compresses at <=640px
- No horizontal scrolling expected at 375px viewport
