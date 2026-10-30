require_relative 'spec_helper'
require 'json'

# Drives app.js against a tiny fake DOM to check what the polling script does when the
# workspace changes state: re-render the friendly lead and swap the lead action without a
# page reload.
RSpec.describe 'dashboard lead rendering' do
  def run_scenarios(initial_state:, polls:)
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
          this.firstChild = opts.text ? { nodeType: 3, textContent: opts.text } : null;
        }
        append(...c) { c.flat().forEach((x) => { x.parentNode = this; this.children.push(x); }); }
        setAttribute(n, v) { this.attributes[n] = v; }
        removeAttribute(n) { delete this.attributes[n]; }
        replaceChildren(...c) { this.children = []; this.append(...c); }
        addEventListener(t, h) { (this.listeners[t] ||= []).push(h); }
        querySelectorAll(sel) {
          const out = [];
          const parts = sel.split(',').map((s) => s.trim());
          const visit = (n) => n.children.forEach((c) => {
            if (parts.some((p) => match(c, p))) out.push(c);
            visit(c);
          });
          visit(this); return out;
        }
        querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
      }
      function match(n, sel) {
        if (sel === '[data-section]') return 'section' in n.dataset;
        if (sel === '.workspace-actions button') return n.tagName === 'BUTTON' && inClass(n, 'workspace-actions');
        if (sel === '.lead__action button') return n.tagName === 'BUTTON' && inClass(n, 'lead__action');
        return false;
      }
      function inClass(n, c) { for (let p = n.parentNode; p; p = p.parentNode) if ((p.className || '').split(/\s+/).includes(c)) return true; return false; }

      class Doc {
        constructor() { this.byId = {}; this.activeElement = null; }
        reg(n) { if (n.id) this.byId[n.id] = n; n.children.forEach((c) => this.reg(c)); return n; }
        getElementById(id) { return this.byId[id] || null; }
        createElement(t) { return new Node(t); }
      }
      const document = new Doc();
      const root = document.reg(new Node('main', { id: 'workspace', dataset: {
        id: 'ws-1', busy: 'false' } }));
      const mk = (tag, id, o = {}) => document.reg(new Node(tag, { id, ...o }));
      const status = mk('h2', 'status'), summary = mk('p', 'summary');
      const buildProgress = mk('div', 'build-progress', { hidden: true });
      const bar = mk('div', 'progress-bar'); const fill = mk('span', 'progress-fill');
      fill.style = {};
      const barStep = mk('span', 'progress-step'), barPercent = mk('span', 'progress-percent'), barEta = mk('span', 'progress-eta');
      const activity = mk('span', 'activity', { hidden: true }), elapsed = mk('span', 'elapsed');
      const preview = mk('a', 'preview', { hidden: true });
      const leadAction = mk('div', 'lead-action', { className: 'lead__action' });
      const message = mk('p', 'message', { hidden: true });
      const error = mk('pre', 'error'), errorPanel = mk('section', 'error-panel', { hidden: true });
      const connection = mk('p', 'connection');
      const envTitle = mk('span', 'environment-title');
      const presetBadge = mk('span', 'environment-preset-badge', { hidden: true });
      const progress = mk('ol', 'progress', { dataset: { section: '' } });
      const actions = mk('div', 'actions', { className: 'workspace-actions' });
      const srcMsg = mk('p', 'source-update-message');
      const log = mk('pre', 'log'); log.clientHeight = 1; log.scrollHeight = 1; log.scrollTop = 0;
      const updated = mk('time', 'updated');
      root.append(status, summary, buildProgress, bar, fill, barStep, barPercent, barEta, activity, elapsed, preview, leadAction, message, error, errorPanel,
        connection, envTitle, presetBadge, progress, actions, srcMsg, log, updated);

      const timers = []; const responses = input.polls.slice();
      const context = {
        document, window: { location: { search: '?log=setup' } },
        URLSearchParams: class { constructor() {} get() { return 'setup'; } },
        fetch: () => Promise.resolve({ ok: true, json: async () => responses.shift() }),
        AbortController: class { constructor() { this.signal = {}; } abort() {} },
        setTimeout(cb, d) { timers.push({ cb, d }); return timers.length; }, clearTimeout() {},
        Date, JSON, Math, Number, console
      };
      vm.runInNewContext(fs.readFileSync('lib/workspaces/dashboard/app.js', 'utf8'), context);

      (async () => {
        const snaps = [];
        for (let i = 0; i < input.polls.length; i++) {
          // app.js schedules both a clock tick and the status poll; run the next poll only.
          const at = timers.findIndex((t) => t.cb.name === 'poll');
          if (at < 0) throw new Error('no poll scheduled');
          const poll = timers.splice(at, 1)[0]; await poll.cb(); await new Promise((r) => setImmediate(r));
          snaps.push({
            headline: status.textContent, summary: summary.textContent,
            barHidden: buildProgress.hidden, barNow: bar.attributes['aria-valuenow'], barFill: fill.style.inlineSize,
            barStep: barStep.textContent, barPercent: barPercent.textContent, barEta: barEta.textContent,
            barSlow: bar.dataset.slow, barText: bar.attributes['aria-valuetext'],
            previewHidden: preview.hidden,
            leadAction: leadAction.children[0] ? { action: leadAction.children[0].action,
              label: leadAction.children[0].children[0].textContent,
              klass: leadAction.children[0].children[0].className } : null,
            envTitle: envTitle.textContent,
            badgeHidden: presetBadge.hidden, badgeText: presetBadge.textContent
          });
        }
        process.stdout.write(JSON.stringify(snaps));
      })();
    NODE
    out, status = Open3.capture2('node', '-e', script, JSON.generate(initial: initial_state, polls: polls))
    raise "node failed: #{out}" unless status.success?

    JSON.parse(out)
  end

  def poll(state, extra = {})
    presentation = { 'state' => state, 'busy' => state == 'busy', 'ready' => state == 'ready', 'error' => '',
                     'steps' => [], 'actions' => [], 'sections' => {},
                     'headline' => "headline for #{state}", 'summary' => "summary for #{state}",
                     'progress' => nil, 'lead_action' => nil, 'environment_title' => 'Change settings',
                     'environment_submit' => 'Save & restart' }.merge(extra)
    { 'presentation' => presentation, 'message' => 'm', 'source_update_message' => '', 'editable_environment' => {},
      'log_source' => 'setup', 'log_tail' => '', 'updated_at' => 'now',
      'prepare_started_at' => '2026-10-05T00:00:00Z', 'completed_at' => '2026-10-05T00:01:00Z' }
  end

  it 'moves from setting up to ready without a reload: new headline and the Open button' do
    busy = poll('busy')
    ready = poll('ready', 'lead_action' => { 'kind' => 'open', 'label' => 'Open workspace' })

    first, second = run_scenarios(initial_state: 'idle', polls: [busy, ready])

    expect(first).to include('headline' => 'headline for busy', 'previewHidden' => true)
    expect(second).to include('headline' => 'headline for ready', 'barHidden' => true,
                              'previewHidden' => false, 'leadAction' => nil)
  end

  it 'draws the progress bar the server computed, marks a slow step, and hides the bar when the run ends' do
    working = poll('busy', 'progress' => { 'percent' => 42, 'step_label' => 'Install gems', 'step_text' => 'Step 2 of 5',
                                           'eta_text' => 'About 1m 10s left', 'slow' => false, 'elapsed_seconds' => 80 })
    slow = poll('busy', 'progress' => { 'percent' => 61, 'step_label' => 'Build assets', 'step_text' => 'Step 4 of 5',
                                        'eta_text' => 'Taking longer than usual', 'slow' => true, 'elapsed_seconds' => 400 })
    done = poll('ready')

    a, b, c = run_scenarios(initial_state: 'busy', polls: [working, slow, done])

    expect(a).to include('barHidden' => false, 'barNow' => '42', 'barFill' => '42%', 'barPercent' => '42%',
                         'barStep' => 'Step 2 of 5 · Install gems', 'barEta' => ' · About 1m 10s left', 'barSlow' => 'false',
                         'barText' => 'Step 2 of 5 · Install gems. About 1m 10s left')
    expect(b).to include('barNow' => '61', 'barSlow' => 'true', 'barEta' => ' · Taking longer than usual')
    expect(c).to include('barHidden' => true)
  end

  it 'shows a large retry button when setup fails' do
    error = poll('error', 'lead_action' => { 'kind' => 'post', 'key' => 'prepare', 'label' => 'Retry setup', 'primary' => true })

    snap, = run_scenarios(initial_state: 'busy', polls: [error])

    expect(snap).to include('previewHidden' => true)
    expect(snap['leadAction']).to include('action' => '/workspaces/ws-1/prepare', 'label' => 'Retry setup',
                                          'klass' => 'button button--primary button--large')
  end

  it 'shows, updates and clears the current preset badge as the settings change, without a reload' do
    none = poll('ready')
    www = poll('ready', 'current_preset' => 'www')
    admin = poll('ready', 'current_preset' => 'admin')

    a, b, c, d = run_scenarios(initial_state: 'ready', polls: [none, www, admin, none])

    expect([a, b, c, d].map { |s| [s['badgeHidden'], s['badgeText']] })
      .to eq([[true, ''], [false, 'Preset: www'], [false, 'Preset: admin'], [true, '']])
  end

  it 'does not rebuild the lead action when nothing changed' do
    stopped = poll('stopped', 'lead_action' => { 'kind' => 'post', 'key' => 'start', 'label' => 'Start workspace', 'primary' => true })

    first, second = run_scenarios(initial_state: 'stopped', polls: [stopped, stopped])

    expect(first['leadAction']).to eq(second['leadAction'])
    expect(first['leadAction']).to include('label' => 'Start workspace')
  end
end
