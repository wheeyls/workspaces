require_relative 'spec_helper'
require 'json'

# Drives environment.js against a small fake DOM: variable rows with a Secret checkbox, add and
# remove, presets, and the busy state. The rows' markup itself is covered by the view specs.
RSpec.describe 'dashboard environment rows' do
  PRELUDE = <<~'NODE'.freeze
    const fs = require('node:fs');
    const vm = require('node:vm');

    class Node {
      constructor(tag, opts = {}) {
        this.tagName = tag.toUpperCase(); this.id = opts.id || null;
        this.attributes = { ...(opts.attributes || {}) }; this.className = opts.className || '';
        this.dataset = opts.dataset || {}; this.children = []; this.parentNode = null; this.listeners = {};
        this.hidden = !!opts.hidden; this.disabled = false; this.value = opts.value || ''; this.type = opts.type || 'text';
        this.name = opts.name || ''; this.placeholder = opts.placeholder || ''; this.autocomplete = '';
        this.checked = !!opts.checked; this.textContent = opts.textContent || '';
        this.classList = { add: () => {}, remove: () => {} };
      }
      get innerHTML() { return this._html || ''; }
      set innerHTML(html) {
        this._html = html;
        const match = /env\[(\d+)\]\[name\]/.exec(html);
        if (match) this.append(makeRow(match[1], { name: '', value: '' }));
      }
      append(...nodes) { nodes.flat().forEach((n) => { n.parentNode = this; this.children.push(n); }); }
      insertBefore(node, ref) {
        node.parentNode = this;
        const at = ref ? this.children.indexOf(ref) : -1;
        if (at < 0) this.children.push(node); else this.children.splice(at, 0, node);
        return node;
      }
      removeChild(n) { this.children = this.children.filter((c) => c !== n); n.parentNode = null; }
      setAttribute(k, v) { this.attributes[k] = v; }
      removeAttribute(k) { delete this.attributes[k]; }
      hasAttribute(k) { return k in this.attributes; }
      addEventListener(t, h) { (this.listeners[t] ||= []).push(h); }
      dispatchEvent(event) {
        event.target = event.target || this;
        for (let n = this; n; n = n.parentNode) (n.listeners[event.type] || []).forEach((h) => h.call(n, event));
      }
      matches(sel) {
        const m = /^\[([a-z-]+)\]$/.exec(sel); if (m) return m[1] in this.attributes;
        const c = /^\.(.+)$/.exec(sel); if (c) return this.className.split(/\s+/).includes(c[1]);
        return false;
      }
      querySelectorAll(sel) {
        const out = []; const visit = (n) => n.children.forEach((k) => { if (k.matches(sel)) out.push(k); visit(k); });
        visit(this); return out;
      }
      querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
      contains(n) { for (let x = n; x; x = x.parentNode) if (x === this) return true; return false; }
      focus() { document.activeElement = this; }
    }

    function makeRow(index, entry, opts = {}) {
      const row = new Node('div', { attributes: { 'data-env-row': '' } });
      if (opts.secret) row.setAttribute('data-secret', 'true');
      if (opts.stored) row.setAttribute('data-stored', 'true');
      const name = new Node('input', { className: 'env-row__name', name: 'env[' + index + '][name]', value: entry.name });
      const secret = new Node('input', { attributes: { 'data-env-secret': '' }, type: 'checkbox', checked: !!opts.secret });
      secret.disabled = !!opts.stored;
      const remove = new Node('button', { attributes: { 'data-env-remove-row': '' }, hidden: true });
      if (opts.stored) {
        // A stored secret: no value input, a note, and a Replace button (as the server renders it).
        const stored = new Node('span', { attributes: { 'data-env-stored': '' } });
        stored.append(new Node('button', { attributes: { 'data-env-replace': '' }, hidden: true }));
        row.append(name, stored, secret, remove);
      } else {
        const value = new Node('input', { attributes: { 'data-env-value': '' }, name: 'env[' + index + '][value]',
          type: opts.secret ? 'password' : 'text', value: entry.value });
        row.append(name, value, secret, remove);
      }
      return row;
    }

    const document = {
      byId: {}, activeElement: null,
      getElementById(id) { return this.byId[id] || null; },
      createElement(tag) { return new Node(tag); }
    };
    const reg = (n) => { if (n.id) document.byId[n.id] = n; return n; };

    function build(input) {
      const root = reg(new Node('main', { id: 'workspace', dataset: { busy: input.busy ? 'true' : 'false' } }));
      const form = reg(new Node('form', { id: 'environment-form',
        dataset: { environmentPresets: JSON.stringify(input.presets || {}) } }));
      const fieldset = new Node('fieldset', { attributes: { 'data-environment-fieldset': '' } });
      const presetGroup = new Node('div', { hidden: true, attributes: { 'data-preset-controls': '' } });
      const presetButtons = Object.keys(input.presets || {}).map((name) => {
        const b = new Node('button', { attributes: { 'data-environment-preset': name, 'aria-pressed': 'false' } });
        b.dataset.environmentPreset = name; return b;
      });
      presetGroup.append(...presetButtons);
      const rows = reg(new Node('div', { id: 'env-rows' }));
      (input.rows || []).forEach((r, i) => rows.append(makeRow(i, r, r)));
      const addButton = new Node('button', { attributes: { 'data-env-add-row': '' }, hidden: true });
      const template = reg(new Node('template', { id: 'env-row-template' }));
      template.innerHTML = '<div env[__INDEX__][name]>';
      const submit = new Node('button', { attributes: { 'data-env-submit': '' }, textContent: 'Save & restart' });
      const status = reg(new Node('p', { id: 'environment-status' }));
      fieldset.append(presetGroup, rows, addButton);
      form.append(fieldset, submit, status);
      form.querySelectorAll = ((orig) => (sel) => sel === '[data-submit-label]' ? [] : orig.call(form, sel))(form.querySelectorAll);
      root.append(form);
      reg(root);
      return { root, form, fieldset, rows, addButton, submit, status, presetButtons, presetGroup };
    }

    function load(dom) {
      const context = { document, window: {}, JSON, Math, Number, console, setTimeout() {}, clearTimeout() {} };
      vm.runInNewContext(fs.readFileSync('lib/workspaces/dashboard/environment.js', 'utf8'), context);
      return context.window.WorkspaceEnvironment;
    }

    const rowState = (rows) => rows.children.map((r) => {
      const v = r.querySelector('[data-env-value]') || { value: '', type: null, placeholder: null };
      return {
      name: r.querySelector('.env-row__name').value, value: v.value, hasValueInput: !!r.querySelector('[data-env-value]'),
      type: v.type, secret: r.querySelector('[data-env-secret]').checked,
      locked: r.querySelector('[data-env-secret]').disabled, placeholder: v.placeholder,
      field: r.querySelector('.env-row__name').name, dataSecret: r.hasAttribute('data-secret'),
      removeHidden: r.querySelector('[data-env-remove-row]').hidden
    }; });
    const click = (n) => n.dispatchEvent({ type: 'click' });
    const type = (n, v) => { n.value = v; n.dispatchEvent({ type: 'input', target: n }); };
    const tick = (n, v) => { n.checked = v; n.dispatchEvent({ type: 'change', target: n }); };
  NODE

  def run(input, scenario)
    script = "#{PRELUDE}\nconst input = #{JSON.generate(input)};\nconst dom = build(input);\nconst api = load(dom);\nconst out = {};\n#{scenario}\nprocess.stdout.write(JSON.stringify(out));"
    output, status = Open3.capture2('node', '-e', script, chdir: File.join(__dir__, '../..'))
    raise "node failed: #{output}" unless status.success?

    JSON.parse(output)
  end

  let(:rows) do
    [{ 'name' => 'UE_APP', 'value' => 'www' }, { 'name' => 'STRIPE_KEY', 'value' => '', 'secret' => true, 'stored' => true }]
  end
  let(:presets) { { 'Admin' => [{ 'name' => 'UE_APP', 'value' => 'admin' }], 'Www' => [{ 'name' => 'UE_APP', 'value' => 'www' }] } }

  it 'reveals the add and remove controls, which a no-script page does not need' do
    result = run({ 'rows' => rows }, 'out.add = dom.addButton.hidden; out.rows = rowState(dom.rows);')

    expect(result['add']).to be(false)
    expect(result['rows'].map { |row| row['removeHidden'] }).to eq([false, false])
  end

  it 'adds an empty row that continues the numbering and takes focus' do
    result = run({ 'rows' => rows }, 'click(dom.addButton); out.rows = rowState(dom.rows); out.focus = document.activeElement.name;')

    expect(result['rows'].last).to include('field' => 'env[2][name]', 'name' => '', 'value' => '', 'type' => 'text',
                                           'secret' => false)
    expect(result['focus']).to eq('env[2][name]')
  end

  it 'removes a row, and the draft is then announced as unsaved' do
    result = run({ 'rows' => rows }, 'click(dom.rows.children[0].querySelector("[data-env-remove-row]")); out.rows = rowState(dom.rows).map((r) => r.name); out.status = dom.status.textContent;')

    expect(result['rows']).to eq(%w(STRIPE_KEY))
    expect(result['status']).to start_with('Draft updated locally and not saved yet')
  end

  it 'turns a value into a password field when Secret is ticked, and back when it is cleared' do
    result = run({ 'rows' => rows }, <<~JS)
      const secret = dom.rows.children[0].querySelector('[data-env-secret]');
      tick(secret, true); out.on = rowState(dom.rows)[0];
      tick(secret, false); out.off = rowState(dom.rows)[0];
    JS

    expect(result['on']).to include('type' => 'password', 'dataSecret' => true, 'placeholder' => 'Value')
    expect(result['off']).to include('type' => 'text', 'dataSecret' => false, 'placeholder' => 'value')
  end

  let(:rows) do
    [{ 'name' => 'UE_APP', 'value' => 'www' }, { 'name' => 'STRIPE_KEY', 'value' => '', 'secret' => true, 'stored' => true }]
  end

  it 'shows a stored secret with no value input, locked as a secret' do
    result = run({ 'rows' => rows }, 'out.row = rowState(dom.rows)[1];')

    expect(result['row']).to include('name' => 'STRIPE_KEY', 'hasValueInput' => false, 'locked' => true, 'secret' => true)
  end

  describe 'Replace' do
    it 'is revealed by script, and adds an empty password input that is hidden from password managers' do
      result = run({ 'rows' => rows }, <<~JS)
        const row = dom.rows.children[1];
        out.replaceHidden = row.querySelector('[data-env-replace]').hidden;
        click(row.querySelector('[data-env-replace]'));
        const replacement = row.querySelector('[data-env-value]');
        out.row = rowState(dom.rows)[1];
        out.attrs = replacement.attributes; out.autocomplete = replacement.autocomplete;
        out.storedGone = !row.querySelector('[data-env-stored]');
        out.focus = document.activeElement === replacement;
      JS

      expect(result['replaceHidden']).to be(false)
      expect(result['row']).to include('hasValueInput' => true, 'type' => 'password', 'value' => '',
                                       'field' => 'env[1][name]', 'placeholder' => 'New value (leave blank to keep)')
      expect(result['storedGone']).to be(true)
      expect(result['focus']).to be(true)
      expect(result['autocomplete']).to eq('off')
      expect(result['attrs']).to include('autocomplete' => 'off', 'data-1p-ignore' => '', 'data-lpignore' => 'true',
                                         'data-bwignore' => '')
    end

    it 'names the new input after its row so the value posts with the right secret' do
      result = run({ 'rows' => rows }, <<~JS)
        click(dom.rows.children[1].querySelector('[data-env-replace]'));
        out.name = dom.rows.children[1].querySelector('[data-env-value]').name;
      JS

      expect(result['name']).to eq('env[1][value]')
    end

    it 'does nothing while the workspace is busy' do
      result = run({ 'rows' => rows }, <<~JS)
        api.toggleBusy(true);
        click(dom.rows.children[1].querySelector('[data-env-replace]'));
        out.has = !!dom.rows.children[1].querySelector('[data-env-value]');
      JS

      expect(result['has']).to be(false)
    end

    it 'counts a replaced secret as an unsaved edit without repeating what was typed' do
      result = run({ 'rows' => rows }, <<~JS)
        click(dom.rows.children[1].querySelector('[data-env-replace]'));
        type(dom.rows.children[1].querySelector('[data-env-value]'), 'sk_live_topsecret');
        out.status = dom.status.textContent;
      JS

      expect(result['status']).to start_with('Draft updated locally and not saved yet')
      expect(result['status']).not_to include('sk_live_topsecret')
    end
  end

  it 'asks password managers to ignore the inputs of a newly added row' do
    result = run({ 'rows' => rows }, <<~JS)
      click(dom.addButton);
      const added = dom.rows.children[dom.rows.children.length - 1];
      tick(added.querySelector('[data-env-secret]'), true);
      out.attrs = added.querySelector('[data-env-value]').attributes;
      out.autocomplete = added.querySelector('[data-env-value]').autocomplete;
    JS

    expect(result['autocomplete']).to eq('off')
    expect(result['attrs']).to include('data-1p-ignore' => '', 'data-lpignore' => 'true', 'data-bwignore' => '')
  end

  it 'never repeats what is typed into a secret in the status message or anywhere else on the page' do
    result = run({ 'rows' => rows }, <<~JS)
      click(dom.rows.children[1].querySelector('[data-env-replace]'));
      type(dom.rows.children[1].querySelector('[data-env-value]'), 'sk_live_topsecret');
      out.status = dom.status.textContent;
      out.rowsWithValue = rowState(dom.rows).filter((r) => r.value === 'sk_live_topsecret').length;
      out.attrs = JSON.stringify(dom.rows.children[1].attributes);
    JS

    expect(result['status']).not_to include('sk_live_topsecret')
    expect(result['attrs']).not_to include('sk_live_topsecret')
    expect(result['rowsWithValue']).to eq(1)
  end

  describe 'presets' do
    it 'replaces the visible variables and keeps every secret row, without submitting' do
      result = run({ 'rows' => rows, 'presets' => presets }, <<~JS)
        const submits = []; dom.form.addEventListener('submit', (e) => submits.push(1));
        click(dom.presetButtons[0]);
        out.rows = rowState(dom.rows); out.status = dom.status.textContent; out.submits = submits.length;
        out.pressed = dom.presetButtons.map((b) => b.attributes['aria-pressed']);
      JS

      expect(result['rows'].map { |row| [row['name'], row['value'], row['secret']] })
        .to eq([['STRIPE_KEY', '', true], ['UE_APP', 'admin', false]])
      expect(result['status']).to eq('Preset loaded into draft only. Use Save & restart to apply changes.')
      expect(result['submits']).to eq(0)
      expect(result['pressed']).to eq(%w(true false))
    end

    it 'matches on the visible rows alone, so adding a secret does not unselect a preset' do
      result = run({ 'rows' => rows, 'presets' => presets }, <<~JS)
        click(dom.presetButtons[0]);
        click(dom.addButton);
        const added = dom.rows.children[dom.rows.children.length - 1];
        type(added.querySelector('.env-row__name'), 'NEW_SECRET'); type(added.querySelector('[data-env-value]'), 'x');
        tick(added.querySelector('[data-env-secret]'), true);
        out.pressed = dom.presetButtons.map((b) => b.attributes['aria-pressed']);
      JS

      expect(result['pressed']).to eq(%w(true false))
    end

    it 'unselects the preset as soon as a visible value is edited' do
      result = run({ 'rows' => rows, 'presets' => presets }, <<~JS)
        click(dom.presetButtons[0]);
        type(dom.rows.children[1].querySelector('[data-env-value]'), 'other');
        out.pressed = dom.presetButtons.map((b) => b.attributes['aria-pressed']);
      JS

      expect(result['pressed']).to eq(%w(false false))
    end
  end

  describe 'while the workspace is busy' do
    it 'disables the form and ignores add, remove and preset clicks' do
      result = run({ 'rows' => rows, 'presets' => presets }, <<~JS)
        api.toggleBusy(true);
        click(dom.addButton); click(dom.presetButtons[0]); click(dom.rows.children[0].querySelector('[data-env-remove-row]'));
        out.rows = rowState(dom.rows).map((r) => r.name);
        out.fieldset = dom.fieldset.disabled; out.submit = dom.submit.disabled;
        out.presets = dom.presetButtons.map((b) => b.disabled);
        api.toggleBusy(false); out.presetsAfter = dom.presetButtons.map((b) => b.disabled);
      JS

      expect(result['rows']).to eq(%w(UE_APP STRIPE_KEY))
      expect(result).to include('fieldset' => true, 'submit' => true, 'presets' => [true, true], 'presetsAfter' => [false, false])
    end
  end

  it 'leaves the rows alone when a poll arrives, so nothing being typed is overwritten' do
    result = run({ 'rows' => rows, 'presets' => presets }, <<~JS)
      type(dom.rows.children[0].querySelector('[data-env-value]'), 'typed');
      document.activeElement = dom.rows.children[0].querySelector('[data-env-value]');
      api.syncFromSnapshot({ editable_environment: { UE_APP: 'www' }, secret_names: [] });
      out.rows = rowState(dom.rows);
    JS

    expect(result['rows'].map { |row| row['value'] }).to eq(['typed', ''])
    expect(result['rows'].length).to eq(2)
  end
end
