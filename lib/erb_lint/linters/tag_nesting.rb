# frozen_string_literal: true

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

      def contains_nested_tag?
        children.any? { |node| node.type == :tag }
      end

      def type
        :tag
      end

      def loc
        node.loc
      end
    end

    # Ensures HTML tags are properly nested.
    class TagNesting < Linter
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
        return unless parent.contains_nested_tag?

        if parent.closing_node
          unless on_own_line?(parent.closing_node)
            add_offense(
              parent.closing_node.loc,
              "Closing tag should be on its own line"
            )
          end
        end

        parent.children.each do |child|
          unless on_own_line?(child) || preceeded_by_text?(child, parent)
            add_offense(
              child.loc,
              "Opening tag should be on its own line"
            )
          end

          add_offenses_in(child)
        end
      end

      def on_own_line?(node)
        if (line_start = node.loc.source_buffer.source.rindex(/\r?\n/, node.loc.begin_pos))
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
              tag_stack.push(tag)
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
