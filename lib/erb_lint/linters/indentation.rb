# frozen_string_literal: true

module ERBLint
  module Linters
    # Warns when tags are not indented properly.
    class Indentation < Linter
      include LinterRegistry

      class ConfigSchema < LinterConfig
        property :enforced_style, converts: :to_sym, accepts: [:spaces, :tabs], default: :spaces
        property :indent_width, converts: :to_i, accepts: Integer, default: -> { enforced_style == :spaces ? 2 : 1 }
      end
      self.config_schema = ConfigSchema

      def run(processed_source)
        level = 0
        source = processed_source.file_content
        indent_char = @config.enforced_style == :spaces ? " " : "\t"

        processed_source.ast.descendants(:tag, :erb).each do |node|
          if node.type == :tag
            tag = BetterHtml::Tree::Tag.from_node(node)
            next if tag.self_closing?

            if tag.closing?
              level -= 1
              next
            end
          end

          line_start = if (index = source.rindex("\n", node.loc.begin_pos))
            index + 1
          else
            0
          end

          indent_loc = node.loc.with(begin_pos: line_start, end_pos: node.loc.begin_pos)
          actual_indent = indent_loc.source
          next unless actual_indent =~ /\A\s*\z/

          expected_indent = indent_char * (level * @config.indent_width)

          if actual_indent != expected_indent
            add_offense(
              indent_loc,
              "Expected line to be indented #{level} #{level == 1 ? "level" : "levels"}.",
              expected_indent
            )
          end

          level += 1 if node.type == :tag
        end
      end

      def autocorrect(_processed_source, offense)
        lambda do |corrector|
          corrector.replace(offense.source_range, offense.context)
        end
      end
    end
  end
end
