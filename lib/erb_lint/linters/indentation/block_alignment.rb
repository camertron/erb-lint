# frozen_string_literal: true

module ERBLint
  module Linters
    class Indentation < Linter
      class BlockAlignment < RuboCop::Cop::Layout::BlockAlignment
        attr_reader :ir

        def self.badge
          @badge ||= ::RuboCop::Cop::Badge.for(superclass.name)
        end

        def bind_to(ir)
          @ir = ir
        end

        private

        def format_message(start_loc, end_loc, do_source_line_column, error_source_line_column)
          start_loc = ir.translate(start_loc)
          end_loc = ir.translate(end_loc)

          # the indentation linter doesn't support the :start_of_block style, so the
          # error always occurs at start_loc, i.e. does not happen at the "do" or "{"
          error_source_line_column = {
            source: start_loc.source_line.strip,
            line: start_loc.line,
            column: start_loc.column,
          }

          super(start_loc, end_loc, error_source_line_column, error_source_line_column)
        end
      end
    end
  end
end
