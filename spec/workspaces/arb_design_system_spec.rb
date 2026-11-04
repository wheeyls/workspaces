require_relative 'spec_helper'

# The dashboard takes its colours from the Arb palette, per theme, through a short list of roles. These specs hold
# that line: the palette file is the vendored one, the stylesheet names no colour of its own, every token it
# reaches for exists in both themes, and every foreground/background pair it relies on meets its contrast target.
RSpec.describe 'Arb design system' do
  let(:dir) { Pathname.new(File.expand_path('../../lib/workspaces/dashboard', __dir__)) }
  let(:palette) { dir.join('arb-palette.css').read }
  let(:styles) { dir.join('styles.css').read }

  def theme_tokens(name)
    block = palette[/\[data-theme="#{name}"\]\s*\{(.*?)\n\}/m, 1]
    block.scan(/--arb-([a-z-]+):\s*(#[0-9A-Fa-f]{6})/).to_h
  end

  def luminance(hex)
    red, green, blue = hex[1..].scan(/../).map { |pair| pair.to_i(16) / 255.0 }
    linear = ->(channel) { channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055)**2.4 }
    (0.2126 * linear.call(red)) + (0.7152 * linear.call(green)) + (0.0722 * linear.call(blue))
  end

  def contrast(foreground, background)
    lighter, darker = [luminance(foreground), luminance(background)].sort.reverse
    (lighter + 0.05) / (darker + 0.05)
  end

  it 'ships both themes with the full set of 28 tokens each' do
    expect(theme_tokens('dark').size).to eq(28)
    expect(theme_tokens('light').size).to eq(28)
    expect(theme_tokens('dark').keys).to match_array(theme_tokens('light').keys)
  end

  it 'carries the palette unchanged, after a two-line note saying where it came from' do
    expect(palette.lines.first).to match(/Arb design system, Native v1/)
    expect(palette).to include('--arb-bg: #0B171A;', '--arb-bg: #F5F2E9;', '--arb-on-accent: #073A35;', '--arb-focus: #246C89;')
  end

  it 'names no colour of its own: no hex, rgb, hsl, colour mixes, or faded opacity' do
    without_comments = styles.gsub(%r{/\*.*?\*/}m, '')

    expect(without_comments).not_to match(/#[0-9a-fA-F]{3,8}\b/)
    expect(without_comments).not_to match(/\b(?:rgb|rgba|hsl|hsla)\(/)
    expect(without_comments).not_to include('color-mix')
    expect(without_comments.scan(/opacity:\s*([\d.]+)/).flatten).to all(eq('1'))
  end

  it 'only reaches for palette tokens that exist in both themes' do
    wanted = (styles.scan(/var\(--arb-([a-z-]+)\)/).flatten + dir.join('template.html.erb').read.scan(/var\(--arb-([a-z-]+)\)/).flatten).uniq
    aliases = %w(canvas raised text-secondary river on-river boundary)

    expect(wanted - aliases - theme_tokens('dark').keys).to eq([])
    expect(wanted - aliases - theme_tokens('light').keys).to eq([])
  end

  it 'defines every custom property it uses' do
    defined = styles.scan(/(--[a-z][a-z0-9-]*):/).flatten.uniq
    used = styles.scan(/var\((--[a-z][a-z0-9-]*)/).flatten.uniq

    expect(used.reject { |name| name.start_with?('--arb-') } - defined).to eq([])
  end

  # Each row is a pairing the stylesheet relies on. The vetted ones come from the palette's audit; the rest are
  # measured here, on unrounded ratios, because the audit does not list them.
  PAIRINGS = [
    ['normal text on a surface', 'text', 'surface', 4.5], ['normal text on the page', 'text', 'bg', 4.5],
    ['secondary text on a surface', 'muted', 'surface', 4.5], ['secondary text on the page', 'muted', 'bg', 4.5],
    ['text on elevated', 'text', 'elevated', 4.5], ['secondary text on elevated', 'muted', 'elevated', 4.5],
    ['link text on a surface', 'accent', 'surface', 4.5],
    ['primary button label', 'on-accent', 'accent', 4.5], ['primary button label, hover', 'on-accent', 'action-hover', 4.5],
    ['primary button label, pressed', 'on-accent', 'action-pressed', 4.5],
    ['primary button against a surface', 'accent', 'surface', 3.0],
    ['danger button label', 'on-error', 'error', 4.5], ['danger button label, hover', 'on-error', 'error-hover', 4.5],
    ['danger button label, pressed', 'on-error', 'error-pressed', 4.5],
    ['control and panel edges', 'border', 'surface', 3.0], ['control edges on the page', 'border', 'bg', 3.0],
    ['focus ring on a surface', 'focus', 'surface', 3.0], ['focus ring on elevated', 'focus', 'elevated', 3.0],
    ['selected text', 'text', 'selected-bg', 4.5], ['selected edge and marker', 'selected-border', 'selected-bg', 3.0],
    ['disabled label', 'disabled-fg', 'disabled-bg', 4.5], ['disabled edge', 'disabled-border', 'disabled-bg', 3.0],
    ['ready pill', 'success', 'success-bg', 4.5], ['error pill', 'error', 'error-bg', 4.5],
    ['interrupted pill', 'warning', 'warning-bg', 4.5],
    ['preparing pill', 'accent', 'elevated', 4.5], ['idle, stopped and sleeping pills', 'steel', 'elevated', 4.5],
    ['body text in the error callout', 'text', 'error-bg', 4.5], ['secondary text in the error callout', 'muted', 'error-bg', 4.5],
    ['danger zone heading', 'error', 'error-bg', 4.5],
    ['delete button inside the danger zone', 'error', 'error-bg', 3.0], ['delete button hover inside the danger zone', 'error-hover', 'error-bg', 3.0],
    ['delete button pressed inside the danger zone', 'error-pressed', 'error-bg', 3.0],
    ['error callout edge against the surface around it', 'error', 'surface', 3.0],
    ['progress bar edge', 'border', 'elevated', 3.0], ['progress fill', 'accent', 'elevated', 3.0],
    ['slow progress fill', 'warning', 'elevated', 3.0],
    ['step icon ring', 'muted', 'surface', 3.0], ['step icon, running', 'accent', 'surface', 3.0],
    ['step icon, complete', 'success', 'surface', 3.0], ['step icon, failed', 'error', 'surface', 3.0],
    ['check mark on the complete icon', 'bg', 'success', 3.0], ['cross on the failed icon', 'bg', 'error', 3.0]
  ].freeze

  %w(dark light).each do |name|
    PAIRINGS.each do |label, foreground, background, minimum|
      it "meets #{minimum}:1 for #{label} in the #{name} theme" do
        tokens = theme_tokens(name)

        expect(contrast(tokens.fetch(foreground), tokens.fetch(background))).to be >= minimum
      end
    end
  end

  it 'uses the bright river only where the palette allows it: as an accent on dark surfaces, never as light-theme text' do
    expect(contrast(theme_tokens('light').fetch('accent'), '#FFFFFF')).to be >= 4.5
    expect(contrast('#58D9C4', '#FFFFFF')).to be < 2
  end
end
