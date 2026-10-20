require_relative 'spec_helper'
require 'json'

# Drives app.js against a small fake DOM to check how the step accordions behave across
# polls: reconciled in place by step id, opened and closed by state changes, never fighting
# a user's own toggle, and the Web server log tab appearing when a backend log exists.
RSpec.describe 'dashboard step accordions' do
  def run_polls(polls, user_actions: {})
    script = <<~'NODE'
      const fs = require('node:fs');
      const vm = require('node:vm');
      const input = JSON.parse(process.argv[1]);

      class Node {
        constructor(tag, opts = {}) {
          this.tagName = tag.toUpperCase(); this.id = opts.id || null;
          this.dataset = opts.dataset || {}; this.attributes = {}; this.className = opts.className || '';
          this.textContent = opts.textContent || ''; this.hidden = !!opts.hidden; this.open = !!opts.open;
          this.disabled = false; this.children = []; this.listeners = {}; this.parentNode = null;
          this.scrollTop = 0; this.clientHeight = 100; this.scrollHeight = 100;
        }
        get childNodes() { return this.children; }
        append(...c) { c.flat().forEach((x) => { x.parentNode = this; this.children.push(x); }); }
        insertBefore(child, ref) {
          child.parentNode = this;
          const at = ref ? this.children.indexOf(ref) : -1;
          if (at < 0) this.children.push(child); else this.children.splice(at, 0, child);
          return child;
        }
        removeChild(child) { this.children = this.children.filter((c) => c !== child); child.parentNode = null; }
        replaceChildren(...c) { this.children = []; this.append(...c); }
        setAttribute(n, v) { this.attributes[n] = v; }
        removeAttribute(n) { delete this.attributes[n]; }
        addEventListener(t, h) { (this.listeners[t] ||= []).push(h); }
        fire(type) { (this.listeners[type] || []).forEach((h) => h.call(this, { type, target: this })); }
        querySelectorAll(sel) {
          const out = [];
          const visit = (n) => n.children.forEach((c) => { if (matches(c, sel)) out.push(c); visit(c); });
          visit(this); return out;
        }
        querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
        // `summary` is the only direct-child tag the script looks up on an accordion.
        set tabIndex(v) { this._tab = v; }
      }
      function matches(n, sel) {
        const parts = sel.split(',').map((s) => s.trim());
        return parts.some((p) => {
          let m;
          if ((m = p.match(/^\[data-step-log="(.+)"\]$/))) return n.dataset.stepLog === m[1];
          if (p === '[data-step-log]') return 'stepLog' in n.dataset;
          if (p === '[data-section]') return 'section' in n.dataset;
          if (p === 'summary') return n.tagName === 'SUMMARY';
          if (p === 'pre') return n.tagName === 'PRE';
          if (p === '.workspace-actions button' || p === '.workspace-actions button, .lead__action button') return false;
          return false;
        });
      }
      class Doc {
        constructor() { this.byId = {}; this.activeElement = null; }
        reg(n) { if (n.id) this.byId[n.id] = n; n.children.forEach((c) => this.reg(c)); return n; }
        getElementById(id) { return this.byId[id] || null; }
        createElement(t) { return new Node(t); }
      }
      const document = new Doc();
      const root = document.reg(new Node('main', { id: 'workspace', dataset: { id: 'ws-1', busy: 'false', disclosureState: 'busy' } }));
      const mk = (tag, id, o = {}) => document.reg(new Node(tag, { id, ...o }));
      const steps = mk('div', 'steps', { dataset: { stepLogs: '' } });
      const fullLog = mk('details', 'full-log', { dataset: { stepLog: 'full' } });
      const fullOutcome = new Node('span', { id: 'full-log-outcome' });
      const fullSummary = new Node('summary'); fullSummary.append(fullOutcome);
      const fullPre = new Node('pre'); fullLog.append(fullSummary, fullPre);
      document.reg(fullOutcome);
      steps.append(fullLog);
      const names = ['status', 'summary', 'activity', 'elapsed', 'preview', 'lead-action', 'message',
        'error', 'error-panel', 'connection', 'environment-title', 'environment-disclosure', 'technical-disclosure',
        'actions', 'source-update-message', 'updated'];
      names.forEach((n) => root.append(mk('div', n, { hidden: n === 'preview' })));
      const log = mk('pre', 'log', { hidden: true });
      const backendTab = mk('a', 'backend-tab', { hidden: true });
      root.append(steps, log, backendTab);

      const timers = [];
      const responses = input.polls.slice();
      const context = {
        document, window: { location: { search: '?log=setup' } },
        URLSearchParams: class { get() { return 'setup'; } },
        fetch: () => Promise.resolve({ ok: true, json: async () => responses.shift() }),
        AbortController: class { constructor() { this.signal = {}; } abort() {} },
        setTimeout(cb, d) { timers.push({ cb, d }); return timers.length; }, clearTimeout() {},
        Date, JSON, Math, Number, console
      };
      vm.runInNewContext(fs.readFileSync('lib/workspaces/dashboard/app.js', 'utf8'), context);

      const accordion = (key) => steps.querySelector('[data-step-log="' + key + '"]');
      (async () => {
        const out = [];
        for (let i = 0; i < input.polls.length; i++) {
          const at = timers.findIndex((t) => t.cb.name === 'poll');
          const poll = timers.splice(at, 1)[0]; await poll.cb(); await new Promise((r) => setImmediate(r));
          // flush the zero-delay timers that clear the programmatic-toggle guard
          timers.filter((t) => t.d === 0).forEach((t) => t.cb()); for (let k = timers.length - 1; k >= 0; k--) if (timers[k].d === 0) timers.splice(k, 1);
          ((input.userActions || {})[String(i)] || []).forEach(({ key, open }) => {
            const d = accordion(key); d.open = open; d.fire('toggle');
          });
          out.push({
            order: steps.children.map((c) => c.dataset.stepLog),
            open: Object.fromEntries(steps.children.map((c) => [c.dataset.stepLog, c.open])),
            state: Object.fromEntries(steps.children.map((c) => [c.dataset.stepLog, c.dataset.stepState || null])),
            names: Object.fromEntries(steps.children.filter((c) => c !== fullLog).map((c) => [c.dataset.stepLog, c.children[0].children[1].textContent])),
            outcomes: Object.fromEntries(steps.children.filter((c) => c !== fullLog).map((c) => [c.dataset.stepLog, c.children[0].children[2].textContent])),
            text: Object.fromEntries(steps.children.filter((c) => c !== fullLog).map((c) => [c.dataset.stepLog, c.children[1].textContent])),
            current: Object.fromEntries(steps.children.filter((c) => c !== fullLog).map((c) => [c.dataset.stepLog, c.attributes['aria-current'] || null])),
            fullText: fullPre.textContent, tabHidden: backendTab.hidden, fullOutcome: fullOutcome.textContent
          });
        }
        process.stdout.write(JSON.stringify(out));
      })();
    NODE
    out, status = Open3.capture2('node', '-e', script, JSON.generate(polls: polls, userActions: user_actions))
    raise "node failed: #{out}" unless status.success?

    JSON.parse(out)
  end

  def step(key, state, duration = nil)
    { 'key' => key, 'label' => key.capitalize, 'state' => state, 'duration_seconds' => duration }
  end

  def poll(steps, logs = {}, backend: false, tail: '', total: nil, busy: true)
    { 'presentation' => { 'state' => busy ? 'busy' : 'ready', 'busy' => busy, 'ready' => !busy, 'error' => '', 'steps' => steps, 'total' => total,
                          'actions' => [], 'sections' => {}, 'headline' => 'h', 'summary' => 's',
                          'lead_action' => nil, 'environment_title' => 't', 'environment_submit' => 'x',
                          'open' => { 'environment' => false, 'technical' => true } },
      'step_logs' => logs.transform_values { |text| { 'text' => text, 'truncated' => false } },
      'backend_log_available' => backend, 'message' => 'm', 'source_update_message' => '',
      'editable_environment' => {}, 'log_source' => 'setup', 'log_tail' => tail, 'updated_at' => 'now',
      'prepare_started_at' => '2026-10-05T00:00:00Z', 'completed_at' => '2026-10-05T00:01:00Z' }
  end

  it 'creates an accordion per step, in recipe order, ahead of the full log, with names, outcomes and output' do
    first, = run_polls([poll([step('gems', 'active'), step('app', 'pending')], { 'gems' => 'installing' })])

    expect(first['order']).to eq(%w(gems app full))
    expect(first['names']).to eq('gems' => 'Gems', 'app' => 'App')
    expect(first['outcomes']).to eq('gems' => 'active', 'app' => 'pending')
    expect(first['text']['gems']).to eq('installing')
    expect(first['current']).to eq('gems' => 'step', 'app' => nil)
  end

  it 'opens the running step, then closes it when it completes while opening the next' do
    one = poll([step('gems', 'active'), step('app', 'pending')])
    two = poll([step('gems', 'complete', 1.5), step('app', 'active')])

    first, second = run_polls([one, two])

    expect(first['open']).to include('gems' => true, 'app' => false)
    expect(second['open']).to include('gems' => false, 'app' => true)
    expect(second['outcomes']['gems']).to eq('complete · 1.5s')
  end

  it 'opens a step that fails and leaves it open' do
    first, second = run_polls([poll([step('gems', 'active')]), poll([step('gems', 'failed', 0.2)], { 'gems' => 'boom' })])

    expect(first['open']['gems']).to eq(true)
    expect(second['open']['gems']).to eq(true)
    expect(second['text']['gems']).to eq('boom')
  end

  it 'never reopens or recloses a step the reader toggled by hand, even when its state later changes' do
    polls = [poll([step('gems', 'active'), step('app', 'pending')]),
             poll([step('gems', 'active'), step('app', 'pending')]),
             poll([step('gems', 'complete', 1.0), step('app', 'active')])]
    # The reader closes the running step after the first poll, and opens the waiting one.
    actions = { '0' => [{ 'key' => 'gems', 'open' => false }, { 'key' => 'app', 'open' => true }] }

    first, second, third = run_polls(polls, user_actions: actions)

    expect(first['open']).to include('gems' => false, 'app' => true)
    expect(second['open']).to include('gems' => false, 'app' => true)
    expect(third['open']).to include('gems' => false, 'app' => true)
  end

  it 'updates output in place without recreating the accordion element' do
    polls = [poll([step('gems', 'active')], { 'gems' => 'one' }), poll([step('gems', 'active')], { 'gems' => 'one\ntwo' })]

    first, second = run_polls(polls)

    expect(first['text']['gems']).to eq('one')
    expect(second['text']['gems']).to eq('one\ntwo')
    expect(second['order']).to eq(%w(gems full))
  end

  it 'drops accordions for steps that are no longer in the run, but keeps the full log' do
    full = poll([step('gems', 'complete', 1.0), step('app', 'complete', 1.0)])
    restart = poll([step('app', 'active')])

    _, second = run_polls([full, restart])

    expect(second['order']).to eq(%w(app full))
  end

  it 'writes the combined log into the full-log accordion' do
    first, = run_polls([poll([step('gems', 'active')], {}, tail: "==> Gems\ninstalling\n")])

    expect(first['fullText']).to eq("==> Gems\ninstalling\n")
  end

  it 'shows "in progress" on the full log row while running, then how the run ended and how long it took' do
    running = poll([step('gems', 'active')])
    finished = poll([step('gems', 'complete', 1.0)], busy: false, total: { 'state' => 'complete', 'seconds' => 137.4 })
    failed = poll([step('gems', 'failed', 1.0)], busy: false, total: { 'state' => 'failed', 'seconds' => 61 })
    bare = poll([step('gems', 'complete', 1.0)], busy: false)

    a, b, c, d = run_polls([running, finished, failed, bare])

    expect([a, b, c, d].map { |s| s['fullOutcome'] }).to eq(['in progress', 'complete · 2m 17s', 'failed · 1m 1s', 'everything, in order'])
  end

  it 'reveals the Web server log tab once a backend log exists and keeps it' do
    without = poll([step('gems', 'complete', 1.0)])
    with = poll([step('gems', 'complete', 1.0)], backend: true)

    first, second, third = run_polls([without, with, without])

    expect([first['tabHidden'], second['tabHidden'], third['tabHidden']]).to eq([true, false, false])
  end
end
