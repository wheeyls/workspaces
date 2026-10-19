require_relative 'spec_helper'
require 'json'

RSpec.describe Workspaces::DurationFormat do
  {
    0 => '0s', 0.0004 => '0s', 0.05 => '0.1s', 0.124 => '0.1s', 0.5 => '0.5s', 1 => '1s', 12.0 => '12s',
    12.34 => '12.3s', 59.94 => '59.9s',
    59.96 => '1m 0s', 60 => '1m 0s', 69.6 => '1m 10s', 70 => '1m 10s', 137 => '2m 17s', 240 => '4m 0s',
    3599.4 => '59m 59s', 3599.6 => '1h 0m 0s', 3600 => '1h 0m 0s', 3723 => '1h 2m 3s'
  }.each do |seconds, expected|
    it "formats #{seconds} as #{expected.inspect}" do
      expect(described_class.call(seconds)).to eq(expected)
    end
  end

  it 'never produces a bare seconds count of a minute or more' do
    expect((60..400).map { |s| described_class.call(s) }).to all(match(/\A\d+m \d+s\z/))
  end

  it 'returns nil for anything that is not a usable duration' do
    expect([nil, 'x', -1, Float::INFINITY, Float::NAN, [], {}].map { |v| described_class.call(v) }).to all(be_nil)
  end

  it 'agrees with the dashboard script for the same inputs, so the page and the setup log never differ' do
    app_js = File.read(File.join(__dir__, '../../lib/workspaces/dashboard/app.js'))
    fn = app_js[/function formatDuration\(seconds\) \{.*?\n  \}\n/m]
    inputs = [0, 0.0004, 0.05, 0.124, 0.5, 0.95, 1, 12, 12.34, 59.94, 59.96, 60, 69.6, 70, 137, 240, 599.5, 3599.4,
              3599.6, 3600, 3723, 86_400.4, -1, nil]
    script = "#{fn}\nprocess.stdout.write(JSON.stringify(#{JSON.generate(inputs)}.map(formatDuration)));"

    output, status = Open3.capture2('node', '-e', script)
    expect(status.success?).to eq(true)
    expect(JSON.parse(output)).to eq(inputs.map { |v| described_class.call(v) })
  end
end
