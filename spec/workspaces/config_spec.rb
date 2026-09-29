require_relative 'spec_helper'

RSpec.describe Workspaces::Config do
  it 'uses stable workspace URLs independent of PR metadata' do
    expect(described_class.preview_url('checkout-a12bc34d')).to eq('http://ws-checkout-a12bc34d.localhost:4747/')
    expect(described_class.preview_workspace_id('ws-checkout-a12bc34d.localhost')).to eq('checkout-a12bc34d')
    expect(described_class.preview_workspace_id('ws-checkout-a12bc34d.localhost.evil.test')).to be_nil
    expect(described_class.dashboard_url('checkout-a12bc34d')).to eq('http://localhost:4747/workspaces/checkout-a12bc34d')
  end

  it 'supports DNS-safe custom prefixes' do
    ClimateControl.modify('WORKSPACES_SUBDOMAIN_PREFIX' => 'sandbox-') do
      expect(described_class.preview_url('agent-123')).to eq('http://sandbox-agent-123.localhost:4747/')
    end
    ClimateControl.modify('WORKSPACES_SUBDOMAIN_PREFIX' => 'bad_prefix') do
      expect { described_class.preview_url('agent-123') }.to raise_error(ArgumentError)
    end
  end

  it 'validates public origins and domains rather than accepting URL injection' do
    %w(https://user:pass@host.test https://host.test/path https://host.test/?token=x).each do |origin|
      ClimateControl.modify('WORKSPACES_PUBLIC_ORIGIN' => origin) do
        expect do
          described_class.public_origin
        end.to raise_error(ArgumentError)
      end
    end
    ClimateControl.modify('WORKSPACES_BASE_DOMAIN' => 'host.test/path') do
      expect { described_class.preview_base_domain }.to raise_error(ArgumentError)
    end
  end
end
