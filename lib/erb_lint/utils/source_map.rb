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

      def translate(range)
        begin_pos = translate_beginning(range.begin)
        return (begin_pos...begin_pos) if begin_pos && range.size == 0

        end_pos = translate_ending(range.end)
        return (begin_pos...end_pos) if begin_pos && end_pos

        begin_pos = translate_relative(range.begin)
        end_pos = translate_relative(range.end)

        return (begin_pos...end_pos) if begin_pos && end_pos
      end

      def translate_beginning(begin_pos)
        @map.each_pair do |dest_range, origin_range|
          return origin_range.begin if dest_range.begin == begin_pos
        end

        nil
      end

      def translate_ending(end_pos)
        @map.each_pair do |dest_range, origin_range|
          return origin_range.end if dest_range.end == end_pos
        end

        nil
      end

      private

      def translate_relative(dest_point)
        @map.each_pair do |dest_range, origin_range|
          next if dest_range.size != origin_range.size

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