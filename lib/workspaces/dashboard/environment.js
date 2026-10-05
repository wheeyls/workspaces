(function () {
  'use strict';
  const form = document.getElementById('environment-form');
  if (!form) return;
  const status = document.getElementById('environment-status');
  const fieldset = form.querySelector('[data-environment-fieldset]');
  const submit = form.querySelector('[data-env-submit]');
  const editor = document.getElementById('editable-env');
  const presetSelect = form.querySelector('[data-environment-preset]');
  const presetGroup = form.querySelector('[data-preset-controls]');
  const initialDraft = editor ? editor.value : '';
  let lastAnnounced = '';
  let activeBusy = document.getElementById('workspace').dataset.busy === 'true';
  let presets = {};

  try {
    presets = JSON.parse(form.dataset.environmentPresets || '{}');
  } catch (_error) {
    presets = {};
  }
  const hasPresets = Object.keys(presets).length > 0;
  if (presetGroup && hasPresets) presetGroup.hidden = false;

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
    if (presetSelect) presetSelect.disabled = activeBusy;
  }

  function updateStatus(busy) {
    if (busy)
      setStatus(
        'Workspace is busy. Environment updates are temporarily disabled.'
      );
    else if (status.textContent === 'Workspace is busy. Environment updates are temporarily disabled.') {
      status.textContent = '';
      lastAnnounced = '';
    }
  }

  function announceUnsaved(message) {
    if (activeBusy) return;
    const nextMessage = message || 'Draft updated locally and not saved yet. Use Save & restart to apply changes.';
    status.textContent = nextMessage;
    lastAnnounced = nextMessage;
  }

  function replaceDraft(value, message) {
    if (!editor) return;
    editor.value = value || '';
    announceUnsaved(message);
  }

  form.addEventListener('submit', () => {
    setStatus('Submitting environment settings…');
  });

  if (editor)
    editor.addEventListener('input', () => {
      if (editor.value === initialDraft) {
        if (!activeBusy) {
          status.textContent = '';
          lastAnnounced = '';
        }
        return;
      }
      announceUnsaved();
    });

  if (presetSelect)
    presetSelect.addEventListener('change', () => {
      if (activeBusy) return;
      const nextValue = presetSelect.value;
      if (!nextValue) return;
      if (!Object.prototype.hasOwnProperty.call(presets, nextValue)) return;
      replaceDraft(
        presets[nextValue],
        'Preset loaded into draft only. Use Save & restart to apply changes.'
      );
      presetSelect.value = '';
    });

  window.WorkspaceEnvironment = {
    toggleBusy,
    updateStatus,
    setStatus,
    syncFromSnapshot(snapshot) {
      if (!snapshot || !presetSelect || !editor) return;
      const rendered = snapshot.editable_environment;
      if (!rendered || typeof rendered !== 'object') return;
      const expected = Object.keys(rendered)
        .sort()
        .map((name) => name + '=' + rendered[name])
        .join('\n');
      if (editor === document.activeElement) return;
      if (editor.value !== expected) return;
      presetSelect.value = '';
    }
  };
  if (!hasPresets && presetSelect) presetSelect.disabled = true;
  toggleBusy(activeBusy);
})();
