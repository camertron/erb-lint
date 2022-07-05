# frozen_string_literal: true

module ERBLint
  module Utils
    class SourceMap
      def initialize
        @map = {}
      end

      def add(origin:, dest:)
        @map[dest] = origin
      end

      def translate(dest_range)
        begin_pos = translate_position(dest_range.begin)
        end_pos = translate_position(dest_range.end)

        (begin_pos...end_pos) if begin_pos && end_pos
      end

      private

      def translate_position(dest_point)
        @map.each_pair do |dest_range, origin_range|
          if dest_point >= dest_range.begin && dest_point <= dest_range.end
            offset = origin_range.begin - dest_range.begin
            return dest_point + offset
          end
        end

        nil
      end
    end
  end
end
