# frozen_string_literal: true

module ERBLint
  module Utils
    class SourceMapCorrector
      def initialize(ir, corrector)
        @ir = ir
        @corrector = corrector
      end

      def remove(range)
        @corrector.remove(translate_range(range))
      end

      def insert_before(range, content)
        @corrector.insert_before(translate_range(range), content)
      end

      def insert_after(range, content)
        @corrector.insert_after(translate_range(range), content)
      end

      def replace(range, content)
        @corrector.replace(translate_range(range), content)
      end

      def remove_preceding(range, size)
        @corrector.remove_preceding(translate_range(range), size)
      end

      def remove_leading(range, size)
        @corrector.remove_leading(translate_range(range), size)
      end

      def remove_trailing(range, size)
        @corrector.remove_trailing(translate_range(range), size)
      end

      def translate_range(node_or_source_range)
        ir.translate(to_source_range(node_or_source_range))
      end

      private

      def to_source_range(node_or_source_range)
        case node_or_source_range
        when ::RuboCop::AST::Node, ::Parser::Source::Comment
          node_or_source_range.loc.expression
        when ::Parser::Source::Range
          node_or_source_range.to_range
        else
          raise TypeError,
            "Expected a Parser::Source::Range, Comment or " \
              "Rubocop::AST::Node, got #{node_or_source_range.class}"
        end
      end
    end
  end
end
