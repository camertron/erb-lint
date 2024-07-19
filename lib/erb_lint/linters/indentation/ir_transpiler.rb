# frozen_string_literal: true

require "erb_lint/linters/indentation/ir"
require "erb_lint/linters/self_closing_tag"
require "erb_lint/utils/source_map"

module ERBLint
  module Linters
    module Indentation
      class IRTranspiler
        SELF_CLOSING_TAGS = ERBLint::Linters::SelfClosingTag::SELF_CLOSING_TAGS

        def self.transpile(original_source, target_ruby_version)
          transpiler = new
          transpiler.visit(original_source.ast)

          ir_source = ::RuboCop::ProcessedSource.new(
            transpiler.ir_source,
            target_ruby_version,
            "#{original_source.filename} (intermediate)"
          )

          IR.new(
            original_source,
            ir_source,
            transpiler.source_map
          )
        end

        attr_reader :source_map, :ir_source

        def initialize
          @ir_source = +""
          @source_map = ::ERBLint::Utils::SourceMap.new
          @inside_pre = false
          @tag_stack = []
        end

        def visit(node)
          send(:"visit_#{node.type}", node)
        end

        private

        def visit_document(node)
          visit_children(node)
        end

        def visit_tag(node)
          tag = BetterHtml::Tree::Tag.from_node(node)
          source = node.location.source_buffer.source

          if tag.closing?
            visit_closing_tag(node, tag, source)
          elsif !tag.self_closing?
            # we've reached a regular 'ol tag
            visit_regular_tag(node, tag, source)
          end
        end

        def visit_closing_tag(node, tag, source)
          # Ignore closing tags for void elements like <input>. They are technically invalid
          # HTML, but we shouldn't let them monkey with the transpilation process if they exist.
          return if SELF_CLOSING_TAGS.include?(tag.name)

          if @tag_stack.pop == "pre"
            @inside_pre = false

            if (idx = source.rindex(/[[:space:]&&[^\r\n]]*\r?\n/, node.location.begin_pos))
              leading_ws = source[idx...node.location.begin_pos]
              emit(leading_ws, idx, leading_ws)
            end
          end

          pos = emit(node.loc.source, node.loc.begin_pos, "}")
          emit("", pos, ";")
        end

        def visit_regular_tag(node, tag, source)
          @tag_stack.push(tag.name)

          tag_loc = node.loc.with(end_pos: tag.name_node.loc.end_pos)
          tag_replacement = "".ljust(tag_loc.source.size, "tag")

          emit(tag_loc.source, tag_loc.begin_pos, "#{tag_replacement}(")
          _, _, attributes = *node
          visit_attributes(attributes) if attributes
          @ir_source << ")"

          # So-called "void" elements like <input>, <img>, etc, shouldn't have a closing
          # tag, but are also not self-closing. They have only an opening tag.
          @ir_source << if SELF_CLOSING_TAGS.include?(tag.name)
            ";"
          else
            " {"
          end

          if tag.name == "pre"
            @inside_pre = true

            if (idx = source.index(/[[:space:]&&[^\r\n]]*\r?\n/, node.location.end_pos + 1))
              @ir_source << source[node.location.end_pos...idx]
            end
          end
        end

        def visit_attributes(node)
          each_attribute_in(node) do |attr_str, sep, attr_node|
            replacement_line = "".ljust(attr_str.size - 1, "line")

            emit(
              attr_node.loc.source,
              attr_node.loc.begin_pos,
              "#{replacement_line},#{sep}"
            )
          end
        end

        def each_attribute_in(node)
          return if node.children.empty?

          if node.children.size == 1
            only_child = node.children.first
            yield only_child.loc.source, "", only_child
            return
          end

          node.children.each_cons(2) do |attr1, attr2|
            sep = if attr1.loc.end_pos != attr2.loc.begin_pos
              attr1.loc.with(begin_pos: attr1.loc.end_pos, end_pos: attr2.loc.begin_pos).source
            else
              ""
            end

            yield attr1.loc.source, sep, attr1
          end

          last_attr = node.children.last
          yield last_attr.loc.source, nil, last_attr
        end

        def visit_erb(node)
          return if @inside_pre

          indicator, _, code_node, = *node
          code = code_node.loc.source

          if indicator && indicator.loc.source == "#"
            emit(node.loc.source, node.loc.begin_pos, "##{code}")
            return
          end

          tag_ends_on_newline = node.loc.source_buffer.source.match(/\s*\n/, node.loc.end_pos)&.begin(0) == node.loc.end_pos

          starts_on_newline = code.start_with?("\n")
          ends_on_newline = code.end_with?("\n")
          is_multiline = code.strip.include?("\n")
          trailing_block = code.match(/((?:do|{)\s*)\z/)&.captures&.[](0)
          leading_ws, code, trailing_ws = ws_split(code)

          # Ignore if code starts on a new line and ends with a block. Normally we can wrap
          # multi-line code chunks like this in begin/end to represent a level of indentation,
          # but that doesn't work when the code ends with a block. We forego checking indentation
          # in these hopefully rare cases.
          if is_multiline && starts_on_newline && trailing_block
            emit(node.loc.source, node.loc.begin_pos, "__with_block #{trailing_block}")
            return
          end

          tag_start = @ir_source.size
          tag_with_indicator = "<%#{indicator&.loc&.source}"

          if is_multiline
            if starts_on_newline
              @ir_source << "begin"
            else
              @ir_source << "".ljust(tag_with_indicator.size - 1, "placeholder")
              @ir_source << ";"
            end
          end

          if !is_multiline && !tag_ends_on_newline
            @ir_source << "".ljust(tag_with_indicator.size + leading_ws.size - 1, "placeholder")
            @ir_source << ";"
          end

          @ir_source << leading_ws if starts_on_newline
          code_start = @ir_source.size
          @ir_source << code
          code_end = @ir_source.size
          @ir_source << trailing_ws if ends_on_newline

          # sourcemap entry for the entire ERB tag
          @source_map.add(
            origin: node.loc.to_range,
            dest: tag_start...@ir_source.size
          )

          # sourcemap entry for code only
          @source_map.add(
            origin: code_node.loc.adjust(begin_pos: leading_ws.size, end_pos: -trailing_ws.size).to_range,
            dest: code_start...code_end
          )

          if is_multiline && starts_on_newline
            @ir_source << "end"
          else
            @ir_source << ";" unless ends_on_newline
          end

          if !is_multiline && !tag_ends_on_newline
            placeholder_size = 2 + leading_ws.size - 1
            placeholder_size -= 1 unless ends_on_newline
            @ir_source << "".ljust(placeholder_size, "placeholder")
            @ir_source << ";"
          end
        end

        def ws_split(str)
          leading_ws = str.match(/\A\s*/)[0]
          trailing_ws = str.match(/\s*\z/, leading_ws.size)[0]
          text = str[leading_ws.size...(str.size - trailing_ws.size)]

          [leading_ws, text, trailing_ws]
        end

        def visit_text(node)
          return if @inside_pre

          pos = node.loc.begin_pos

          node.children.each do |child_node|
            if child_node.is_a?(String)
              pos = emit_string(child_node, pos) do |text, pos|
                if text.size > 1
                  # -1 for semicolon
                  pos = emit(text, pos, "".ljust(text.size - 1, "text"))
                  emit("", pos, ";")
                else
                  pos
                end
              end
            else
              visit(child_node)
              pos += child_node.loc.source.size
            end
          end
        end

        def emit_string(origin_str, pos, &block)
          leading_ws, text, trailing_ws = ws_split(origin_str)
          pos = emit(leading_ws, pos, leading_ws) unless leading_ws.empty?

          if text.match(/\r?\n/)
            text.split(/(\r?\n)/).each_slice(2) do |chunk, newline|
              pos = emit_string(chunk, pos, &block)
              pos = emit(newline, pos, newline) if newline
            end
          elsif !text.empty?
            pos = yield(text, pos)
          end

          pos = emit(trailing_ws, pos, trailing_ws) unless trailing_ws.empty?
          pos
        end

        def emit(origin_str, origin_begin, ir_str)
          @source_map.add(
            origin: origin_begin...(origin_begin + origin_str.size),
            dest: @ir_source.size...(@ir_source.size + ir_str.size)
          )

          @ir_source << ir_str
          origin_begin + origin_str.size
        end

        def visit_comment(node)
          return if @inside_pre

          # Ignore comments that appear at the end of some other content, since appearing eg.
          # between tag curly braces will cause the rest of the tag body to be indented to
          # the same level as the comment, which is wrong.
          return unless on_own_line?(node)

          emit(node.loc.source, node.loc.begin_pos, "__comment")
          @ir_source << ";"
        end

        def visit_children(node)
          node.children.each do |child_node|
            visit(child_node) if child_node.is_a?(BetterHtml::AST::Node)
          end
        end

        def on_own_line?(node)
          return true if node.loc.begin_pos == 0

          if (line_start = node.loc.source_buffer.source.rindex(/\A|\r?\n/, node.loc.begin_pos))
            node.loc.with(begin_pos: line_start, end_pos: node.loc.begin_pos).source =~ /\A\s*\z/
          end
        end
      end
    end
  end
end
