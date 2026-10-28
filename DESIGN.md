# Managed Workspace Dashboard Design Tokens

## Scope

Workspace list/create screen and per-workspace setup/status screen. Workspace identity is independent of PR provenance.

GET is read-only. All creation and lifecycle controls submit same-origin POST forms. Workspace IDs, branches and filesystem paths wrap on narrow screens. Native labelled inputs and buttons are keyboard accessible; polling announces status without replacing form focus or making the entire log an ARIA live region.

## Visual direction

Restrained tooling UI: a near-black page, one slightly lighter card surface with a hairline border and no shadow, a compact spacing rhythm, clear status affordances, and no decorative animation. Every text pairing is at least 4.5:1 against its surface.

## Tokens used

### Color

- `--bg` `#0b0f17`: page. `--bg-elevated` `#141a26`: card surface. `--border` `#2a3447`: card edge. `--divider` `#252e41`: row dividers. `--border-strong` `#3f4b63`: the table header rule.
- `--control-border`: the edge of inputs, outline buttons and tabs. Currently `#3f4b63`, about 2:1 against the card. WCAG 1.4.11 asks 3:1 for a control's boundary, so this is a known shortfall, kept to match the design handoff; `#5b6b8a` or lighter reaches 3:1. It is one token, so changing it is a one-line edit.
- Text: `--text-strong` `#f8fafc` (headings, workspace names, input values), `--text` `#e2e8f0` (body), `--text-cell` `#cbd5e1` (table cells, logs), `--muted` `#a8b3c7` (secondary), `--placeholder` `#8a97ad`.
- `--accent` `#6fa8ff` with `--on-accent` `#06101f` text on buttons; `--accent-hover` `#8dbbff` for link and button hover. `--success`, `--danger` and `--warning` are unchanged.
- **Status pills** take three custom properties, `--pill-bg`, `--pill-text` and `--pill-dot`, set per `data-status`. Sleeping indigo, idle amber and stopped red come from the handoff. Ready green, preparing cyan, error deeper red and interrupted orange were chosen to the same contrast (text 8:1 or better, dot 3:1 or better). Any other status gets the neutral slate pair.

### Radius and depth

- `--radius`: 12px panel corners. `--radius-control`: 8px for inputs, buttons and tabs. `--control-height`: 44px.
- `--shadow`: none. Panels are separated by their border alone.

### Spacing scale

- `--space-1` to `--space-8` (4px base multiples)

### Typography

- Interface: Inter (`--font-sans`) at 15px body, 14px labels at 600, h1 32px at 700, panel h2 20px at 600, table column headers 12px at 600 uppercase with 0.06em tracking.
- Workspace names, input values and logs: JetBrains Mono (`--font-mono`), 14px. Both stacks fall back to system fonts, because nothing is loaded from the network.
- Timestamps use `font-variant-numeric: tabular-nums`.

## Component primitives

- **Creation form**: four labelled fields in one wrapping row (`flex: 1 1 220px`, 16px gap), each with a real `<label for>`, then a `type="submit"` button on its own line.
- **Workspace inventory**: a centered column up to 1180px. The page header carries "N managed worktrees · none running" (or "· K running"), counted from the data. The table sits in an `overflow-x: auto` wrapper with `min-width: 820px`, so a phone scrolls it sideways instead of cramming or hiding columns. Rows have 16px padding; workspace names are monospaced links with no underline until hover. Times read "Oct 27, 10:48", are UTC (the headers say so) and keep the full ISO value in a `title`. A missing start reads "Never" and a missing creation time "Unavailable", in the muted colour.
- **Status pill**: a dot and one word (13px, 600, fully rounded), never colour alone. A busy workspace adds "(busy)" and pulses its dot, which stops under reduced motion.
- **Setup progress**: names and ordered states come from repository run steps; failures are highlighted. Restart shows the background launch and later readiness commands.
- **Actions by state**: idle/stopped offers Start; active operations show progress without lifecycle buttons; failure offers Retry; ready offers Open workspace plus rebuild/restart/stop.
- **PR source update**: a secondary Update from PR form only for PR-sourced workspaces; it fetches the latest PR head, fast-forwards the checkout, and preserves local edits without rebuilding or restarting. A persistent result message explains when rebuild is needed or when a retained stash needs manual recovery.
- **Failure panel**: prominently above the log, with escaped error details and a matching retry action.
- **PR page**: existing workspaces are primary; creating another is a collapsed secondary disclosure. Creation is primary only when none exist.
- **Workspace card**: the default page for a workspace (`/workspaces/ID`, and the same card at the visitor's own address on a preview host while the workspace is not serving). One centered card, about 26rem wide: the workspace id with a gear (an icon link to `/workspaces/ID/settings`, labelled "Settings and details"), the headline and a muted sentence, the *Preset: name* badge when the saved settings match a preset, the progress bar with its step line, elapsed time and estimate, then at most one large full-width action. Idle shows a single start form with a preset select; ready shows **Open workspace**; asleep or stopped shows **Wake workspace** or **Start workspace**; failure shows the shortened error with a link to the full log. The card never opens the preview by itself.
  - **Shared with the settings page**: the card reuses the page's element ids and `app.js`, so polling needs no second script. `app.js` tolerates the elements the card lacks (actions, steps, logs, environment).
  - **On a preview host** (`data-base="/__workspaces"`, `data-reload-when-ready="true"`): the card is served from the workspace's own origin, so it is the smallest surface that can work. It polls `/__workspaces/status`, posts only to `/__workspaces/start|prepare|restart|resume`, shows a fixed failure line instead of error text, and reloads the current page once when the workspace is ready. Everything else (settings, environment, secrets, logs, removal) stays on the shared dashboard origin behind its same-origin check.
  - **Settings page**: the full page described below, with a *Back to workspace* link. It is where Update from PR, keep-awake, rebuild, restart, stop, environment editing and deletion live.
- **Three layers** (the settings page; the card shows only the lead): the workspace page leads with the friendly, the deliberate, then the technical. Each layer is shown or collapsed by lifecycle state, driven by `Presentation::STATES`:
  1. **Lead** (always visible): a plain-language headline, one sentence, and at most one primary action (a large button). The setup steps never appear here.
  2. **Settings** (a `<details>` titled *Change settings*, with a *Preset: name* badge in its header whenever the saved settings exactly match a preset, so the choice is visible while it is closed, or *Choose what to preview* on a brand new workspace): presets first, as buttons, then the environment variables. The one submit button names what it does (Start workspace, Save & restart, Save & start, Save & retry). It starts open only for a new workspace.
  3. **Technical details** (one `<details>`): setup step logs with timings, the web server log, workspace controls (rebuild, restart, stop, update from PR), preview URL, branch and path, and the Danger Zone. It starts collapsed, and opens by itself while setup runs or after a failure so a cause is never hidden.
- **Lead by state**:
  - `idle`: "Let's get your workspace running", with the settings open and *Start workspace* in the form.
  - `busy`: "Setting things up…", with the current step as a quiet line and the elapsed time. Technical details open so progress and the log can be watched.
  - `ready`: "Your workspace is ready" with a large **Open workspace** button. Everything else is collapsed.
  - `stopped`: "Your workspace is paused" with a large **Start workspace** button.
  - `error`/`interrupted`: a plain "Something didn't go to plan" with a large **Retry failed step** button (**Continue setup** after an interruption) that names the step in the summary, a subtle **Re-run all steps** beside it, the error shown, and technical details open. When the recorded steps cannot be resumed, the single **Retry** of the earlier design is shown instead.
  - `unknown`: a minimal view with technical details open.
- **Disclosure behavior**: the server renders the initial open state and the polling script re-applies it from `presentation.open`, but only when the state changes. A section the user opened or closed is left alone on later polls. Sections that are not meaningful in a state are hidden, never shown disabled.
- **Per-step re-run controls**: inside each step's accordion, small subtle **Re-run this step** and **Re-run from here** forms aimed at `/workspaces/ID/resume?only=KEY` and `?from=KEY`. The server decides which appear (`presentation.resume.step_modes`), so the page never offers something that would be refused; they are hidden while a run is in progress and are disabled with the other controls while busy.
- **Sleeping**: a workspace asleep is its own state (`sleeping`), distinct from stopped and failed. The lead reads "Your workspace is asleep", says files and data are kept and that opening the preview wakes it, and offers one **Wake workspace** button. A ready workspace shows one muted line, "Sleeps after N min without preview traffic", or "Kept awake" when exempt. **Keep awake** / **Allow sleep** are subtle workspace controls. A waking workspace is simply busy.
- **Environment rows**: the settings form is a list of rows, each a name input, a value input and a **Secret** checkbox, with **Add variable** and a per-row **Remove** (both revealed by script; without it the server-rendered rows still save). Rows post as `env[N][name|value|secret]`. A secret row's value is a password field that is never pre-filled; a stored secret shows its name, the placeholder "Stored. Enter a new value to replace it", and a locked checked checkbox (a hidden field carries it), so it can only be replaced or removed, not exposed. Ticking Secret on a new row switches its value to a password field. Presets replace only the visible rows and are matched against visible rows alone. A note under the rows shows why secrets are unavailable when the vault is not usable, and a line explains that secrets are write-only.
- **Action buttons**: start, prepare/rebuild, restart server, stop server, retry failed step, and refresh
- **Open workspace**: success-styled link available when the server is ready
- **Lifecycle controls**: hidden while busy (see state machine); helper text distinguishes rebuilding from server-only restart
- **Step logs (GitHub Actions style)**: setup output is split by recipe step. Each step is a `<details>` row with a status icon (ring, pulsing ring, check or cross), its name, how long it took and a chevron; opening it shows only that step's output. A step that is running or has failed starts open and a completed or waiting one starts closed. The script updates rows in place by step id, and applies the open preference only when a step's state changes, so a row the reader toggled is never reopened or reclosed and what they are reading is never rebuilt.
  - **Capture**: `StepLog` wraps the combined log. Every line still goes to the combined `<id>.setup.log`; while a step is current the same scrubbed text also goes to `logs/<id>.steps/<step-id>.log`. A step's file is truncated when it begins, the files are cleared when a run starts, and a failing step records its error message in its own file.
  - **Read**: the snapshot carries `step_logs` (the tail of each step that has output, with a `truncated` flag) for the setup view only, and `backend_log_available`.
  - **Tabs**: *Setup steps* (the accordions) and *Web server log*. The server tab appears only once the backend log has content. The combined log stays reachable as a final, collapsed *Full setup log* row, which also covers workspaces set up before step files existed.
- **Build progress**: while a build is being prepared the lead is the headline, a progress bar (`role="progressbar"` with a text value), and one line saying *Step n of m · name*, the percentage, the elapsed time and an estimate. The server computes the numbers from the step states and per-step averages frozen when the run began (`Progress`), and the script only draws them; the elapsed clock ticks locally between polls. A step well past its usual time turns the bar amber and the estimate reads "Taking longer than usual". Without history there is no time estimate. The bar is hidden when no build is running.
- **Build history**: every finished run is appended to `build-history.jsonl` (`BuildHistory`). Estimates are the mean of a step's last 10 successful completions; failed runs are recorded but never counted. Recording is best-effort and cannot fail a build.
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

- Single-column layout with intrinsic grid sections; panel padding is 28px and compresses to 20px at <=640px
- The workspace table is the one deliberate exception to "no horizontal scrolling": it keeps its columns and scrolls inside its own wrapper, rather than stacking rows and hiding the dates
- Everything else fits a 375px viewport
