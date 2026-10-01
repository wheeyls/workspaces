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
    root.querySelectorAll('.workspace-actions button').forEach((button) => {
      button.disabled = nextBusy;
    });
    if (window.WorkspaceEnvironment)
      window.WorkspaceEnvironment.toggleBusy(nextBusy);
    node('remove-form').querySelectorAll('input, button').forEach((control) => {
      control.disabled = nextBusy;
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
    outcome.textContent = step.state;
    item.append(bullet, label, outcome);
    return item;
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
    busy = view.busy;
    toggleBusyState(busy);
    started = Date.parse(data.prepare_started_at);
    completed = Date.parse(data.completed_at);
    renderStatus(view);
    node('message').textContent = data.message || '';
    node('source-update-message').textContent = data.source_update_message || '';
    node('progress').replaceChildren(...view.steps.map(renderStep));
    renderActions(view.actions);
    updateLog(data);
  }

  function renderStatus(view) {
    node('status').textContent = view.title;
    node('activity').hidden = !view.busy;
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
