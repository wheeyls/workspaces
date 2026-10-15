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

  function renderStep(step) {
    const item = document.createElement('li');
    item.className = 'step';
    item.dataset.stepState = step.state;
    if (step.state === 'active') item.setAttribute('aria-current', 'step');
    const bullet = document.createElement('span');
    bullet.className = 'step-bullet';
    bullet.setAttribute('aria-hidden', 'true');
    const label = document.createElement('span');
    label.textContent = step.label;
    const outcome = document.createElement('span');
    outcome.className = 'step-outcome';
    outcome.textContent = stepOutcome(step);
    item.append(bullet, label, outcome);
    return item;
  }

  function stepOutcome(step) {
    const state = step.state;
    const rawDuration = step.duration_seconds;
    if (typeof rawDuration !== 'number') return state;
    const duration = rawDuration;
    if (
      (state === 'complete' || state === 'failed') &&
      Number.isFinite(duration) &&
      duration >= 0
    )
      return state + ' · ' + duration.toFixed(3) + 's';
    return state;
  }

  function updateLog(data) {
    if (data.log_source !== selectedLog) return;
    const log = node('log');
    const bottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 18;
    log.textContent = data.log_tail || '';
    if (bottom) log.scrollTop = log.scrollHeight;
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
    node('progress').replaceChildren(...view.steps.map(renderStep));
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
      if (Number.isFinite(seconds))
        node('elapsed').textContent =
          Math.floor(seconds / 60) + 'm ' + (seconds % 60) + 's';
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
