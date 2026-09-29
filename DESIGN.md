# Managed Workspace Dashboard Design Tokens

## Scope

Workspace list/create screen and per-workspace setup/status screen. Workspace identity is independent of PR provenance.

GET is read-only. All creation and lifecycle controls submit same-origin POST forms. No source-reset or cleanup button exists. Workspace IDs, branches and filesystem paths wrap on narrow screens. Native labelled inputs and buttons are keyboard accessible; polling announces status without replacing form focus or making the entire log an ARIA live region.

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
- **Status pill**: current workspace status as text
- **Setup progress**: names and ordered states come from repository run steps; failures are highlighted. Restart shows the background launch and later readiness commands.
- **Actions by state**: idle/stopped offers Start; active operations show progress without lifecycle buttons; failure offers Retry; ready offers Open workspace plus rebuild/restart/stop.
- **Failure panel**: prominently above the log, with escaped error details and a matching retry action.
- **PR page**: existing workspaces are primary; creating another is a collapsed secondary disclosure. Creation is primary only when none exist.
- **Action buttons**: start, prepare/rebuild, restart server, stop server, and refresh
- **Open workspace**: success-styled link available when the server is ready
- **Lifecycle controls**: disabled while busy; helper text distinguishes rebuilding from server-only restart
- **Bounded log panel**: monospace text, fixed max height, manual-scroll-safe updates

## Accessibility constraints

- Semantic sections/headings for all regions
- Focus-visible outlines on actionable controls
- `aria-live` limited to phase-change and connection warnings (not full log stream)
- No-JS refresh path always available

## Responsive behavior

- Single-column layout with intrinsic grid sections
- Panel padding compresses at <=640px
- No horizontal scrolling expected at 375px viewport
