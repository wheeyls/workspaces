# frozen_string_literal: true

require_relative 'spec_helper'
require 'json'

# The card has only a few of the page's elements. This runs app.js against exactly that set, to check
# the polling script does not assume the settings page's controls exist.
RSpec.describe 'card page script' do
  def run_card(polls)
    script = <<~'NODE'
      const fs = require('node:fs');
      const vm = require('node:vm');
      const input = JSON.parse(process.argv[1]);
      class Node {
        constructor(tag, o = {}) {
          Object.assign(this, { tagName: tag.toUpperCase(), id: o.id || null, dataset: o.dataset || {}, attributes: {},
            className: o.className || '', textContent: '', hidden: !!o.hidden, disabled: false, children: [],
            listeners: {}, parentNode: null, style: {} });
        }
        append(...c) { c.flat().forEach((x) => { x.parentNode = this; this.children.push(x); }); }
        setAttribute(n, v) { this.attributes[n] = v; }
        removeAttribute(n) { delete this.attributes[n]; }
        replaceChildren(...c) { this.children = []; this.append(...c); }
        addEventListener(t, h) { (this.listeners[t] ||= []).push(h); }
        querySelectorAll(sel) {
          const out = []; const parts = sel.split(',').map((s) => s.trim());
          const visit = (n) => n.children.forEach((c) => { if (parts.some((p) => match(c, p))) out.push(c); visit(c); });
          visit(this); return out;
        }
        querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
      }
      const match = (n, sel) => (sel === '[data-only-state]' ? 'onlyState' in n.dataset
        : sel === '[data-section]' ? 'section' in n.dataset : false);
      const byId = {};
      const mk = (tag, id, o = {}) => { const n = new Node(tag, { id, ...o }); byId[id] = n; return n; };
      const root = mk('main', 'workspace', { dataset: { id: 'ws-1', busy: 'false' } });
      const start = new Node('form', { dataset: { onlyState: 'idle' } });
      const kids = [mk('h1', 'status'), mk('p', 'summary'), mk('span', 'environment-preset-badge', { hidden: true }),
        mk('div', 'build-progress', { hidden: true }), mk('div', 'progress-bar'), mk('span', 'progress-fill'),
        mk('span', 'progress-step'), mk('span', 'progress-percent'), mk('span', 'progress-eta'), mk('span', 'elapsed'),
        mk('a', 'preview', { hidden: true }), mk('div', 'lead-action', { className: 'lead__action' }),
        mk('p', 'sleep-note', { hidden: true }), mk('pre', 'error'), mk('section', 'error-panel', { hidden: true }),
        mk('p', 'connection'), start];
      root.append(...kids);
      const timers = []; const responses = input.polls.slice();
      const context = {
        document: { getElementById: (id) => byId[id] || null, createElement: (t) => new Node(t), activeElement: null },
        window: { location: { search: '', pathname: '/workspaces/ws-1' } },
        URLSearchParams: class { get() { return null; } },
        fetch: () => Promise.resolve({ ok: true, json: async () => responses.shift() }),
        AbortController: class { constructor() { this.signal = {}; } abort() {} },
        setTimeout(cb, d) { timers.push({ cb, d }); return timers.length; }, clearTimeout() {},
        Date, JSON, Math, Number, console
      };
      vm.runInNewContext(fs.readFileSync('lib/workspaces/dashboard/app.js', 'utf8'), context);
      (async () => {
        const snaps = [];
        for (let i = 0; i < input.polls.length; i++) {
          const at = timers.findIndex((t) => t.cb.name === 'poll');
          if (at < 0) throw new Error('no poll scheduled');
          await timers.splice(at, 1)[0].cb(); await new Promise((r) => setImmediate(r));
          snaps.push({ headline: byId.status.textContent, connection: byId.connection.textContent,
            previewHidden: byId.preview.hidden, startHidden: start.hidden,
            badgeHidden: byId['environment-preset-badge'].hidden, badge: byId['environment-preset-badge'].textContent,
            errorHidden: byId['error-panel'].hidden, error: byId.error.textContent,
            lead: byId['lead-action'].children[0] ? byId['lead-action'].children[0].action : null });
        }
        process.stdout.write(JSON.stringify(snaps));
      })();
    NODE
    out, status = Open3.capture2('node', '-e', script, JSON.generate(polls: polls))
    raise "node failed: #{out}" unless status.success?

    JSON.parse(out)
  end

  def poll(state, extra = {})
    presentation = { 'state' => state, 'busy' => state == 'busy', 'ready' => state == 'ready', 'error' => '',
                     'steps' => [], 'actions' => [], 'sections' => {}, 'headline' => "headline for #{state}",
                     'summary' => '', 'progress' => nil, 'lead_action' => nil, 'current_preset' => nil,
                     'open' => {} }.merge(extra)
    { 'presentation' => presentation, 'message' => '', 'log_source' => 'setup', 'log_tail' => '',
      'prepare_started_at' => '2026-10-05T00:00:00Z', 'completed_at' => '2026-10-05T00:01:00Z' }
  end

  it 'updates without the settings-only elements, and shows the start form only while idle' do
    idle, busy, ready = run_card([poll('idle'), poll('busy'), poll('ready')])

    expect(idle).to include('headline' => 'headline for idle', 'startHidden' => false, 'connection' => '')
    expect(busy).to include('headline' => 'headline for busy', 'startHidden' => true, 'connection' => '')
    expect(ready).to include('previewHidden' => false, 'startHidden' => true, 'connection' => '')
  end

  it 'shows the preset and the error, and offers the lifecycle action after a failure' do
    failed = poll('error', 'error' => 'bundle failed', 'current_preset' => 'marketplace',
                           'lead_action' => { 'kind' => 'post', 'key' => 'start', 'label' => 'Retry' })

    snap, = run_card([failed])

    expect(snap).to include('badge' => 'Preset: marketplace', 'badgeHidden' => false, 'errorHidden' => false,
                            'error' => 'bundle failed', 'lead' => '/workspaces/ws-1/start')
  end
end
