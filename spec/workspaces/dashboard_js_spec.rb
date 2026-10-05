require_relative 'spec_helper'
require 'json'

RSpec.describe 'dashboard scripts' do
  let(:app_js) { File.read(File.join(__dir__, '../../lib/workspaces/dashboard/app.js')) }
  let(:environment_js) { File.read(File.join(__dir__, '../../lib/workspaces/dashboard/environment.js')) }

  it 'executes environment preset button flow with explicit replacement, persistent selected state, no submit, and busy disablement' do
    script = <<~'NODE'
      const fs = require('node:fs');
      const vm = require('node:vm');

      class ClassList {
        constructor(owner) { this.owner = owner; this._set = new Set(); }
        add(name) { this._set.add(name); this._sync(); }
        remove(name) { this._set.delete(name); this._sync(); }
        contains(name) { return this._set.has(name); }
        _sync() { this.owner.className = Array.from(this._set).join(' '); }
      }

      class Node {
        constructor(tagName, opts = {}) {
          this.tagName = tagName.toUpperCase();
          this.id = opts.id || null;
          this.dataset = opts.dataset || {};
          this.attributes = opts.attributes || {};
          this.className = opts.className || '';
          this.classList = new ClassList(this);
          this.className.split(/\s+/).filter(Boolean).forEach((name) => this.classList.add(name));
          this.textContent = opts.textContent || '';
          this.value = opts.value || '';
          this.disabled = !!opts.disabled;
          this.hidden = !!opts.hidden;
          this.listeners = {};
          this.children = [];
          this.parentNode = null;
        }
        append(...children) {
          children.flat().forEach((child) => {
            child.parentNode = this;
            this.children.push(child);
          });
        }
        appendChild(child) {
          child.parentNode = this;
          this.children.push(child);
          return child;
        }
        replaceChildren(...children) {
          this.children = [];
          this.append(...children);
        }
        addEventListener(type, handler) {
          this.listeners[type] ||= [];
          this.listeners[type].push(handler);
        }
        dispatchEvent(event) {
          event.target ||= this;
          (this.listeners[event.type] || []).forEach((handler) => handler.call(this, event));
          if (event.bubbles && this.parentNode) this.parentNode.dispatchEvent(event);
        }
        querySelectorAll(selector) {
          const selectors = selector.split(',').map((s) => s.trim());
          const results = [];
          const visit = (node) => {
            node.children.forEach((child) => {
              if (selectors.some((candidate) => matchesSelector(child, candidate))) results.push(child);
              visit(child);
            });
          };
          visit(this);
          return results;
        }
        querySelector(selector) {
          return this.querySelectorAll(selector)[0] || null;
        }
        setAttribute(name, value) { this.attributes[name] = value; }
      }

      class Form extends Node {
        constructor(opts = {}) {
          super('form', opts);
          this.method = opts.method || '';
          this.action = opts.action || '';
        }
      }

      class Button extends Node {
        constructor(opts = {}) { super('button', opts); }
      }

      class Document {
        constructor() {
          this.byId = {};
          this.activeElement = null;
        }
        register(node) {
          if (node.id) this.byId[node.id] = node;
          node.children.forEach((child) => this.register(child));
          return node;
        }
        getElementById(id) { return this.byId[id] || null; }
        createElement(tagName) {
          if (tagName === 'form') return new Form();
          if (tagName === 'button') return new Button();
          return new Node(tagName);
        }
      }

      function matchesSelector(node, selector) {
        if (selector === 'fieldset') return node.tagName === 'FIELDSET';
        if (selector === 'button') return node.tagName === 'BUTTON';
        if (selector === 'input') return node.tagName === 'INPUT';
        if (selector === 'form') return node.tagName === 'FORM';
        if (selector === '[data-env-submit]') return Object.prototype.hasOwnProperty.call(node.attributes, 'data-env-submit');
        if (selector === '[data-environment-fieldset]') return Object.prototype.hasOwnProperty.call(node.attributes, 'data-environment-fieldset');
        if (selector === '[data-environment-preset]') return Object.prototype.hasOwnProperty.call(node.attributes, 'data-environment-preset');
        if (selector === '[data-preset-controls]') return Object.prototype.hasOwnProperty.call(node.attributes, 'data-preset-controls');
        if (selector === '.workspace-actions button') {
          return node.tagName === 'BUTTON' && hasAncestorWithClass(node, 'workspace-actions');
        }
        if (selector === '.workspace-actions form') {
          return node.tagName === 'FORM' && hasAncestorWithClass(node, 'workspace-actions');
        }
        if (selector.startsWith('#')) return node.id === selector.slice(1);
        return false;
      }

      function hasAncestorWithClass(node, className) {
        let current = node.parentNode;
        while (current) {
          if ((current.className || '').split(/\s+/).includes(className)) return true;
          current = current.parentNode;
        }
        return false;
      }

      function parseSimpleUrl(url) {
        const index = url.indexOf('?');
        return {
          search: index >= 0 ? url.slice(index) : ''
        };
      }

      class SearchParams {
        constructor(search) {
          this.map = {};
          const raw = search.startsWith('?') ? search.slice(1) : search;
          if (!raw) return;
          raw.split('&').forEach((part) => {
            if (!part) return;
            const pieces = part.split('=');
            const key = decodeURIComponent(pieces.shift());
            const value = decodeURIComponent(pieces.join('='));
            this.map[key] = value;
          });
        }
        get(name) {
          return Object.prototype.hasOwnProperty.call(this.map, name) ? this.map[name] : null;
        }
      }

      const document = new Document();
      const root = document.register(new Node('main', {
        id: 'workspace',
        dataset: {
          id: 'fixture',
          status: 'ready',
          started: '2026-10-05T00:00:00Z',
          completed: '2026-10-05T00:01:00Z',
          busy: 'false'
        }
      }));

      const actionsWrap = document.register(new Node('div', { className: 'workspace-actions' }));
      const actions = document.register(new Node('div', { id: 'actions', className: 'workspace-actions' }));
      const preview = document.register(new Node('a', { id: 'preview' }));
      actionsWrap.append(preview, actions);

      const removeForm = document.register(new Form({ id: 'remove-form' }));
      const removeInput = document.register(new Node('input', { id: 'confirm-id' }));
      const removeButton = document.register(new Button({ id: 'remove-submit' }));
      removeForm.append(removeInput, removeButton);

      const envForm = document.register(new Form({
        id: 'environment-form',
        dataset: { environmentPresets: JSON.stringify({ Alpha: 'UE_APP=alpha\nROUTING_SUBDOMAIN=alpha', Beta: 'UE_APP=beta' }) },
        attributes: { 'data-environment-form': '' }
      }));
      const envFieldset = document.register(new Node('fieldset', { attributes: { 'data-environment-fieldset': '' } }));
      const presetGroup = document.register(new Node('div', { hidden: true, attributes: { 'data-preset-controls': '' } }));
      const alphaPreset = document.register(new Button({
        id: 'environment-preset-alpha',
        attributes: { 'data-environment-preset': 'Alpha', 'aria-pressed': 'false', type: 'button' },
        className: 'button button--subtle env-preset-button',
        textContent: 'Alpha'
      }));
      alphaPreset.dataset.environmentPreset = 'Alpha';
      const betaPreset = document.register(new Button({
        id: 'environment-preset-beta',
        attributes: { 'data-environment-preset': 'Beta', 'aria-pressed': 'false', type: 'button' },
        className: 'button button--subtle env-preset-button',
        textContent: 'Beta'
      }));
      betaPreset.dataset.environmentPreset = 'Beta';
      const editor = document.register(new Node('textarea', { id: 'editable-env', value: 'UE_APP=www\nROUTING_SUBDOMAIN=www' }));
      envFieldset.append(presetGroup);
      presetGroup.append(alphaPreset, betaPreset);
      envFieldset.append(editor);
      const envSubmit = document.register(new Button({ attributes: { 'data-env-submit': '' } }));
      const envStatus = document.register(new Node('p', { id: 'environment-status' }));
      envForm.append(envFieldset, envSubmit, envStatus);

      const status = document.register(new Node('h2', { id: 'status' }));
      const activity = document.register(new Node('span', { id: 'activity' }));
      const message = document.register(new Node('p', { id: 'message' }));
      const sourceUpdate = document.register(new Node('p', { id: 'source-update-message' }));
      const progress = document.register(new Node('ol', { id: 'progress' }));
      const error = document.register(new Node('pre', { id: 'error' }));
      const errorPanel = document.register(new Node('section', { id: 'error-panel' }));
      const log = document.register(new Node('pre', { id: 'log' }));
      log.clientHeight = 100;
      log.scrollHeight = 100;
      log.scrollTop = 0;
      const updated = document.register(new Node('time', { id: 'updated' }));
      const connection = document.register(new Node('p', { id: 'connection' }));
      const elapsed = document.register(new Node('span', { id: 'elapsed' }));

      root.append(actionsWrap, removeForm, envForm, status, activity, message, sourceUpdate, progress, error, errorPanel, log, updated, connection, elapsed);

      const pendingTimers = [];
      const fakeFetches = [];
      const fakeResponse = {
        ok: true,
        async json() {
          return {
            presentation: {
              title: 'Ready',
              busy: false,
              ready: true,
              error: '',
              actions: [{ key: 'start', label: 'Start workspace', primary: true }],
              steps: []
            },
            message: 'ok',
            source_update_message: '',
            editable_environment: { ROUTING_SUBDOMAIN: 'www', UE_APP: 'www' },
            log_source: 'setup',
            log_tail: 'next',
            updated_at: 'now',
            prepare_started_at: '2026-10-05T00:00:00Z',
            completed_at: '2026-10-05T00:01:00Z'
          };
        }
      };

      function fetchStub(url) {
        fakeFetches.push(url);
        return Promise.resolve(fakeResponse);
      }

      class AbortControllerStub {
        constructor() { this.signal = {}; }
        abort() {}
      }

      const context = {
        document,
        window: {
          location: parseSimpleUrl('/workspaces/fixture?log=setup')
        },
        URLSearchParams: SearchParams,
        fetch: fetchStub,
        AbortController: AbortControllerStub,
        setTimeout(callback, delay) {
          pendingTimers.push({ callback, delay });
          return pendingTimers.length;
        },
        clearTimeout() {},
        Date,
        JSON,
        Math,
        Number,
        console
      };
      context.window.document = document;
      context.window.fetch = fetchStub;
      context.window.AbortController = AbortControllerStub;
      context.window.setTimeout = context.setTimeout;
      context.window.clearTimeout = context.clearTimeout;
      context.window.URLSearchParams = SearchParams;
      context.window.Date = Date;
      context.window.JSON = JSON;
      context.window.Math = Math;
      context.window.Number = Number;
      context.window.console = console;

      const appJs = fs.readFileSync('lib/workspaces/dashboard/app.js', 'utf8');
      const environmentJs = fs.readFileSync('lib/workspaces/dashboard/environment.js', 'utf8');
      vm.runInNewContext(appJs, context);
      vm.runInNewContext(environmentJs, context);

      const result = {};
      result.presetGroupVisibleAfterInit = !presetGroup.hidden;
      result.pressedAfterInit = {
        alpha: alphaPreset.attributes['aria-pressed'],
        beta: betaPreset.attributes['aria-pressed']
      };

      const submitEvents = [];
      envForm.addEventListener('submit', (event) => submitEvents.push(event.type));

      alphaPreset.dispatchEvent({ type: 'click', target: alphaPreset });
      result.editorAfterPreset = editor.value;
      result.statusAfterPreset = envStatus.textContent;
      result.submitCountAfterPreset = submitEvents.length;
      result.pressedAfterPreset = {
        alpha: alphaPreset.attributes['aria-pressed'],
        beta: betaPreset.attributes['aria-pressed']
      };

      editor.value = 'UE_APP=custom';
      editor.dispatchEvent({ type: 'input', target: editor });
      result.statusAfterEdit = envStatus.textContent;
      result.pressedAfterManualEdit = {
        alpha: alphaPreset.attributes['aria-pressed'],
        beta: betaPreset.attributes['aria-pressed']
      };

      betaPreset.dispatchEvent({ type: 'click', target: betaPreset });
      result.editorAfterSwitchingPreset = editor.value;
      result.pressedAfterSwitchingPreset = {
        alpha: alphaPreset.attributes['aria-pressed'],
        beta: betaPreset.attributes['aria-pressed']
      };

      context.window.WorkspaceEnvironment.toggleBusy(true);
      alphaPreset.dispatchEvent({ type: 'click', target: alphaPreset });
      result.editorAfterBusyPresetAttempt = editor.value;
      result.presetDisabledWhenBusy = alphaPreset.disabled && betaPreset.disabled;
      result.editorDisabledWhenBusy = envFieldset.disabled;
      result.saveDisabledWhenBusy = envSubmit.disabled;

      context.window.WorkspaceEnvironment.toggleBusy(false);
      result.presetEnabledAfterBusy = !alphaPreset.disabled && !betaPreset.disabled;

      document.activeElement = editor;
      context.window.WorkspaceEnvironment.syncFromSnapshot({ editable_environment: { ROUTING_SUBDOMAIN: 'www', UE_APP: 'www' } });
      result.pressedAfterSyncWhileFocused = {
        alpha: alphaPreset.attributes['aria-pressed'],
        beta: betaPreset.attributes['aria-pressed']
      };

      document.activeElement = null;
      editor.value = 'UE_APP=custom';
      context.window.WorkspaceEnvironment.syncFromSnapshot({ editable_environment: { ROUTING_SUBDOMAIN: 'www', UE_APP: 'www' } });
      result.editorAfterPollingSyncMismatch = editor.value;
      result.pressedAfterPollingSyncMismatch = {
        alpha: alphaPreset.attributes['aria-pressed'],
        beta: betaPreset.attributes['aria-pressed']
      };

      editor.value = 'UE_APP=www\nROUTING_SUBDOMAIN=www';
      context.window.WorkspaceEnvironment.syncFromSnapshot({ editable_environment: { ROUTING_SUBDOMAIN: 'www', UE_APP: 'www' } });
      result.pressedAfterPollingSyncExact = {
        alpha: alphaPreset.attributes['aria-pressed'],
        beta: betaPreset.attributes['aria-pressed']
      };

      result.scheduledDelays = pendingTimers.map((item) => item.delay);
      process.stdout.write(JSON.stringify(result));
    NODE

    output, status = Open3.capture2('node', '-e', script, chdir: File.join(__dir__, '../..'))
    expect(status.success?).to eq(true)
    result = JSON.parse(output)

    expect(result['presetGroupVisibleAfterInit']).to eq(true)
    expect(result['pressedAfterInit']).to eq({ 'alpha' => 'false', 'beta' => 'false' })
    expect(result['editorAfterPreset']).to eq("UE_APP=alpha\nROUTING_SUBDOMAIN=alpha")
    expect(result['statusAfterPreset']).to eq('Preset loaded into draft only. Use Save & restart to apply changes.')
    expect(result['submitCountAfterPreset']).to eq(0)
    expect(result['pressedAfterPreset']).to eq({ 'alpha' => 'true', 'beta' => 'false' })
    expect(result['statusAfterEdit']).to eq('Draft updated locally and not saved yet. Use Save & restart to apply changes.')
    expect(result['pressedAfterManualEdit']).to eq({ 'alpha' => 'false', 'beta' => 'false' })
    expect(result['editorAfterSwitchingPreset']).to eq('UE_APP=beta')
    expect(result['pressedAfterSwitchingPreset']).to eq({ 'alpha' => 'false', 'beta' => 'true' })
    expect(result['editorAfterBusyPresetAttempt']).to eq('UE_APP=beta')
    expect(result['presetDisabledWhenBusy']).to eq(true)
    expect(result['editorDisabledWhenBusy']).to eq(true)
    expect(result['saveDisabledWhenBusy']).to eq(true)
    expect(result['presetEnabledAfterBusy']).to eq(true)
    expect(result['pressedAfterSyncWhileFocused']).to eq({ 'alpha' => 'false', 'beta' => 'true' })
    expect(result['editorAfterPollingSyncMismatch']).to eq('UE_APP=custom')
    expect(result['pressedAfterPollingSyncMismatch']).to eq({ 'alpha' => 'false', 'beta' => 'true' })
    expect(result['pressedAfterPollingSyncExact']).to eq({ 'alpha' => 'false', 'beta' => 'true' })
    expect(result['scheduledDelays']).to include(1000)
  end

  it 'keeps preset UI hidden when no presets are provided and no-JS editor remains available in HTML' do
    snapshot = {
      'workspace_id' => 'fixture',
      'status' => 'idle',
      'active' => false,
      'editable_environment' => { 'UE_APP' => 'www' },
      'environment_presets' => {}
    }
    html = Workspaces::DashboardView.render(snapshot)

    expect(html).to include('id="editable-env"')
    expect(html).not_to include('id="environment-preset"')
    expect(html).to include('data-environment-presets="{}"')
  end
end
