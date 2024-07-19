# frozen_string_literal: true

require "spec_helper"

describe ERBLint::Linters::Indentation::Linter do
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

    context "when improper indentation exists in a <pre> tag" do
      let(:file) { <<~ERB }
        <pre>
        <%= foo %>
        </pre>
      ERB

      it { expect(subject).to eq([]) }
    end

    context "when a child HTML element is improperly indented" do
      let(:file) { <<~ERB }
        <div>
           <span class="foo">bar</span>
        </div>
      ERB

      it do
        expect(subject).to(eq([
          build_offense(6...9, "Layout/IndentationWidth: Use 2 (not 3) spaces for indentation.", severity: :convention)
        ]))
      end
    end

    context "when an HTML element spans multiple lines" do
      let(:file) { <<~ERB }
        <span>
          <a class="class1 class2"
            href="foo"
            target="_blank">
            Link text
          </a>
        </span>
      ERB

      it do
        expect(subject).to(eq([
          build_offense(38...38, "Layout/ArgumentAlignment: Align the arguments of a method call if they span more than one line.", severity: :convention),
          build_offense(53...67, "Layout/ArgumentAlignment: Align the arguments of a method call if they span more than one line.", severity: :convention),
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

    context "when a multi-line ERB statement isn't indented properly" do
      let(:file) { <<~ERB }
        <%
        foo = "foo"
        bar = "bar"
        %>
      ERB

      it do
        expect(subject).to(eq([
          build_offense(3...3, "Layout/IndentationWidth: Use 2 (not 0) spaces for indentation.", severity: :convention),
        ]))
      end
    end

    context "when a multi-line ERB statement is indented properly" do
      let(:file) { <<~ERB }
        <%
          foo = "foo"
          bar = "bar"
        %>
      ERB

      it { expect(subject).to eq([]) }
    end

    context "when a multi-line ERB statement that starts on the first line isn't indented properly" do
      let(:file) { <<~ERB }
        <% foo = "foo"
        bar = "bar"
        %>
      ERB

      it { expect(subject).to eq([]) }
    end

    context "when a branching ERB tag is indented by text" do
      let(:file) { <<~ERB }
        text <% if foo %>
          foo
        <% else %>
          bar
        <% end %>
      ERB

      it do
        expect(subject).to(eq([
          build_offense(20...23, "Layout/IndentationWidth: Use 2 (not -3) spaces for indentation.", severity: :convention),
          build_offense(41...50, "Layout/EndAlignment: `end` at 5, 0 is not aligned with `if` at 1, 5.", severity: :warning),
          build_offense(24...34, "Layout/ElseAlignment: Align `else` with `if`.", severity: :convention),
        ]))
      end
    end

    context "when a branching ERB tag is indented by an ERB tag on the same line" do
      let(:file) { <<~ERB }
        <%= text %> <% if foo %>
          foo
        <% else %>
          bar
        <% end %>
      ERB

      it "indents to the level of the first line" do
        expect(subject).to(eq([
          build_offense(27...42, "Layout/IndentationWidth: Use 2 (not -10) spaces for indentation.", severity: :convention),
          build_offense(48...57, "Layout/EndAlignment: `end` at 5, 0 is not aligned with `if` at 1, 12.", severity: :warning),
          build_offense(31...41, "Layout/ElseAlignment: Align `else` with `if`.", severity: :convention),
        ]))
      end
    end

    context "when a multi-line ERB statement ends with a trailing block" do
      let(:file) { <<~ERB }
        <%
        foo = "foo"
        bar do
        %>
          bar
        <% end %>
      ERB

      it "does not indent" do
        expect(subject).to eq([])
      end
    end

    context "when a multi-line ERB statement that starts on the same line ends with a trailing block" do
      let(:file) { <<~ERB }
        <% foo = "foo"
        bar do
        %>
          bar
        <% end %>
      ERB

      it "does not indent" do
        expect(subject).to eq([])
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

    context "when a branching ERB tag is indented by an ERB tag on the same line" do
      let(:file) { <<~ERB }
        <%= text %> <% if foo %>
          foo
        <% end %>
      ERB

      it "indents to the level of the first line" do
        expect(subject).to(eq(<<~ERB))
          <%= text %> <% if foo %>
                        foo
                      <% end %>
        ERB
      end
    end

    context "when an HTML element spans multiple lines" do
      let(:file) { <<~ERB }
        <span>
          <a class="class1 class2"
            href="foo"
            target="_blank">
            Link text
          </a>
        </span>
      ERB

      it do
        expect(subject).to(eq(<<~ERB))
          <span>
            <a class="class1 class2"
               href="foo"
               target="_blank">
              Link text
            </a>
          </span>
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
