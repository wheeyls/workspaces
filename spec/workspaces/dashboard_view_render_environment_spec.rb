require_relative 'spec_helper'

RSpec.describe Workspaces::DashboardView, '.render' do
  before { repository }

  it 'renders a labelled multiline editor and disables saving while busy' do
    snapshot = { 'workspace_id' => 'fixture', 'status' => 'preparing', 'active' => true,
                 'editable_environment' => { 'APP_VARIANT' => 'www', 'APP_CHANNEL' => 'www' } }
    html = described_class.render(snapshot)

    expect(html).to include('<textarea id="editable-env" name="editable_env"')
    expect(html).to include('APP_CHANNEL=www', 'APP_VARIANT=www')
    expect(html).to include("'fieldset, [data-env-submit]'")
    expect(html).to include('Workspace is busy. Environment updates are temporarily disabled.')
    expect(html).not_to include('data-env-add-row', 'data-replace-toggle')
  end
end
