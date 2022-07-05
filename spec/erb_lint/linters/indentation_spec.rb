# frozen_string_literal: true

require "spec_helper"

describe ERBLint::Linters::Indentation do
  let(:linter_config) do
    described_class.config_schema.new # (enforced_style: enforced_style)
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

    context "when enforced_style is spaces" do
      let(:enforced_style) { "spaces" }

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

      context "when content contains multi-line ruby code" do
        let(:file) { <<~ERB }
          <div foo="<%= bar %>">foo</div>
        ERB

        it { expect(subject).to(eq([])) }
      end

      context "when content is improperly indented" do
        # let(:file) { <<~ERB }
        #   <div>
        #      <span class="foo">bar</span>
        #      <%= hello_world %>
        #   </div>
        # ERB

        # let(:file) { <<~ERB }
        #   <div>
        #    <span class="foo">bar</span>
        #      <% 10.times do |i| %>
        #          <%= i %>
        #       <% end %>
        #    </div>
        # ERB

        let(:file) { <<~ERB }
<div>
 <span class="foo">bar</span>
 <% 10.times do |i| %>
   <%= i %>
 <% end %>
 </div>
        ERB

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

        it do
          offenses = subject
          puts corrected_content
          # expect(subject).to(eq([
          #   build_offense(6...9, "Expected line to be indented 1 level."),
          #   build_offense(38...41, "Expected line to be indented 1 level."),
          # ]))
        end
      end

      context "when content is improperly indented with mixed indentation characters" do
        let(:file) { <<~ERB }
          <div>
          \t <span class="foo">bar</span>
          \t <%= hello_world %>
          </div>
        ERB

        it do
          expect(subject).to(eq([
            build_offense(6...8, "Expected line to be indented 1 level."),
            build_offense(37...39, "Expected line to be indented 1 level."),
          ]))
        end
      end
    end

    context "when enforced_style is tabs" do
      let(:enforced_style) { "tabs" }

      context "when tag does not span multiple lines" do
        let(:file) { "<div><%= hello_world %></div>" }

        it { expect(subject).to(eq([])) }
      end

      context "when tag is self-closing" do
        let(:file) { <<~ERB }
          <div>
          \t<input type="text" />
          \t<span>First name</span>
          </div>
        ERB

        it { expect(subject).to(eq([])) }
      end

      context "when content is properly indented" do
        let(:file) { <<~ERB }
          <div>
          \t<span class="foo">bar</span>
          \t<%= hello_world %>
          </div>
        ERB

        it { expect(subject).to(eq([])) }
      end

      context "when content is improperly indented" do
        let(:file) { <<~ERB }
          <div>
          \t\t<span class="foo">bar</span>
          \t\t<%= hello_world %>
          </div>
        ERB

        it do
          expect(subject).to(eq([
            build_offense(6...8, "Expected line to be indented 1 level."),
            build_offense(37...39, "Expected line to be indented 1 level."),
          ]))
        end
      end

      context "when content is improperly indented with mixed indentation characters" do
        let(:file) { <<~ERB }
          <div>
          \t <span class="foo">bar</span>
          \t <%= hello_world %>
          </div>
        ERB

        it do
          expect(subject).to(eq([
            build_offense(6...8, "Expected line to be indented 1 level."),
            build_offense(37...39, "Expected line to be indented 1 level."),
          ]))
        end
      end
    end
  end

  describe "autocorrect" do
    subject { corrected_content }

    context "when enforced_style is spaces" do
      let(:enforced_style) { "spaces" }

      context "when tag does not span multiple lines" do
        let(:file) { "<div><%= hello_world %></div>" }

        it { expect(subject).to(eq(file)) }
      end

      context "when tag is self-closing" do
        let(:file) { <<~ERB }
          <div>
            <input type="text" />
            <span>First name</span>
          </div>
        ERB

        it { expect(subject).to(eq(file)) }
      end

      context "when content is properly indented" do
        let(:file) { <<~ERB }
          <div>
            <span class="foo">bar</span>
            <%= hello_world %>
          </div>
        ERB

        it { expect(subject).to(eq(file)) }
      end

      context "when content is improperly indented" do
        let(:file) { <<~ERB }
          <div>
             <span class="foo">bar</span>
             <%= hello_world %>
          </div>
        ERB

        it do
          expect(subject).to(eq(<<~ERB))
            <div>
              <span class="foo">bar</span>
              <%= hello_world %>
            </div>
          ERB
        end
      end

      context "when content is improperly indented with mixed indentation characters" do
        let(:file) { <<~ERB }
          <div>
          \t <span class="foo">bar</span>
          \t <%= hello_world %>
          </div>
        ERB

        it do
          expect(subject).to(eq(<<~ERB))
            <div>
              <span class="foo">bar</span>
              <%= hello_world %>
            </div>
          ERB
        end
      end
    end

    context "when enforced_style is tabs" do
      let(:enforced_style) { "tabs" }

      context "when tag does not span multiple lines" do
        let(:file) { "<div><%= hello_world %></div>" }

        it { expect(subject).to(eq(file)) }
      end

      context "when tag is self-closing" do
        let(:file) { <<~ERB }
          <div>
          \t<input type="text" />
          \t<span>First name</span>
          </div>
        ERB

        it { expect(subject).to(eq(file)) }
      end

      context "when content is properly indented" do
        let(:file) { <<~ERB }
          <div>
          \t<span class="foo">bar</span>
          \t<%= hello_world %>
          </div>
        ERB

        it { expect(subject).to(eq(file)) }
      end

      context "when content is improperly indented" do
        let(:file) { <<~ERB }
          <div>
          \t\t<span class="foo">bar</span>
          \t\t<%= hello_world %>
          </div>
        ERB

        it do
          expect(subject).to(eq(<<~ERB))
            <div>
            \t<span class="foo">bar</span>
            \t<%= hello_world %>
            </div>
          ERB
        end
      end

      context "when content is improperly indented with mixed indentation characters" do
        let(:file) { <<~ERB }
          <div>
          \t <span class="foo">bar</span>
          \t <%= hello_world %>
          </div>
        ERB

        it do
          expect(subject).to(eq(<<~ERB))
            <div>
            \t<span class="foo">bar</span>
            \t<%= hello_world %>
            </div>
          ERB
        end
      end
    end
  end

  private

  def build_offense(range, message)
    ERBLint::Offense.new(
      linter,
      processed_source.to_source_range(range),
      message
    )
  end
end
