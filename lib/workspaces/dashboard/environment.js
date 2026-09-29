(function () {
  'use strict';
  const form = document.getElementById('environment-form');
  if (!form) return;
  const list = form.querySelector('[data-env-add-list]');
  const addButton = form.querySelector('[data-env-add-row]');
  const status = document.getElementById('environment-status');
  const namePattern = /^[A-Za-z_][A-Za-z0-9_]*$/;
  let rowIndex = 0;

  function toggleBusy(nextBusy) {
    form
      .querySelectorAll('fieldset, [data-env-submit], [data-env-add-row]')
      .forEach((control) => {
        control.disabled = nextBusy;
      });
  }

  function updateStatus(busy) {
    if (busy)
      status.textContent =
        'Workspace is busy. Environment updates are temporarily disabled.';
  }

  function syncReplace(toggle) {
    const input = toggle
      .closest('[data-env-existing]')
      .querySelector('[data-replace-value]');
    input.disabled = !toggle.checked;
    if (!toggle.checked) input.value = '';
  }

  function labelledInput(id, label, type) {
    const wrap = document.createElement('p');
    const caption = document.createElement('label');
    caption.className = 'env-input-label';
    caption.htmlFor = id;
    caption.textContent = label;
    const input = document.createElement('input');
    input.id = id;
    input.type = type;
    input.autocomplete = 'off';
    wrap.append(caption, input);
    return [wrap, input];
  }

  function addVariableRow() {
    const row = document.createElement('li');
    row.className = 'env-add-item';
    row.dataset.envAddRow = String(rowIndex);
    const [keyWrap, key] = labelledInput(
      'env-add-key-' + rowIndex,
      'Variable name',
      'text'
    );
    key.spellcheck = false;
    key.dataset.envNewName = 'true';
    key.pattern = '[A-Za-z_][A-Za-z0-9_]*';
    key.title =
      'Use letters, numbers, and underscores; must not start with a number.';
    const [valueWrap, value] = labelledInput(
      'env-add-value-' + rowIndex,
      'Value',
      'password'
    );
    value.dataset.envNewValue = 'true';
    rowIndex += 1;
    const fields = document.createElement('div');
    fields.className = 'env-add-grid';
    fields.append(keyWrap, valueWrap);
    const actions = document.createElement('div');
    actions.className = 'env-row-actions';
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'button button--subtle button--icon';
    remove.textContent = 'Remove';
    remove.setAttribute('aria-label', 'Remove variable row');
    remove.addEventListener('click', () => row.remove());
    actions.append(remove);
    row.append(fields, actions);
    list.append(row);
    key.focus();
  }

  function appendSetValue(row) {
    const key = row.querySelector('[data-env-new-name]').value.trim();
    const value = row.querySelector('[data-env-new-value]');
    if (key && namePattern.test(key)) {
      const hidden = document.createElement('input');
      hidden.type = 'hidden';
      hidden.dataset.generatedSet = 'true';
      hidden.name = 'set[' + key + ']';
      hidden.value = value.value;
      form.append(hidden);
    }
  }

  function prepareSubmit() {
    form.querySelectorAll('[data-env-existing]').forEach((row) => {
      const toggle = row.querySelector('[data-replace-toggle]');
      if (!toggle.checked) row.querySelector('[data-replace-value]').value = '';
    });
    form
      .querySelectorAll('[data-generated-set]')
      .forEach((input) => input.remove());
    form.querySelectorAll('li[data-env-add-row]').forEach(appendSetValue);
  }

  form.querySelectorAll('[data-replace-toggle]').forEach((toggle) => {
    toggle.addEventListener('change', () => syncReplace(toggle));
    syncReplace(toggle);
  });
  addButton.addEventListener('click', addVariableRow);
  form.addEventListener('submit', () => {
    prepareSubmit();
    status.textContent = 'Submitting environment overrides…';
  });
  window.WorkspaceEnvironment = { toggleBusy, updateStatus };
  toggleBusy(document.getElementById('workspace').dataset.busy === 'true');
})();
