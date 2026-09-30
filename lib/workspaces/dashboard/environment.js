(function () {
  'use strict';
  const form = document.getElementById('environment-form');
  if (!form) return;
  const status = document.getElementById('environment-status');

  function toggleBusy(nextBusy) {
    form.querySelectorAll('fieldset, [data-env-submit]').forEach((control) => {
      control.disabled = nextBusy;
    });
  }

  function updateStatus(busy) {
    if (busy)
      status.textContent =
        'Workspace is busy. Environment updates are temporarily disabled.';
  }

  form.addEventListener('submit', () => {
    status.textContent = 'Submitting environment settings…';
  });
  window.WorkspaceEnvironment = { toggleBusy, updateStatus };
  toggleBusy(document.getElementById('workspace').dataset.busy === 'true');
})();
