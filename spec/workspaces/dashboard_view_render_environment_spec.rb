require_relative 'spec_helper'

RSpec.describe Workspaces::DashboardView, '.render' do
  before { repository }

  let(:workspace) { Workspaces::Registry.new.create(branch: 'main') }

  def render_dashboard_html(snapshot_overrides = {})
    base = workspace.describe.merge('workspace_id' => workspace.id,
                                    'status' => 'ready',
                                    'active' => false,
                                    'message' => 'Workspace ready',
                                    'environment_keys' => ['APP_VARIANT'])
    described_class.render(base.merge(snapshot_overrides))
  end

  it 'keeps replace inputs disabled until explicitly enabled and adds safe variable rows' do
    html = render_dashboard_html

    expect(html).to include('data-replace-toggle')
    expect(html).to include('data-replace-value disabled')
    expect(html).to include('data-env-add-row')
    expect(html).to include('namePattern = /^[A-Za-z_][A-Za-z0-9_]*$/')
    expect(html).to include("hidden.name = 'set[' + key + ']';")
  end

  it 'clears and omits unchanged replace values and incomplete add rows before submit' do
    html = render_dashboard_html

    expect(html).to include('function prepareSubmit()')
    expect(html).to include("if (!toggle.checked) row.querySelector('[data-replace-value]').value = ''")
    expect(html).to include('if (key && namePattern.test(key))')
  end

  it 'disables environment submit controls while busy without removing field values in DOM' do
    html = render_dashboard_html('active' => true, 'status' => 'preparing')

    expect(html).to include('function toggleBusyState(nextBusy)')
    expect(html).to include("'fieldset, [data-env-submit], [data-env-add-row]'")
    expect(html).to include('Workspace is busy. Environment updates are temporarily disabled.')
  end
end
