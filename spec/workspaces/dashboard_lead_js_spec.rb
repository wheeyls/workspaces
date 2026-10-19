require_relative 'spec_helper'
require 'json'

# Drives app.js against a tiny fake DOM to check what the polling script does when the
# workspace changes state: re-render the friendly lead, swap the lead action, and open
# the right disclosure, without a page reload.
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
        id: 'ws-1', busy: 'false', disclosureState: input.initial } }));
      const mk = (tag, id, o = {}) => document.reg(new Node(tag, { id, ...o }));
      const status = mk('h2', 'status'), summary = mk('p', 'summary');
      const subtitle = mk('p', 'subtitle', { hidden: true });
      const subtitleText = mk('span', 'subtitle-text');
      const activity = mk('span', 'activity', { hidden: true }), elapsed = mk('span', 'elapsed');
      const preview = mk('a', 'preview', { hidden: true });
      const leadAction = mk('div', 'lead-action', { className: 'lead__action' });
      const message = mk('p', 'message', { hidden: true });
      const error = mk('pre', 'error'), errorPanel = mk('section', 'error-panel', { hidden: true });
      const connection = mk('p', 'connection');
      const envTitle = mk('span', 'environment-title');
      const presetBadge = mk('span', 'environment-preset-badge', { hidden: true });
      const envDisclosure = mk('details', 'environment-disclosure', { dataset: { section: '' } });
      const techDisclosure = mk('details', 'technical-disclosure', { dataset: { section: '' } });
      const progress = mk('ol', 'progress', { dataset: { section: '' } });
      const actions = mk('div', 'actions', { className: 'workspace-actions' });
      const srcMsg = mk('p', 'source-update-message');
      const log = mk('pre', 'log'); log.clientHeight = 1; log.scrollHeight = 1; log.scrollTop = 0;
      const updated = mk('time', 'updated');
      root.append(status, summary, subtitle, subtitleText, activity, elapsed, preview, leadAction, message, error, errorPanel,
        connection, envTitle, presetBadge, envDisclosure, techDisclosure, progress, actions, srcMsg, log, updated);

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
            subtitleHidden: subtitle.hidden, subtitleText: subtitleText.textContent,
            previewHidden: preview.hidden,
            leadAction: leadAction.children[0] ? { action: leadAction.children[0].action,
              label: leadAction.children[0].children[0].textContent,
              klass: leadAction.children[0].children[0].className } : null,
            envOpen: envDisclosure.open, techOpen: techDisclosure.open,
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

  def poll(state, **extra)
    presentation = { 'state' => state, 'busy' => state == 'busy', 'ready' => state == 'ready', 'error' => '',
                     'steps' => [], 'actions' => [], 'sections' => {},
                     'headline' => "headline for #{state}", 'summary' => "summary for #{state}",
                     'subtitle' => nil, 'lead_action' => nil, 'environment_title' => 'Change settings',
                     'environment_submit' => 'Save & restart',
                     'open' => { 'environment' => false, 'technical' => false } }.merge(extra)
    { 'presentation' => presentation, 'message' => 'm', 'source_update_message' => '', 'editable_environment' => {},
      'log_source' => 'setup', 'log_tail' => '', 'updated_at' => 'now',
      'prepare_started_at' => '2026-10-05T00:00:00Z', 'completed_at' => '2026-10-05T00:01:00Z' }
  end

  it 'moves from setting up to ready without a reload: new headline, Open button, details stay collapsed' do
    busy = poll('busy', 'subtitle' => 'Install Ruby dependencies', 'open' => { 'environment' => false, 'technical' => true })
    ready = poll('ready', 'lead_action' => { 'kind' => 'open', 'label' => 'Open workspace' },
                          'open' => { 'environment' => false, 'technical' => false })

    first, second = run_scenarios(initial_state: 'idle', polls: [busy, ready])

    expect(first).to include('headline' => 'headline for busy', 'subtitleHidden' => false,
                             'subtitleText' => 'Install Ruby dependencies', 'previewHidden' => true,
                             'techOpen' => true, 'envOpen' => false)
    expect(second).to include('headline' => 'headline for ready', 'subtitleHidden' => true,
                              'previewHidden' => false, 'techOpen' => false, 'leadAction' => nil)
  end

  it 'shows a large retry button and opens technical details when setup fails' do
    error = poll('error', 'lead_action' => { 'kind' => 'post', 'key' => 'prepare', 'label' => 'Retry setup', 'primary' => true },
                          'open' => { 'environment' => false, 'technical' => true })

    snap, = run_scenarios(initial_state: 'busy', polls: [error])

    expect(snap).to include('techOpen' => true, 'previewHidden' => true)
    expect(snap['leadAction']).to include('action' => '/workspaces/ws-1/prepare', 'label' => 'Retry setup',
                                          'klass' => 'button button--primary button--large')
  end

  it 'applies a disclosure preference only when the state changes, so a user-opened section stays open on later polls' do
    ready = poll('ready')
    snaps = run_scenarios(initial_state: 'ready', polls: [ready, ready])

    expect(snaps.map { |s| s['techOpen'] }).to eq([false, false])
    expect(snaps.map { |s| s['headline'] }).to eq(['headline for ready', 'headline for ready'])
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
