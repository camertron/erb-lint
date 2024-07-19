# frozen_string_literal: true

module ERBLint
  module Linters
    module Indentation
      class IR
        attr_reader :original_source, :ir_source, :source_map

        def initialize(original_source, ir_source, source_map)
          @original_source = original_source
          @ir_source = ir_source
          @source_map = source_map
        end

        def translate(ir_range)
          if (original_range = source_map.translate(ir_range.to_range))
            original_source.to_source_range(original_range)
          end
        end

        # debugging tool
        def highlight(original_range)
          original_source.file_content.dup.tap do |result|
            result.insert(original_range.end_pos, "]")
            result.insert(original_range.begin_pos, "[")
          end
        end

        def translate_beginning(begin_pos)
          source_map.translate_beginning(begin_pos)
        end
      end
    end
  end
end
