# frozen_string_literal: true

require "erb_lint/linters/self_closing_tag"

module ERBLint
  module Linters
    class Document
      attr_reader :children

      def initialize(children = [])
        @children = children
      end
    end

    class Tag
      attr_reader :node, :children
      attr_accessor :closing_node

      def initialize(node, children = [])
        @node = node
        @closing_node = closing_node
        @children = children
      end

      def type
        :tag
      end

      def name
        node.name
      end

      def loc
        node.loc
      end
    end

    # Ensures HTML tags are properly nested.
    class TagNesting < Linter
      SELF_CLOSING_TAGS = ERBLint::Linters::SelfClosingTag::SELF_CLOSING_TAGS

      include LinterRegistry

      def run(processed_source)
        doc = build_document(processed_source)
        doc.children.each { |child| add_offenses_in(child) }
      end

      def autocorrect(_processed_source, offense)
        lambda do |corrector|
          corrector.insert_before(offense.source_range, "\n")
        end
      end

      private

      def add_offenses_in(parent)
        return if parent.type == :text
        return if parent.name == "pre"

        if should_be_on_own_line?(parent)
          if !on_own_line?(parent)
            add_offense(
              parent.node.loc,
              "Opening tag should be on its own line"
            )
          end

          if (first_child = parent.children.first)
            # Check will_add_newline? and bail if true since the recursive call below
            # will add a newline to this child later.
            if !on_own_line?(first_child) && !will_add_newline?(first_child)
              add_offense(
                first_child.loc,
                "#{first_child.type.to_s.capitalize} should start on its own line"
              )
            end
          end

          if parent.closing_node && !on_own_line?(parent.closing_node)
            add_offense(
              parent.closing_node.loc,
              "Closing tag should be on its own line"
            )
          end
        end

        parent.children.each_with_index do |child, idx|
          add_offenses_in(child)
        end
      end

      def should_be_on_own_line?(node)
        contains_nested_tag?(node) || contains_multiline_text?(node)
      end

      alias will_add_newline? should_be_on_own_line?

      def contains_nested_tag?(node)
        return false if node.type == :text

        node.children.any? { |node| node.type == :tag }
      end

      def contains_multiline_text?(node)
        return false if node.type == :text

        node.children.any? { |child| is_multiline_text?(child) }
      end

      def is_multiline_text?(node)
        return false if node.type != :text
        return false if node.loc.source =~ /\A\s*\z/

        node.loc.first_line < node.loc.last_line
      end

      def on_own_line?(node)
        return true if node.loc.begin_pos == 0

        if (line_start = node.loc.source_buffer.source.rindex(/\A|\r?\n/, node.loc.begin_pos))
          node.loc.with(begin_pos: line_start, end_pos: node.loc.begin_pos).source =~ /\A\s*\z/
        end
      end

      def preceeded_by_text?(tag, parent)
        text_node = find_preceeding_text_node(tag, parent)

        return false unless text_node
        return false if text_node.loc.source =~ /\A\s*\z/

        text_node.loc.last_line == tag.loc.first_line
      end

      def find_preceeding_text_node(tag, parent)
        idx = parent.children.index(tag)

        (idx - 1).downto(0) do |i|
          if parent.children[i].type == :text
            return parent.children[i]
          end
        end

        nil
      end

      def build_document(processed_source)
        doc = Document.new
        tag_stack = [doc]

        processed_source.ast.descendants(:tag, :text).each do |node|
          if node.type == :tag
            tag_node = BetterHtml::Tree::Tag.from_node(node)

            if tag_node.closing?
              break if tag_stack.empty?

              tag_stack.pop.closing_node = tag_node
            elsif tag_node.self_closing?
              tag_stack.last.children << Tag.new(tag_node)
            else
              tag = Tag.new(tag_node)
              tag_stack.last.children << tag

              unless SELF_CLOSING_TAGS.include?(tag_node.name)
                tag_stack.push(tag)
              end
            end
          else
            tag_stack.last.children << node
          end
        end

        doc
      end
    end
  end
end
