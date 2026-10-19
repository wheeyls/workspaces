(function () {
  'use strict';
  const root = document.getElementById('workspace');
  if (!root) return;
  const node = (id) => document.getElementById(id);
  const base = '/workspaces/' + root.dataset.id;
  const selectedLog = new URLSearchParams(window.location.search).get('log') === 'backend'
    ? 'backend'
    : 'setup';
  const allowedActions = ['start', 'prepare', 'restart', 'stop', 'update-pr'];
  let busy = root.dataset.busy === 'true';
  let started = Date.parse(root.dataset.started);
  let completed = Date.parse(root.dataset.completed);
  let actionsSignature = null;
  function toggleBusyState(nextBusy) {
    busy = !!nextBusy;
    root.querySelectorAll('.workspace-actions button, .lead__action button').forEach((button) => {
      button.disabled = busy;
    });
    if (window.WorkspaceEnvironment)
      window.WorkspaceEnvironment.toggleBusy(busy);
    const removeForm = node('remove-form');
    if (removeForm)
      removeForm.querySelectorAll('input, button').forEach((control) => {
        control.disabled = busy;
      });
  }

  function renderActions(actions) {
    const signature = JSON.stringify(actions);
    if (signature === actionsSignature) return;
    actionsSignature = signature;
    node('actions').replaceChildren();
    actions.forEach((action) => {
      if (!allowedActions.includes(action.key)) return;
      const form = document.createElement('form');
      form.method = 'post';
      form.action = base + '/' + action.key;
      const button = document.createElement('button');
      button.className =
        'button ' + (action.primary ? 'button--primary' : 'button--subtle');
      button.textContent = action.label;
      form.append(button);
      node('actions').append(form);
    });
    toggleBusyState(busy);
  }

  // Each recipe step is a disclosure element. The server renders the first paint; after that the
  // poll updates these nodes in place, keyed by step id, so nothing the user is reading
  // is rebuilt. A step opens by itself when it starts running or fails, and closes when it
  // completes, but only on a state change, and never after the user toggled it by hand.
  const userToggled = new Set();
  const stepState = {};

  function ensureStep(container, step, before) {
    const existing = container.querySelector('[data-step-log="' + step.key + '"]');
    if (existing) return existing;
    const details = document.createElement('details');
    details.className = 'step-log';
    details.dataset.stepLog = step.key;
    const summary = document.createElement('summary');
    const status = document.createElement('span');
    status.className = 'step-log__status';
    status.setAttribute('aria-hidden', 'true');
    const name = document.createElement('span');
    name.className = 'step-log__name';
    const outcome = document.createElement('span');
    outcome.className = 'step-log__outcome step-outcome';
    summary.append(status, name, outcome);
    const output = document.createElement('pre');
    output.tabIndex = 0;
    details.append(summary, output);
    details.addEventListener('toggle', () => {
      if (details.dataset.programmatic === 'true') return;
      userToggled.add(step.key);
    });
    container.insertBefore(details, before || null);
    return details;
  }

  function renderSteps(view, stepLogs) {
    const container = node('steps');
    if (!container) return;
    const steps = view.steps || [];
    const full = node('full-log');
    const keep = new Set(steps.map((step) => step.key).concat(['full']));
    container.querySelectorAll('[data-step-log]').forEach((element) => {
      if (!keep.has(element.dataset.stepLog)) container.removeChild(element);
    });
    renderFullLogOutcome(view);
    steps.forEach((step) => {
      const details = ensureStep(container, step, full);
      details.dataset.stepState = step.state;
      if (step.state === 'active') details.setAttribute('aria-current', 'step');
      else details.removeAttribute('aria-current');
      const summary = details.querySelector('summary');
      const parts = summary.children;
      parts[1].textContent = step.label;
      parts[2].textContent = stepOutcome(step);
      const output = details.querySelector('pre');
      output.setAttribute('aria-label', step.label + ' output');
      const entry = stepLogs && stepLogs[step.key];
      if (entry && output.textContent !== entry.text) writeLog(output, entry.text);
      applyStepOpenState(details, step);
    });
  }

  // The Full setup log row reads "in progress" while running, then how the run ended and how
  // long it took. Without a recorded total it keeps its plain label.
  function renderFullLogOutcome(view) {
    const label = node('full-log-outcome');
    if (!label) return;
    const total = view.total;
    const text = total && formatDuration(total.seconds);
    label.textContent = view.busy
      ? 'in progress'
      : text
        ? total.state + ' · ' + text
        : 'everything, in order';
  }

  function applyStepOpenState(details, step) {
    const previous = stepState[step.key];
    stepState[step.key] = step.state;
    if (previous === step.state || userToggled.has(step.key)) return;
    const shouldOpen = step.state === 'active' || step.state === 'failed';
    if (details.open === shouldOpen) return;
    details.dataset.programmatic = 'true';
    details.open = shouldOpen;
    // The toggle event fires asynchronously; clear the guard after it has been delivered.
    setTimeout(() => { details.dataset.programmatic = 'false'; }, 0);
  }

  // Writing a log must not yank a reader who scrolled up; follow the tail only if already there.
  function writeLog(pre, text) {
    const atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 18;
    pre.textContent = text || '';
    if (atBottom) pre.scrollTop = pre.scrollHeight;
  }

  // Durations read the way people say them: 0.5s, 12.3s, 1m 10s, 1h 5m 3s. This mirrors
  // Workspaces::DurationFormat in Ruby; a spec runs both over the same inputs.
  function formatDuration(seconds) {
    if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds < 0) return null;
    if (seconds < 60) {
      const rounded = Math.round(seconds * 10) / 10;
      if (rounded >= 60) return '1m 0s';
      return rounded + 's';
    }
    const whole = Math.round(seconds);
    const hours = Math.floor(whole / 3600);
    const minutes = Math.floor((whole % 3600) / 60);
    const secs = whole % 60;
    return hours > 0 ? hours + 'h ' + minutes + 'm ' + secs + 's' : minutes + 'm ' + secs + 's';
  }

  function stepOutcome(step) {
    const state = step.state;
    if (state !== 'complete' && state !== 'failed') return state;
    const text = formatDuration(step.duration_seconds);
    return text ? state + ' · ' + text : state;
  }

  function updateLog(data) {
    if (data.log_source !== selectedLog) return;
    const tab = node('backend-tab');
    if (tab && data.backend_log_available) tab.hidden = false;
    if (selectedLog === 'backend') writeLog(node('log'), data.log_tail);
    else {
      const full = node('full-log');
      if (full) writeLog(full.querySelector('pre'), data.log_tail);
    }
    node('updated').textContent = data.updated_at || '';
  }

  function update(data) {
    const view = data.presentation;
    if (!view)
      throw new Error('Restart the front door to load the updated status API.');
    toggleBusyState(view.busy);
    started = Date.parse(data.prepare_started_at);
    completed = Date.parse(data.completed_at);
    renderStatus(view);
    renderSections(view);
    if (node('message')) node('message').textContent = data.message || '';
    node('source-update-message').textContent = data.source_update_message || '';
    renderSteps(view, data.step_logs);
    renderActions(view.actions);
    if (window.WorkspaceEnvironment)
      window.WorkspaceEnvironment.syncFromSnapshot(data);
    updateLog(data);
  }

  function renderSections(view) {
    const sections = view.sections || {};
    root.querySelectorAll('[data-section]').forEach((element) => {
      element.hidden = !sections[element.dataset.section];
    });
    renderLead(view);
    applyDisclosureState(view);
    if (window.WorkspaceEnvironment)
      window.WorkspaceEnvironment.setSubmitLabel(view.environment_submit);
  }

  function renderLead(view) {
    node('status').textContent = view.headline || view.title;
    node('summary').textContent = view.summary || '';
    const subtitle = node('subtitle');
    const activity = node('activity');
    if (subtitle) {
      const text = view.subtitle || '';
      subtitle.hidden = !text;
      // The text has its own element, so it can be set whether or not the server rendered any.
      const target = node('subtitle-text');
      if (target) target.textContent = text;
    }
    if (activity) activity.hidden = !view.busy;
    const title = node('environment-title');
    if (title && view.environment_title) title.textContent = view.environment_title;
    const badge = node('environment-preset-badge');
    if (badge) {
      badge.hidden = !view.current_preset;
      badge.textContent = view.current_preset ? 'Preset: ' + view.current_preset : '';
    }
    renderLeadAction(view.lead_action);
  }

  // The lead action is a lifecycle post (start/retry) or, when ready, the preview link
  // rendered separately as #preview. Rebuild only when it actually changes.
  let leadSignature = null;
  function renderLeadAction(action) {
    const holder = node('lead-action');
    if (!holder) return;
    const signature = JSON.stringify(action || null);
    if (signature === leadSignature) return;
    leadSignature = signature;
    holder.replaceChildren();
    if (!action || action.kind !== 'post' || !allowedActions.includes(action.key)) return;
    const form = document.createElement('form');
    form.method = 'post';
    form.action = base + '/' + action.key;
    const button = document.createElement('button');
    button.className = 'button button--primary button--large';
    button.textContent = action.label;
    form.append(button);
    holder.append(form);
    toggleBusyState(busy);
  }

  // A disclosure opens by itself when its state says so (a failure must never be hidden,
  // a fresh workspace needs its settings), but we never close one the user opened, and
  // we only apply the state's preference when the state changes, not on every poll.
  let lastDisclosureState = root.dataset.disclosureState || null;
  function applyDisclosureState(view) {
    if (view.state === lastDisclosureState) return;
    lastDisclosureState = view.state;
    const open = view.open || {};
    [['environment-disclosure', open.environment], ['technical-disclosure', open.technical]].forEach(
      ([id, shouldOpen]) => {
        const element = node(id);
        if (element) element.open = !!shouldOpen;
      }
    );
  }

  function renderStatus(view) {
    node('preview').hidden = !view.ready;
    node('error').textContent = view.error || '';
    node('error-panel').hidden = !view.error;
    if (window.WorkspaceEnvironment)
      window.WorkspaceEnvironment.updateStatus(view.busy);
  }

  async function poll() {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    try {
      const response = await fetch(base + '/status?log=' + selectedLog, {
        credentials: 'same-origin',
        signal: controller.signal
      });
      if (!response.ok)
        throw new Error('Status unavailable. Retrying automatically.');
      update(await response.json());
      node('connection').textContent = '';
    } catch (error) {
      node('connection').textContent = error.message;
    } finally {
      clearTimeout(timeout);
      setTimeout(poll, busy || selectedLog === 'backend' ? 2000 : 10000);
    }
  }

  function tick() {
    if (Number.isFinite(started)) {
      const end = busy ? Date.now() : completed;
      const seconds = Math.max(0, Math.floor((end - started) / 1000));
      // The running clock counts whole seconds, so format it as one (no decimals).
      if (Number.isFinite(seconds)) node('elapsed').textContent = formatDuration(seconds);
    }
    setTimeout(tick, 1000);
  }

  root.addEventListener('submit', (event) => {
    if (event.target.id !== 'environment-form' && event.target.id !== 'remove-form')
      toggleBusyState(true);
    node('connection').textContent = 'Submitting…';
  });

  toggleBusyState(busy);
  tick();
  setTimeout(poll, 1000);
})();
