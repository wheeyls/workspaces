# Managed Workspace Dashboard Design Tokens

## Scope

Workspace list/create screen and per-workspace setup/status screen. Workspace identity is independent of PR provenance.

GET is read-only. All creation and lifecycle controls submit same-origin POST forms. Workspace IDs, branches and filesystem paths wrap on narrow screens. Native labelled inputs and buttons are keyboard accessible; polling announces status without replacing form focus or making the entire log an ARIA live region.

## Visual direction

Restrained tooling UI built on the **Arb design system, Native v1** (`~/code/arb-design-system`, commit `88765ca`): a deep-teal page in the dark theme and limestone in the light one, one slightly lighter card surface with a hairline border and no shadow, a compact spacing rhythm, clear status affordances, and no decorative animation. Every text pairing is at least 4.5:1 against its surface, and `spec/workspaces/arb_design_system_spec.rb` measures each one in both themes.

Only colour changed in this migration. Type, spacing, radii and motion timing are the ones the dashboard already had, because the Arb kit defines none of them. No state, label, handler, route or permission changed.

## Tokens used

### Color

`dashboard/arb-palette.css` is the kit's `tokens/palette.css` copied unchanged (a two-line note on top says where from). It defines 28 `--arb-*` tokens per theme, selected by `data-theme` on `<html>`. **The theme follows the visitor's operating-system setting, with dark as the default**; a one-line script in the `<head>` sets it before anything paints, and a page without script stays dark. There is no theme switch, because the kit says to follow the host's existing behaviour and the dashboard had none.

`styles.css` names no colour of its own, which a spec enforces (no hex, `rgb`, `hsl`, `color-mix` or faded opacity). Its `:root` maps a short list of roles onto the palette, and everything below uses the roles or `--arb-*` directly:

| Role in `styles.css` | Arb token | Used for |
|---|---|---|
| `--bg` | `bg` | the page |
| `--bg-elevated` | `surface` | panels, the card, inputs, log blocks |
| `--arb-elevated` | `elevated` | the progress track, neutral pill fill |
| `--text`, `--muted` | `text`, `muted` | body and supporting text (the old strong, cell and placeholder greys are gone: one text colour, one muted) |
| `--border` | `border` | every edge and divider, including control edges, so controls now meet 3:1 (the old control edge was about 2:1) |
| `--accent`, `--accent-hover`, `--accent-pressed`, `--on-accent` | `accent`, `action_hover`, `action_pressed`, `on_accent` | primary buttons and links |
| `--focus` | `focus` | the focus ring |
| `--danger` / `--arb-error*`, `--arb-on-error` | `error`, `error_hover`, `error_pressed`, `on_error` | Delete, the setup error callout, the danger zone, failed steps |
| `--warning`, `--success` | `warning`, `success` | slow-progress fill, vault note, completed step icon |
| `--arb-selected-bg`, `--arb-selected-border` | `selected_bg`, `selected_border` | the chosen preset, the preset badge, the log tab you are on |
| `--arb-surface-hover`, `--arb-surface-pressed` | `surface_hover`, `surface_pressed` | hover and pressed on subtle buttons, rows, tabs |
| `--arb-disabled-*` | `disabled_bg`, `disabled_fg`, `disabled_border` | disabled buttons and fields, at full opacity |

- **Focus** is a 2px `focus` ring with a 2px gap, as the kit specifies. The gap is the outline's own offset, which is transparent and so shows the surface actually behind the control.
- **Selected** is never colour alone: the chosen preset and the current log tab carry a check mark, because the light theme's selected and pressed fills are the same colour.
- **Disabled** controls use the disabled tokens at full opacity, not a faded copy of the enabled style.
- **Status pills** pair a glyph with the word the server already sends: ready is a check on `success_bg`, error a cross on `error_bg`, interrupted an exclamation mark on `warning_bg` (a run that was cut off, not one that failed), preparing a ringed dot in `accent`. Idle, stopped and sleeping have no palette role of their own, so they are told apart by glyph and word (empty ring, filled square, half ring) in `steel` on a neutral fill. The earlier design gave each its own hue; the palette has no roles to carry that, and the guide forbids inventing near-matches.
- **Motion**: the dots that pulsed forever (next to the current step, and on a busy pill) are gone, because a pulse that never stops says "working" whether or not anything is. The bar, the step name and its number carry progress. The step status icon no longer pulses either.
- **Forced colors**: shapes that carry meaning get a real border so they survive the system palette.

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
- **Workspace inventory**: a centered column up to 1180px. Rows are ordered by last startup, newest first; workspaces that never started (or whose start time cannot be read) come last, and ties fall back to the id so the list never shuffles between loads. Moments are compared as moments, not text. The page header carries "N managed worktrees · none running" (or "· K running"), counted from the data. The table sits in an `overflow-x: auto` wrapper with `min-width: 820px`, so a phone scrolls it sideways instead of cramming or hiding columns. Rows have 16px padding; workspace names are monospaced links with no underline until hover. Times read "Oct 27, 10:48", are UTC (the headers say so) and keep the full ISO value in a `title`. A missing start reads "Never" and a missing creation time "Unavailable", in the muted colour.
- **Status pill**: a glyph and one word (13px, 600, fully rounded), never colour alone. A busy workspace adds "(busy)" to the word; nothing pulses.
- **Setup progress**: names and ordered states come from repository run steps; failures are highlighted. Restart shows the background launch and later readiness commands.
- **Actions by state**: idle/stopped offers Start; active operations show progress without lifecycle buttons; failure offers Retry; ready offers Open workspace plus rebuild/restart/stop.
- **PR source update**: a secondary Update from PR form only for PR-sourced workspaces; it fetches the latest PR head, fast-forwards the checkout, and preserves local edits without rebuilding or restarting. A persistent result message explains when rebuild is needed or when a retained stash needs manual recovery.
- **Failure panel**: prominently above the log, with escaped error details and a matching retry action.
- **PR page**: existing workspaces are primary; creating another is a collapsed secondary disclosure. Creation is primary only when none exist.
- **Workspace card**: the default page for a workspace (`/workspaces/ID`, and the same card at the visitor's own address on a preview host while the workspace is not serving). One centered card, about 26rem wide: the workspace id with a gear (an icon link to `/workspaces/ID/settings`, labelled "Settings and details"), the headline and a muted sentence, the *Preset: name* badge when the saved settings match a preset, the progress bar with its step line, elapsed time and estimate, then at most one large full-width action. Idle shows a single start form with a preset select; ready shows **Open workspace**; asleep or stopped shows **Wake workspace** or **Start workspace**; failure shows the shortened error with a link to the full log. The card never opens the preview by itself.
  - **Shared with the settings page**: the card reuses the page's element ids and `app.js`, so polling needs no second script. `app.js` tolerates the elements the card lacks (actions, steps, logs, environment).
  - **On a preview host** (`data-base="/__workspaces"`, `data-reload-when-ready="true"`): the card is served from the workspace's own origin, so it is the smallest surface that can work. It polls `/__workspaces/status`, posts only to `/__workspaces/start|prepare|restart|resume`, shows a fixed failure line instead of error text, and reloads the current page once when the workspace is ready. Everything else (settings, environment, secrets, logs, removal) stays on the shared dashboard origin behind its same-origin check.
  - **Settings page**: the full page described below, with a *Back to workspace* link. It is where Update from PR, keep-awake, rebuild, restart, stop, environment editing and deletion live.
- **Three layers** (the settings page; the card shows only the lead): the workspace page leads with the friendly, the deliberate, then the technical. Which layers are shown depends on lifecycle state, driven by `Presentation::STATES`. They are plain sections, never folded: the card at `/workspaces/ID` is what keeps the details out of the way, so the settings page has nothing to hide.
  1. **Lead** (always visible): a plain-language headline, one sentence, and at most one primary action (a large button). The setup steps never appear here.
  2. **Settings** (a section headed *Change settings*, with a *Preset: name* badge beside the heading whenever the saved settings exactly match a preset, or *Choose what to preview* on a brand new workspace): presets first, as buttons, then the environment variables. The one submit button names what it does (Start workspace, Save & restart, Save & start, Save & retry).
  3. **Technical details** (a section): setup step logs with timings, the web server log, workspace controls (rebuild, restart, stop, update from PR), preview URL, branch and path, and the Danger Zone. It is shown whenever the state has something to show (while setup runs, after a failure, and once ready), so a cause is never hidden.
- **Lead by state**:
  - `idle`: "Let's get your workspace running", with the settings shown and *Start workspace* in the form.
  - `busy`: "Setting things up…", with the current step as a quiet line and the elapsed time. Technical details are shown so progress and the log can be watched.
  - `ready`: "Your workspace is ready" with a large **Open workspace** button. Settings and technical details sit below it.
  - `stopped`: "Your workspace is paused" with a large **Start workspace** button.
  - `error`/`interrupted`: a plain "Something didn't go to plan" with a large **Retry failed step** button (**Continue setup** after an interruption) that names the step in the summary, a subtle **Re-run all steps** beside it, the error shown, and technical details shown. When the recorded steps cannot be resumed, the single **Retry** of the earlier design is shown instead.
  - `unknown`: a minimal view with technical details shown.
- **Section visibility**: the server renders which sections the state shows, and the polling script reveals or hides them as the state changes. Sections that are not meaningful in a state are hidden, never shown disabled. Nothing on the page folds except the per-step log rows below, so polling never opens or closes anything the reader is looking at.
- **Per-step re-run controls**: inside each step's accordion, small subtle **Re-run this step** and **Re-run from here** forms aimed at `/workspaces/ID/resume?only=KEY` and `?from=KEY`. The server decides which appear (`presentation.resume.step_modes`), so the page never offers something that would be refused; they are hidden while a run is in progress and are disabled with the other controls while busy.
- **Sleeping**: a workspace asleep is its own state (`sleeping`), distinct from stopped and failed. The lead reads "Your workspace is asleep", says files and data are kept and that opening the preview wakes it, and offers one **Wake workspace** button. A ready workspace shows one muted line, "Sleeps after N min without preview traffic", or "Kept awake" when exempt. **Keep awake** / **Allow sleep** are subtle workspace controls. A waking workspace is simply busy.
- **Environment rows**: the settings form is a list of rows, each a name input, a value input and a **Secret** checkbox, with **Add variable** and a per-row **Remove** (both revealed by script; without it the server-rendered rows still save). Rows post as `env[N][name|value|secret]`. A secret row's value is a password field that is never pre-filled; a stored secret shows its name, the placeholder "Stored. Enter a new value to replace it", and a locked checked checkbox (a hidden field carries it), so it can only be replaced or removed, not exposed. Ticking Secret on a new row switches its value to a password field. Presets replace only the visible rows and are matched against visible rows alone. A note under the rows shows why secrets are unavailable when the vault is not usable, and a line explains that secrets are write-only.
- **Action buttons**: start, prepare/rebuild, restart server, stop server, retry failed step, and refresh
- **Open workspace**: success-styled link available when the server is ready
- **Lifecycle controls**: hidden while busy (see state machine); helper text distinguishes rebuilding from server-only restart
- **Step logs (GitHub Actions style)**: setup output is split by recipe step. Each step is a `<details>` row with a status icon (ring, pulsing ring, check or cross), its name, how long it took and a chevron; opening it shows only that step's output. A step that is running or has failed starts open and a completed or waiting one starts closed. The script updates rows in place by step id, and applies the open preference only when a step's state changes, so a row the reader toggled is never reopened or reclosed and what they are reading is never rebuilt.
  - **Capture**: `StepLog` wraps the combined log. Every line still goes to the combined `<id>.setup.log`; while a step is current the same scrubbed text also goes to `logs/<id>.steps/<step-id>.log`. A step's file is truncated when it begins, the files are cleared when a run starts, and a failing step records its error message in its own file.
  - **Read**: the snapshot carries `step_logs` (the tail of each step that has output, with a `truncated` flag) for the setup view only, and `backend_log_available`.
  - **Tabs**: *Setup steps* (the step rows) and *Web server log*. The server tab appears only once the backend log has content. Switching tabs reloads the page, and the links end in `#log-title` so the reader lands back on the log rather than the top of the page. The combined log stays reachable as a final, collapsed *Full setup log* row, which also covers workspaces set up before step files existed.
- **Build progress**: while a build is being prepared the lead is the headline, a progress bar (`role="progressbar"` with a text value), and one line saying *Step n of m · name*, the percentage, the elapsed time and an estimate. The server computes the numbers from the step states and per-step averages frozen when the run began (`Progress`), and the script only draws them; the elapsed clock ticks locally between polls. A step well past its usual time turns the bar amber and the estimate reads "Taking longer than usual". Without history there is no time estimate. The bar is hidden when no build is running.
- **Build history**: every finished run is appended to `build-history.jsonl` (`BuildHistory`). Estimates are the mean of a step's last 10 successful completions; failed runs are recorded but never counted. Recording is best-effort and cannot fail a build.
- **Bounded log panel**: monospace text, fixed max height, manual-scroll-safe updates
- **Log source switcher**: two native links inside one log panel (Setup steps, Web server log), with current selection announced through `aria-current`; only the selected view is loaded and refreshed. Setup steps is the default.
- **Preview destination**: a small muted URL in Technical details, visible before readiness; the large Open workspace button is reserved for ready servers.
- **Editable environment**: labelled monospace multiline `NAME=value` control for non-secret recipe defaults and added workspace settings; busy state disables the fieldset and save button, values are escaped in HTML, other legacy overrides remain hidden. Omitted default names revert to recipe defaults; omitted added names are unset.
- **Environment presets (JS-enhanced)**: optional preset selector is hidden by default and revealed only when JavaScript is active and presets exist. Selecting a preset replaces the entire draft editor content and announces unsaved state without submitting. Draft edits remain local until Save & restart.
- **Danger Zone**: isolated section on the detail page with explicit loss-of-uncommitted-and-untracked-work copy, an exact-workspace-ID confirmation field, and a destructive action. Deletion remains possible without JavaScript, is disabled while setup is busy, and never appears as a list-row action.
- **Workspace favicon**: a small two-pane workspace mark served by the dashboard host. **Not migrated to the Arb mark yet**: blue for localhost and gold for hosted origins is how a browser tab tells the environments apart, and the Arb guide forbids recolouring or badging its mark, so swapping it would drop that signal. This needs a decision, not a guess. The icon contains no workspace-specific data.

## Accessibility constraints

- Semantic sections/headings for all regions
- Focus-visible outlines on actionable controls: a 2px ring with a 2px gap, in the palette's focus colour
- Selected controls carry a check mark as well as a fill; statuses carry a glyph as well as a colour
- Forced-colors and reduced-motion are handled
- `aria-live` limited to phase-change and connection warnings (not full log stream)
- No-JS refresh path always available

## Responsive behavior

- Single-column layout with intrinsic grid sections; panel padding is 28px and compresses to 20px at <=640px
- The workspace table is the one deliberate exception to "no horizontal scrolling": it keeps its columns and scrolls inside its own wrapper, rather than stacking rows and hiding the dates
- Everything else fits a 375px viewport
