require_relative 'spec_helper'

RSpec.describe Workspaces::DashboardView, '.render' do
  before { repository }

  it 'renders a labelled multiline editor and disables saving while busy' do
    snapshot = { 'workspace_id' => 'fixture', 'status' => 'preparing', 'active' => true,
                 'editable_environment' => { 'APP_VARIANT' => 'www', 'APP_CHANNEL' => 'www' },
                 'environment_presets' => { 'Default' => { 'UE_APP' => 'www' } } }
    html = described_class.render(snapshot)

    expect(html).to include('<textarea id="editable-env" name="editable_env"')
    expect(html).to include('data-preset-controls hidden')
    expect(html).to include('<select id="environment-preset"')
    expect(html).to include('data-environment-presets')
    expect(html).to include('data-environment-fieldset disabled')
    expect(html).to include('data-env-submit disabled')
    expect(html).to include('APP_CHANNEL=www', 'APP_VARIANT=www')
    expect(html).to include('toggleBusy,')
    expect(html).to include('if (fieldset) fieldset.disabled = activeBusy;')
    expect(html).to include('if (submit) submit.disabled = activeBusy;')
    expect(html).to include('if (presetSelect) presetSelect.disabled = activeBusy;')
    expect(html).to include('Workspace is busy. Environment updates are temporarily disabled.')
    expect(html).to include('Preset loaded into draft only. Use Save & restart to apply changes.')
    expect(html).to include('href="/workspaces/fixture">Refresh status</a>')
    expect(html).not_to include('data-env-add-row', 'data-replace-toggle')
  end
end
