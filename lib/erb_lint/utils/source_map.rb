# frozen_string_literal: true

module ERBLint
  module Utils
    class SourceMap
      attr_reader :map

      def initialize
        @map = []
      end

      def add(origin:, dest:)
        [dest, origin].tap do |entry|
          @map << entry
        end
      end

      def translate(range)
        if (origin_range = find_origin(range))
          return origin_range
        end

        begin_pos = translate_beginning(range.begin)
        return (begin_pos...begin_pos) if begin_pos && range.size == 0

        end_pos = translate_ending(range.end)
        return (begin_pos...end_pos) if begin_pos && end_pos

        relative_range = translate_relative(range)
        return relative_range if relative_range

        spanning_range = translate_spanning(range)
        return spanning_range if spanning_range
      end

      def translate_beginning(begin_pos)
        @map.each do |(dest_range, origin_range)|
          return origin_range.begin if dest_range.begin == begin_pos
        end

        nil
      end

      def translate_ending(end_pos)
        @map.each do |(dest_range, origin_range)|
          return origin_range.end if dest_range.end == end_pos
        end

        nil
      end

      private

      def find_origin(dest)
        @map.each do |(dest_range, origin_range)|
          return origin_range if dest == dest_range
        end

        nil
      end

      def translate_relative(dest_sub_range)
        each_equal_range do |dest_range, origin_range|
          if dest_sub_range.begin >= dest_range.begin && dest_sub_range.end <= dest_range.end
            offset = origin_range.begin - dest_range.begin
            return (dest_sub_range.begin + offset)...(dest_sub_range.end + offset)
          end
        end

        nil
      end

      def translate_spanning(dest_sub_range)
        start_pos = translate_relative(dest_sub_range.first...dest_sub_range.first)
        return unless start_pos

        end_pos = translate_relative(dest_sub_range.last...dest_sub_range.last)
        return unless end_pos

        start_pos.first...end_pos.first
      end

      def each_equal_range
        @map.each do |(dest_range, origin_range)|
          next if dest_range.size != origin_range.size

          yield dest_range, origin_range
        end
      end
    end
  end
end
