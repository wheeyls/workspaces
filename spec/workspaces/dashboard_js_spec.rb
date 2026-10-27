require_relative 'spec_helper'
require 'json'

RSpec.describe 'dashboard scripts' do
  let(:app_js) { File.read(File.join(__dir__, '../../lib/workspaces/dashboard/app.js')) }
  let(:environment_js) { File.read(File.join(__dir__, '../../lib/workspaces/dashboard/environment.js')) }

  it 'keeps preset UI hidden when no presets are provided and the no-JS rows remain available in HTML' do
    snapshot = {
      'workspace_id' => 'fixture',
      'status' => 'idle',
      'active' => false,
      'editable_environment' => { 'UE_APP' => 'www' },
      'environment_presets' => {}
    }
    html = Workspaces::DashboardView.render(snapshot)

    expect(html).to include('id="env-rows"', 'name="env[0][name]" value="UE_APP"')
    expect(html).not_to include('id="environment-preset"')
    expect(html).to include('data-environment-presets="{}"')
  end
end
