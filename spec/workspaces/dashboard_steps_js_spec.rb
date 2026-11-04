require_relative 'spec_helper'
require 'json'

# Drives app.js against a small fake DOM to check how the step accordions behave across
# polls: reconciled in place by step id, opened and closed by state changes, never fighting
# a user's own toggle, and the Web server log tab appearing when a backend log exists.
RSpec.describe 'dashboard step accordions' do
  def run_polls(polls, user_actions: {}, server_rendered: [], selections: {})
    script = <<~'NODE'
      const fs = require('node:fs');
      const vm = require('node:vm');
      const input = JSON.parse(process.argv[1]);

      class Node {
        constructor(tag, opts = {}) {
          this.tagName = tag.toUpperCase(); this.id = opts.id || null;
          this.dataset = opts.dataset || {}; this.attributes = {}; this.className = opts.className || '';
          this._t = opts.textContent || ''; this.writes = 0; this.hidden = !!opts.hidden; this.open = !!opts.open;
          this.disabled = false; this.children = []; this.listeners = {}; this.parentNode = null;
          this.scrollTop = 0; this.clientHeight = 100; this.scrollHeight = 100;
        }
        // Every assignment replaces the text node, which is what drops a selection inside it, so count them.
        get textContent() { return this._t; }
        set textContent(v) { this._t = v; this.writes += 1; }
        contains(n) { for (let x = n; x; x = x.parentNode) if (x === this) return true; return false; }
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
          if (p === '.step-log__actions') return n.className === 'step-log__actions';
          if (p === '.workspace-actions button' || p === '.workspace-actions button, .lead__action button') return false;
          return false;
        });
      }
      class Doc {
        constructor() { this.byId = {}; this.activeElement = null; this.listeners = {}; }
        addEventListener(t, h) { (this.listeners[t] ||= []).push(h); }
        fire(type) { (this.listeners[type] || []).forEach((h) => h({ type })); }
        reg(n) { if (n.id) this.byId[n.id] = n; n.children.forEach((c) => this.reg(c)); return n; }
        getElementById(id) { return this.byId[id] || null; }
        createElement(t) { return new Node(t); }
      }
      const document = new Doc();
      const root = document.reg(new Node('main', { id: 'workspace', dataset: { id: 'ws-1', busy: 'false' } }));
      const mk = (tag, id, o = {}) => document.reg(new Node(tag, { id, ...o }));
      const steps = mk('div', 'steps', { dataset: { stepLogs: '' } });
      const fullLog = mk('details', 'full-log', { dataset: { stepLog: 'full' } });
      const fullOutcome = new Node('span', { id: 'full-log-outcome' });
      const fullSummary = new Node('summary'); fullSummary.append(fullOutcome);
      const fullPre = new Node('pre'); fullLog.append(fullSummary, fullPre);
      document.reg(fullOutcome);
      steps.append(fullLog);
      // Accordions the server rendered before the script ran: a summary and a pre, and no controls
      // container, because the server only emits one for a step that has controls.
      input.serverRendered.forEach((key) => {
        const details = new Node('details', { className: 'step-log', dataset: { stepLog: key } });
        const summary = new Node('summary');
        summary.append(new Node('span'), new Node('span'), new Node('span'));
        details.append(summary, new Node('pre'));
        steps.insertBefore(details, fullLog);
      });
      const names = ['status', 'summary', 'activity', 'elapsed', 'preview', 'lead-action', 'message',
        'error', 'error-panel', 'connection', 'environment-title',
        'actions', 'source-update-message', 'updated'];
      names.forEach((n) => root.append(mk('div', n, { hidden: n === 'preview' })));
      const log = mk('pre', 'log', { hidden: true });
      const backendTab = mk('a', 'backend-tab', { hidden: true });
      root.append(steps, log, backendTab);

      const noSelection = { isCollapsed: true, anchorNode: null, focusNode: null };
      let selection = noSelection;
      const timers = [];
      const responses = input.polls.slice();
      const context = {
        document, window: { location: { search: '?log=setup' }, getSelection: () => selection },
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
          const preOf = (which) => which === 'full' ? fullPre : which === 'error' ? document.getElementById('error') : accordion(which).querySelector('pre');
          ((input.selections || {})[String(i)] || []).forEach((action) => {
            if (action.select) { const pre = preOf(action.select); selection = { isCollapsed: false, anchorNode: pre, focusNode: pre }; }
            if (action.collapse) { const pre = preOf(action.collapse); selection = { isCollapsed: true, anchorNode: pre, focusNode: pre }; }
            if (action.span) { const pre = preOf(action.span); selection = { isCollapsed: false, anchorNode: null, focusNode: null, containsNode: (n) => n === pre }; }
            if (action.clear) selection = noSelection;
            document.fire('selectionchange');
          });
          out.push({
            order: steps.children.map((c) => c.dataset.stepLog),
            open: Object.fromEntries(steps.children.map((c) => [c.dataset.stepLog, c.open])),
            state: Object.fromEntries(steps.children.map((c) => [c.dataset.stepLog, c.dataset.stepState || null])),
            names: Object.fromEntries(steps.children.filter((c) => c !== fullLog).map((c) => [c.dataset.stepLog, c.children[0].children[1].textContent])),
            outcomes: Object.fromEntries(steps.children.filter((c) => c !== fullLog).map((c) => [c.dataset.stepLog, c.children[0].children[2].textContent])),
            text: Object.fromEntries(steps.children.filter((c) => c !== fullLog).map((c) => [c.dataset.stepLog, c.querySelector('pre').textContent])),
            current: Object.fromEntries(steps.children.filter((c) => c !== fullLog).map((c) => [c.dataset.stepLog, c.attributes['aria-current'] || null])),
            controls: Object.fromEntries(steps.children.filter((c) => c !== fullLog).map((c) => {
              const holder = c.querySelector('.step-log__actions');
              return [c.dataset.stepLog, { hidden: holder.hidden, actions: holder.children.map((f) => f.action), labels: holder.children.map((f) => f.children[0].textContent) }];
            })),
            writes: Object.fromEntries(steps.children.filter((c) => c !== fullLog).map((c) => [c.dataset.stepLog, c.querySelector('pre').writes])),
            fullWrites: fullPre.writes, errorWrites: document.getElementById('error').writes,
            errorText: document.getElementById('error').textContent,
            fullText: fullPre.textContent, tabHidden: backendTab.hidden, fullOutcome: fullOutcome.textContent
          });
        }
        process.stdout.write(JSON.stringify(out));
      })();
    NODE
    out, status = Open3.capture2('node', '-e', script, JSON.generate(polls: polls, userActions: user_actions, serverRendered: server_rendered, selections: selections))
    raise "node failed: #{out}" unless status.success?

    JSON.parse(out)
  end

  def step(key, state, duration = nil)
    { 'key' => key, 'label' => key.capitalize, 'state' => state, 'duration_seconds' => duration }
  end

  def poll(steps, logs = {}, backend: false, tail: '', total: nil, busy: true, resume: nil, error: '')
    { 'presentation' => { 'state' => busy ? 'busy' : 'ready', 'busy' => busy, 'ready' => !busy, 'error' => error, 'steps' => steps, 'total' => total,
                          'resume' => resume,
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

  describe 'accordions rendered by the server' do
    it 'keeps updating step output and state on every poll, with no controls container to start from' do
      first, second = run_polls([poll([step('gems', 'active')], { 'gems' => 'one' }),
                                 poll([step('gems', 'complete', 3.0)], { 'gems' => 'one two' })],
                                server_rendered: %w(gems))

      expect([first['text']['gems'], second['text']['gems']]).to eq(['one', 'one two'])
      expect([first['state']['gems'], second['state']['gems']]).to eq(%w(active complete))
      expect(second['controls']['gems']).to include('hidden' => true)
    end

    it 'shows the controls on a server-rendered accordion once the workspace is idle' do
      resume = { 'step_modes' => { 'gems' => %w(only from) } }
      result = run_polls([poll([step('gems', 'complete', 1.0)], busy: false, resume: resume)], server_rendered: %w(gems))

      expect(result.last['controls']['gems']).to include('hidden' => false, 'labels' => ['Re-run this step', 'Re-run from here'])
    end
  end

  describe 're-run controls' do
    let(:steps) { [step('gems', 'complete', 1.0), step('ready', 'complete', 2.0)] }

    it 'shows only the re-run forms the server allows, aimed at the resume route' do
      resume = { 'step_modes' => { 'gems' => %w(only from), 'ready' => %w(from) } }
      result = run_polls([poll(steps, busy: false, resume: resume)]).last['controls']

      expect(result['gems']).to include('hidden' => false, 'labels' => ['Re-run this step', 'Re-run from here'],
                                        'actions' => ['/workspaces/ws-1/resume?only=gems', '/workspaces/ws-1/resume?from=gems'])
      expect(result['ready']).to include('hidden' => false, 'actions' => ['/workspaces/ws-1/resume?from=ready'])
    end

    it 'hides the controls when nothing can be re-run, and again once a run starts' do
      resume = { 'step_modes' => { 'gems' => %w(only from), 'ready' => %w(from) } }
      polls = [poll(steps, busy: false, resume: resume), poll(steps, busy: true, resume: nil),
               poll(steps, busy: false, resume: { 'step_modes' => { 'gems' => [], 'ready' => [] } })]
      results = run_polls(polls).map { |entry| entry['controls'] }

      expect(results[0]['gems']['hidden']).to be(false)
      expect(results[1]['gems']).to include('hidden' => true, 'actions' => [])
      expect(results[2]['gems']).to include('hidden' => true, 'actions' => [])
    end

    it 'does not rebuild the forms on a poll that changes nothing' do
      resume = { 'step_modes' => { 'gems' => %w(only from), 'ready' => %w(from) } }
      first, second = run_polls([poll(steps, busy: false, resume: resume), poll(steps, busy: false, resume: resume)])

      expect(second['controls']).to eq(first['controls'])
    end

    it 'encodes a step key that needs it' do
      odd = [step('a b&c', 'complete', 1.0)]
      resume = { 'step_modes' => { 'a b&c' => %w(only) } }

      expect(run_polls([poll(odd, busy: false, resume: resume)]).last['controls']['a b&c']['actions'])
        .to eq(['/workspaces/ws-1/resume?only=a%20b%26c'])
    end
  end

  describe 'copying text out of a log' do
    let(:running) { [step('gems', 'active'), step('app', 'pending')] }

    it 'does not rewrite a log whose text has not changed, so a selection in it is never dropped' do
      same = poll(running, { 'gems' => 'installing' }, tail: 'whole setup log', error: 'boom')

      first, second, third = run_polls([same, same, same])

      expect(third['writes']['gems']).to eq(first['writes']['gems'])
      expect(third['fullWrites']).to eq(first['fullWrites'])
      expect(third['errorWrites']).to eq(first['errorWrites'])
      expect(third).to include('fullText' => 'whole setup log', 'errorText' => 'boom')
      expect(second['writes']).to eq(first['writes'])
    end

    it 'leaves a log alone while text in it is selected, then catches up to the latest text once it is not' do
      polls = [poll(running, { 'gems' => 'one' }), poll(running, { 'gems' => "one\ntwo" }),
               poll(running, { 'gems' => "one\ntwo\nthree" })]

      first, second, third = run_polls(polls, selections: { '0' => [{ 'select' => 'gems' }], '2' => [{ 'clear' => true }] })

      expect(first['text']['gems']).to eq('one')
      expect(second['text']['gems']).to eq('one')
      expect(second['writes']['gems']).to eq(first['writes']['gems'])
      expect(third['text']['gems']).to eq("one\ntwo\nthree")
      expect(third['writes']['gems']).to eq(first['writes']['gems'] + 1)
    end

    it 'applies only the newest text when the selection ends, not each one it missed' do
      polls = [poll(running, { 'gems' => 'a' }), poll(running, { 'gems' => 'b' }), poll(running, { 'gems' => 'c' }),
               poll(running, { 'gems' => 'd' })]

      snaps = run_polls(polls, selections: { '0' => [{ 'select' => 'gems' }], '3' => [{ 'clear' => true }] })

      expect(snaps.map { |snap| snap['text']['gems'] }).to eq(%w(a a a d))
      expect(snaps.last['writes']['gems']).to eq(snaps.first['writes']['gems'] + 1)
    end

    it 'only holds the log being read: another step keeps updating' do
      polls = [poll(running, { 'gems' => 'g1', 'app' => 'a1' }), poll(running, { 'gems' => 'g2', 'app' => 'a2' })]

      _, second = run_polls(polls, selections: { '0' => [{ 'select' => 'gems' }] })

      expect(second['text']).to eq('gems' => 'g1', 'app' => 'a2')
    end

    it 'holds a log in the middle of a selection that spans several' do
      polls = [poll(running, { 'gems' => 'g1', 'app' => 'a1' }), poll(running, { 'gems' => 'g2', 'app' => 'a2' })]

      _, second = run_polls(polls, selections: { '0' => [{ 'span' => 'app' }] })

      expect(second['text']).to eq('gems' => 'g2', 'app' => 'a1')
    end

    it 'does not hold a log for a caret with nothing selected' do
      polls = [poll(running, { 'gems' => 'one' }), poll(running, { 'gems' => 'two' })]

      _, second = run_polls(polls, selections: { '0' => [{ 'collapse' => 'gems' }] })

      expect(second['text']['gems']).to eq('two')
    end

    it 'holds the full setup log and the error panel too' do
      polls = [poll(running, {}, tail: 'log one', error: 'error one'), poll(running, {}, tail: 'log two', error: 'error two')]

      selected_full = run_polls(polls, selections: { '0' => [{ 'select' => 'full' }] }).last
      selected_error = run_polls(polls, selections: { '0' => [{ 'select' => 'error' }] }).last

      expect(selected_full).to include('fullText' => 'log one', 'errorText' => 'error two')
      expect(selected_error).to include('fullText' => 'log two', 'errorText' => 'error one')
    end

    it 'does not close a step on completion while text in its log is selected' do
      one = poll([step('gems', 'active'), step('app', 'pending')], { 'gems' => 'installing' })
      two = poll([step('gems', 'complete', 1.5), step('app', 'active')], { 'gems' => 'installing' })

      _, second = run_polls([one, two], selections: { '0' => [{ 'select' => 'gems' }] })

      expect(second['open']['gems']).to eq(true)
      expect(second['open']['app']).to eq(true)
    end

    it 'closes the completed step once the selection is gone' do
      one = poll([step('gems', 'active'), step('app', 'pending')], { 'gems' => 'installing' })
      two = poll([step('gems', 'complete', 1.5), step('app', 'active')], { 'gems' => 'installing' })
      three = poll([step('gems', 'complete', 1.5), step('app', 'active')], { 'gems' => 'installing' })

      _, second, third = run_polls([one, two, three], selections: { '0' => [{ 'select' => 'gems' }], '2' => [{ 'clear' => true }] })

      expect(second['open']['gems']).to eq(true)
      expect(third['open']['gems']).to eq(false)
    end

    it 'still updates a log normally when nothing is selected' do
      polls = [poll(running, { 'gems' => 'one' }, tail: 'a'), poll(running, { 'gems' => 'two' }, tail: 'b')]

      _, second = run_polls(polls)

      expect(second['text']['gems']).to eq('two')
      expect(second['fullText']).to eq('b')
    end
  end
end
