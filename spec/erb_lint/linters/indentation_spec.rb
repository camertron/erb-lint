# frozen_string_literal: true

require "spec_helper"

describe ERBLint::Linters::Indentation do
  let(:linter_config) do
    described_class.config_schema.new
  end

  let(:file_loader) { ERBLint::FileLoader.new(".") }
  let(:linter) { described_class.new(file_loader, linter_config) }
  let(:processed_source) { ERBLint::ProcessedSource.new("file.rb", file) }
  let(:offenses) { linter.offenses }
  let(:corrector) { ERBLint::Corrector.new(processed_source, offenses) }
  let(:corrected_content) { corrector.corrected_content }

  before { linter.run(processed_source) }

  describe "offenses" do
    subject { offenses }

    context "when tag does not span multiple lines" do
      let(:file) { "<div><%= hello_world %></div>" }

      it { expect(subject).to(eq([])) }
    end

    context "when tag is self-closing" do
      let(:file) { <<~ERB }
        <div>
          <input type="text" />
          <span>First name</span>
        </div>
      ERB

      it { expect(subject).to(eq([])) }
    end

    context "when content is properly indented" do
      let(:file) { <<~ERB }
        <div>
          <span class="foo">bar</span>
          <%= hello_world %>
        </div>
      ERB

      it { expect(subject).to(eq([])) }
    end

    context "when a child HTML element is improperly indented" do
      let(:file) { <<~ERB }
        <div>
           <span class="foo">bar</span>
        </div>
      ERB

#         let(:file) { <<~ERB }
# <div>
#  <span class="foo">bar</span>
#  <% 10.times do |i| %>
#    <%= i %>
#  <% end %>
#  </div>
#         ERB

      # let(:file) { <<~ERB }
      #   <% 5.times do |i| %>
      #   <span>foo</span>
      #   <% end %>
      # ERB

      # let(:file) { <<~ERB }
      #   <div>
      #     <span class="foo">bar</span>
      #   <% 10.times do |i| %>
      #       <%= i %>
      #     <% end %>
      #   </div>
      # ERB

      # let(:file) { <<~ERB }
      # <div class="m-1">
      # <!-- List of plans available to the target -->
      #   <% if !GitHub.enterprise? && error_message.include?(User::NOT_UNIQUE_LOGIN_MESSAGE) %>
      #     Please choose another. To submit a trademark claim, please see our <a href="<%= GitHub.help_url %>/articles/github-trademark-policy/" target="_blank">Trademark Policy</a>.
      #   <% end %>
      # </div>
      # ERB

      it do
        expect(subject).to(eq([
          build_offense(6...9, "Layout/IndentationWidth: Use 2 (not 3) spaces for indentation.", severity: :convention)
        ]))
      end
    end

    context "when a child ERB node is improperly indented" do
      let(:file) { <<~ERB }
        <div>
          <% 10.times do |i| %>
             <%= i %>
          <% end %>
        </div>
      ERB

      it do
        expect(subject).to(eq([
          build_offense(32...35, "Layout/IndentationWidth: Use 2 (not 3) spaces for indentation.", severity: :convention),
        ]))
      end
    end

    context "when the end of an ERB block isn't aligned properly" do
      let(:file) { <<~ERB }
        <div>
          <% 10.times do |i| %>
            <%= i %>
            <% end %>
        </div>
      ERB

      it do
        expect(subject).to(eq([
          build_offense(34...34, "Layout/IndentationWidth: Use 2 (not 0) spaces for indentation.", severity: :convention),
          build_offense(47...56, "Layout/BlockAlignment: `<% end %>` at 4, 4 is not aligned with `<% 10.times do |i| %>` at 2, 2.", severity: :convention),
        ]))
      end
    end
  end

  describe "autocorrect" do
    subject { corrected_content }

    context "when a child HTML element is improperly indented" do
      let(:file) { <<~ERB }
        <div>
           <span class="foo">bar</span>
        </div>
      ERB

      it do
        expect(subject).to(eq(<<~ERB))
          <div>
            <span class="foo">bar</span>
          </div>
        ERB
      end
    end

    context "when a child ERB node is improperly indented" do
      let(:file) { <<~ERB }
        <div>
          <% 10.times do |i| %>
             <%= i %>
          <% end %>
        </div>
      ERB

      it do
        expect(subject).to(eq(<<~ERB))
          <div>
            <% 10.times do |i| %>
              <%= i %>
            <% end %>
          </div>
        ERB
      end
    end

    context "when the end of an ERB block isn't aligned properly" do
      let(:file) { <<~ERB }
        <div>
          <% 10.times do |i| %>
            <% end %>
        </div>
      ERB

      it do
        expect(subject).to(eq(<<~ERB))
          <div>
            <% 10.times do |i| %>
            <% end %>
          </div>
        ERB
      end
    end
  end

  private

  def build_offense(range, message, context: nil, severity: nil)
    ERBLint::Offense.new(
      linter,
      processed_source.to_source_range(range),
      message,
      context,
      severity
    )
  end
end
