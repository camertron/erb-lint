# frozen_string_literal: true

require "singleton"

module ERBLint
  class IdentitySourceMap
    include Singleton

    def add(**); end

    def translate(dest_sub_range)
      dest_sub_range
    end
  end

  class SourceMap
    def self.identity_map
      IdentitySourceMap.instance
    end

    def initialize
      @map = {}
    end

    def add(origin:, dest:)
      @map[dest] = origin
    end

    # def translate_source_range(dest_sub_source_range)
    #   translate(dest_sub_source_range.range)
    # end

    # def translate(dest_sub_range)
    #   dest_range, origin_range = find_origin(dest_sub_range)
    #   return unless origin_range

    #   offset = origin_range.begin - dest_range.begin
    #   (dest_sub_range.begin + offset)...(dest_sub_range.end + offset)
    # end

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

    # def find_origin(range)
    #   @map.each_pair do |dest_range, origin_range|
    #     return dest_range, origin_range if range.begin >= dest_range.begin && range.end <= dest_range.end
    #   end

    #   nil
    # end

    # def translate_point(dest_point)
    #   @map.each_pair do |dest_range, origin_range|
    #     if dest_range.cover?(dest_point)
    #       offset = origin_range.begin - dest_range.begin
    #       return dest_point + offset
    #     end
    #   end

    #   nil
    # end
  end
end
