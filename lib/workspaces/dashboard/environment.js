(function () {
  'use strict';
  const form = document.getElementById('environment-form');
  if (!form) return;
  const status = document.getElementById('environment-status');
  const fieldset = form.querySelector('[data-environment-fieldset]');
  const submit = form.querySelector('[data-env-submit]');
  const rowsContainer = document.getElementById('env-rows');
  const rowTemplate = document.getElementById('env-row-template');
  const addButton = form.querySelector('[data-env-add-row]');
  const presetButtons = Array.from(form.querySelectorAll('[data-environment-preset]'));
  const presetGroup = form.querySelector('[data-preset-controls]');
  let lastAnnounced = '';
  let activeBusy = document.getElementById('workspace').dataset.busy === 'true';
  let presets = {};
  let selectedPreset = null;
  let nextIndex = 0;
  let initialSignature = '';

  try {
    presets = JSON.parse(form.dataset.environmentPresets || '{}');
  } catch (_error) {
    presets = {};
  }
  const hasPresets = Object.keys(presets).length > 0;
  if (presetGroup && hasPresets) presetGroup.hidden = false;

  // A preset is a list of { name, value }. A row's state is what the person typed. Secret rows are
  // never part of any comparison, so a preset can match while secrets are present.
  function rowElements() {
    return rowsContainer ? Array.from(rowsContainer.querySelectorAll('[data-env-row]')) : [];
  }

  // The value input is missing on a stored secret until Replace is clicked, so it can be null.
  function fieldsOf(row) {
    return {
      name: row.querySelector('.env-row__name'),
      value: row.querySelector('[data-env-value]'),
      secret: row.querySelector('[data-env-secret]'),
      remove: row.querySelector('[data-env-remove-row]'),
      stored: row.querySelector('[data-env-stored]'),
      replace: row.querySelector('[data-env-replace]')
    };
  }

  const valueOf = (fields) => (fields.value ? fields.value.value || '' : '');

  // Keeps password managers out of every input this script creates: autocomplete is ignored on
  // password fields, so each manager's own opt-out goes with it.
  function noAutofill(input) {
    input.autocomplete = 'off';
    input.setAttribute('autocomplete', 'off');
    input.setAttribute('data-1p-ignore', '');
    input.setAttribute('data-lpignore', 'true');
    input.setAttribute('data-bwignore', '');
  }

  function visibleEntries() {
    return rowElements()
      .map((row) => {
        const fields = fieldsOf(row);
        return {
          name: (fields.name.value || '').trim(),
          value: valueOf(fields),
          secret: !!(fields.secret && fields.secret.checked)
        };
      })
      .filter((entry) => !entry.secret && (entry.name || entry.value));
  }

  function signatureOf(entries) {
    return JSON.stringify(
      entries
        .map((entry) => [entry.name, entry.value])
        .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    );
  }

  function matchingPresetName() {
    const current = signatureOf(visibleEntries());
    return Object.keys(presets).find((name) => signatureOf(presets[name]) === current) || null;
  }

  function updatePresetButtons(nextSelected) {
    selectedPreset = nextSelected || null;
    presetButtons.forEach((button) => {
      const isSelected = !!selectedPreset && button.dataset.environmentPreset === selectedPreset;
      button.setAttribute('aria-pressed', isSelected ? 'true' : 'false');
      if (isSelected) button.classList.add('button--success');
      else button.classList.remove('button--success');
    });
  }

  function submitLabel() {
    return (submit && submit.textContent.trim()) || 'Save & restart';
  }

  function setSubmitLabel(label) {
    if (!label) return;
    if (submit) submit.textContent = label;
    form.querySelectorAll('[data-submit-label]').forEach((element) => {
      element.textContent = label;
    });
  }

  function setStatus(message) {
    if (!message) return;
    if (lastAnnounced === message) return;
    status.textContent = message;
    lastAnnounced = message;
  }

  function toggleBusy(nextBusy) {
    activeBusy = !!nextBusy;
    if (fieldset) fieldset.disabled = activeBusy;
    if (submit) submit.disabled = activeBusy;
    presetButtons.forEach((button) => {
      button.disabled = activeBusy || !hasPresets;
    });
  }

  function updateStatus(busy) {
    if (busy)
      setStatus('Workspace is busy. Environment updates are temporarily disabled.');
    else if (status.textContent === 'Workspace is busy. Environment updates are temporarily disabled.') {
      status.textContent = '';
      lastAnnounced = '';
    }
  }

  function announceUnsaved(message) {
    if (activeBusy) return;
    const nextMessage =
      message || 'Draft updated locally and not saved yet. Use ' + submitLabel() + ' to apply changes.';
    status.textContent = nextMessage;
    lastAnnounced = nextMessage;
  }

  function clearStatus() {
    if (activeBusy) return;
    status.textContent = '';
    lastAnnounced = '';
  }

  // The checkbox of a secret that is already stored is disabled (and a hidden field carries it), so a
  // saved secret cannot be turned back into a visible variable. Ticking Secret on a new row switches
  // its value to a password field; the value is write-only from then on.
  function syncRow(row) {
    const fields = fieldsOf(row);
    const secret = !!(fields.secret && fields.secret.checked);
    if (secret) row.setAttribute('data-secret', 'true');
    else row.removeAttribute('data-secret');
    if (!fields.value) return;
    fields.value.type = secret ? 'password' : 'text';
    noAutofill(fields.value);
    if (row.hasAttribute('data-stored')) fields.value.placeholder = 'New value (leave blank to keep)';
    else fields.value.placeholder = secret ? 'Value' : 'value';
  }

  // Replace adds the value input to a stored secret. Until then the page has no password field for
  // it at all.
  function revealReplaceInput(row) {
    const fields = fieldsOf(row);
    if (fields.value || !fields.stored) return;
    const input = document.createElement('input');
    input.className = 'env-row__value';
    input.name = (fields.name.name || '').replace(/\[name\]$/, '[value]');
    input.type = 'password';
    input.value = '';
    input.placeholder = 'New value (leave blank to keep)';
    input.setAttribute('aria-label', 'New value');
    input.setAttribute('spellcheck', 'false');
    input.setAttribute('autocapitalize', 'off');
    input.setAttribute('data-env-value', '');
    noAutofill(input);
    fields.stored.parentNode.insertBefore(input, fields.stored);
    fields.stored.parentNode.removeChild(fields.stored);
    input.focus();
  }

  function bindRow(row) {
    const fields = fieldsOf(row);
    if (fields.remove) {
      fields.remove.hidden = false;
      fields.remove.addEventListener('click', () => {
        if (activeBusy) return;
        row.parentNode.removeChild(row);
        draftChanged();
      });
    }
    if (fields.replace) {
      fields.replace.hidden = false;
      fields.replace.addEventListener('click', () => {
        if (activeBusy) return;
        revealReplaceInput(row);
      });
    }
    ['input', 'change'].forEach((type) => {
      row.addEventListener(type, (event) => {
        if (event && event.target && event.target.matches && event.target.matches('[data-env-secret]'))
          syncRow(row);
        draftChanged();
      });
    });
    syncRow(row);
  }

  function addRow(entry) {
    if (!rowTemplate || !rowsContainer) return null;
    const holder = document.createElement('div');
    holder.innerHTML = rowTemplate.innerHTML.split('__INDEX__').join(String(nextIndex++));
    const row = holder.querySelector('[data-env-row]');
    if (!row) return null;
    rowsContainer.append(row);
    const fields = fieldsOf(row);
    if (entry) {
      fields.name.value = entry.name || '';
      if (fields.value) fields.value.value = entry.value || '';
    }
    bindRow(row);
    return row;
  }

  function draftChanged() {
    updatePresetButtons(matchingPresetName());
    const unchanged = rowElements().length === 0 ? false : currentSignature() === initialSignature;
    if (unchanged) clearStatus();
    else announceUnsaved();
  }

  function currentSignature() {
    return JSON.stringify(
      rowElements().map((row) => {
        const fields = fieldsOf(row);
        const secret = !!(fields.secret && fields.secret.checked);
        // A secret's value is kept out of the signature, but whether one has been typed is not: a
        // pending replacement is an unsaved change.
        return [fields.name.value, secret ? '' : valueOf(fields), secret, secret && valueOf(fields) !== ''];
      })
    );
  }

  // Loading a preset replaces the visible variables only. Secrets are never touched by a preset.
  function loadPreset(name) {
    const entries = presets[name] || [];
    rowElements().forEach((row) => {
      const fields = fieldsOf(row);
      const isSecret = !!(fields.secret && fields.secret.checked);
      if (!isSecret) row.parentNode.removeChild(row);
    });
    entries.forEach((entry) => addRow(entry));
    updatePresetButtons(name);
    announceUnsaved('Preset loaded into draft only. Use ' + submitLabel() + ' to apply changes.');
  }

  form.addEventListener('submit', () => {
    setStatus('Submitting environment settings…');
  });

  presetButtons.forEach((button) => {
    button.addEventListener('click', () => {
      if (activeBusy) return;
      const nextValue = button.dataset.environmentPreset;
      if (!nextValue) return;
      if (!Object.prototype.hasOwnProperty.call(presets, nextValue)) return;
      loadPreset(nextValue);
    });
  });

  if (addButton) {
    addButton.hidden = false;
    addButton.addEventListener('click', () => {
      if (activeBusy) return;
      const row = addRow(null);
      if (row) fieldsOf(row).name.focus();
    });
  }

  // Rows the server rendered already carry numbered names; new rows continue after the highest.
  rowElements().forEach((row) => {
    const match = /env\[(\d+)\]/.exec(fieldsOf(row).name.name || '');
    if (match) nextIndex = Math.max(nextIndex, Number(match[1]) + 1);
    bindRow(row);
  });
  initialSignature = currentSignature();

  window.WorkspaceEnvironment = {
    toggleBusy,
    updateStatus,
    setStatus,
    setSubmitLabel,
    // The rows are server-rendered and the person may be editing them, so a poll never rewrites
    // them; it only keeps the selected preset in step when nothing has been touched.
    syncFromSnapshot(snapshot) {
      if (!snapshot || presetButtons.length === 0) return;
      if (rowsContainer && rowsContainer.contains(document.activeElement)) return;
      updatePresetButtons(matchingPresetName());
    }
  };
  updatePresetButtons(matchingPresetName());
  toggleBusy(activeBusy);
})();
