# frozen_string_literal: true

require "pry-byebug"
require "erb_lint/linters/self_closing_tag"
require "erb_lint/utils/source_map"
require "erb_lint/utils/source_map_corrector"

require "erb_lint/linters/indentation/block_alignment"

module ERBLint
  module Linters
    # Warns when HTML and ERB tags are not indented properly.
    class Indentation < Linter
      include LinterRegistry

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

      class IRTranspiler
        SELF_CLOSING_TAGS = ERBLint::Linters::SelfClosingTag::SELF_CLOSING_TAGS

        def self.transpile(original_source, target_ruby_version)
          transpiler = new
          transpiler.visit(original_source.ast)

          ir_source = ::RuboCop::ProcessedSource.new(
            transpiler.output,
            target_ruby_version,
            "(intermediate)"
          )

          IR.new(
            original_source,
            ir_source,
            transpiler.source_map
          )
        end

        attr_reader :source_map, :output

        def initialize
          @output = +""
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
          elsif !tag.self_closing?
            @tag_stack.push(tag.name)

            tag_loc = node.loc.with(end_pos: tag.name_node.loc.end_pos)
            body_loc = tag.loc.with(begin_pos: tag.name_node.loc.end_pos, end_pos: tag.loc.end_pos - 1)

            pos = emit(tag_loc, node.loc.begin_pos, "__tag")

            # So-called "void" elements like <input>, <img>, etc, shouldn't have a closing
            # tag, but are also not self-closing. They have only an opening tag.
            if SELF_CLOSING_TAGS.include?(tag.name)
              emit("", pos, ";")
            else
              emit("", pos, " {")
            end

            if tag.name == "pre"
              @inside_pre = true

              if (idx = source.index(/[[:space:]&&[^\r\n]]*\r?\n/, node.location.end_pos + 1))
                @output << source[node.location.end_pos...idx]
              end
            end
          end
        end

        def visit_erb(node)
          return if @inside_pre

          indicator, _, code_node, = *node

          if indicator && indicator.loc.source == "#"
            emit(node.loc.source, node.loc.begin_pos, "__comment")
            @output << ";"
            return
          end

          code = code_node.loc.source
          is_multiline = code.start_with?("\n")
          leading_ws, code, trailing_ws = ws_split(code)

          if is_multiline
            @output << "begin"

            @source_map.add(
              origin: code_node.loc.begin_pos...(code_node.loc.begin_pos + leading_ws.size),
              dest: @output.size...(@output.size + leading_ws.size)
            )

            @output << leading_ws
          end

          @source_map.add(
            origin: node.loc.to_range,
            dest: @output.size...(@output.size + code.size)
          )

          @output << code
          @output << ";"

          if is_multiline
            @source_map.add(
              origin: (code_node.loc.end_pos - trailing_ws.size)...code_node.loc.end_pos,
              dest: @output.size...(@output.size + trailing_ws.size)
            )

            @output << trailing_ws
            @output << ";" unless code_node.loc.source.end_with?("\n")
            @output << "end;"
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
                pos = emit(text, pos, "__text")
                emit("", pos, ";")
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

        def emit(origin_str, origin_begin, dest_str)
          @source_map.add(
            origin: origin_begin...(origin_begin + origin_str.size),
            dest: @output.size...(@output.size + dest_str.size)
          )

          @output << dest_str
          origin_begin + origin_str.size
        end

        def visit_comment(node)
          return if @inside_pre

          # Ignore comments that appear at the end of some other content, since appearing eg.
          # between tag curly braces will cause the rest of the tag body to be indented to
          # the same level as the comment, which is wrong.
          return unless on_own_line?(node)

          emit(node.loc.source, node.loc.begin_pos, "__comment")
          @output << ";"
        end

        def visit_children(node)
          node.children.each do |child_node|
            visit(child_node) if child_node.is_a?(BetterHtml::AST::Node)
          end
        end

        private

        def on_own_line?(node)
          return true if node.loc.begin_pos == 0

          if (line_start = node.loc.source_buffer.source.rindex(/\A|\r?\n/, node.loc.begin_pos))
            node.loc.with(begin_pos: line_start, end_pos: node.loc.begin_pos).source =~ /\A\s*\z/
          end
        end
      end

      class ConfigSchema < LinterConfig
        INDENTATION_WIDTH_DEFAULTS = RuboCop::ConfigLoader.default_configuration["Layout/IndentationWidth"]
        BLOCK_ALIGNMENT_DEFAULTS = RuboCop::ConfigLoader.default_configuration["Layout/BlockAlignment"]
        BEGIN_END_ALIGNMENT_DEFAULTS = RuboCop::ConfigLoader.default_configuration["Layout/BeginEndAlignment"]
        END_ALIGNMENT_DEFAULTS = RuboCop::ConfigLoader.default_configuration["Layout/EndAlignment"]
        ELSE_ALIGNMENT_DEFAULTS = RuboCop::ConfigLoader.default_configuration["Layout/ElseAlignment"]

        property(
          :width,
          converts: :to_i,
          accepts: Integer,
          default: INDENTATION_WIDTH_DEFAULTS["Width"]
        )

        property(
          :enforced_style_block_align_with,
          accepts: BLOCK_ALIGNMENT_DEFAULTS["SupportedStylesAlignWith"],
          default: BLOCK_ALIGNMENT_DEFAULTS["EnforcedStyleAlignWith"]
        )

        property(
          :enforced_style_begin_end_align_with,
          accepts: BEGIN_END_ALIGNMENT_DEFAULTS["SupportedStylesAlignWith"],
          default: BEGIN_END_ALIGNMENT_DEFAULTS["EnforcedStyleAlignWith"]
        )

        property(
          :enforced_style_end_align_with,
          accepts: END_ALIGNMENT_DEFAULTS["SupportedStylesAlignWith"],
          default: END_ALIGNMENT_DEFAULTS["EnforcedStyleAlignWith"]
        )

        property(
          :enforced_style_else_align_with,
          accepts: ELSE_ALIGNMENT_DEFAULTS["SupportedStylesAlignWith"],
          default: ELSE_ALIGNMENT_DEFAULTS["EnforcedStyleAlignWith"]
        )
      end
      self.config_schema = ConfigSchema

      SCHEMA_TO_COP_MAP = {
        "Layout/IndentationWidth" => {
          "Width" => :width,
        },

        "Layout/BlockAlignment" => {
          "EnforcedStyleAlignWith" => :enforced_style_block_align_with,
        },

        "Layout/BeginEndAlignment" => {
          "EnforcedStyleAlignWith" => :enforced_style_begin_end_align_with
        },

        "Layout/EndAlignment" => {
          "EnforcedStyleAlignWith" => :enforced_style_end_align_with
        },

        "Layout/ElseAlignment" => {
          "EnforcedStyleAlignWith" => :enforced_style_else_align_with
        },
      }

      SCHEMA_TO_COP_MAP.freeze

      def initialize(file_loader, config)
        super

        @rubocop_config = if ::RuboCop::Config.method(:create).arity < 0
          ::RuboCop::Config.create(cop_config, "file.yml", check: false)
        else
          ::RuboCop::Config.create(cop_config, "file.yml")
        end
      end

      def run(original_source)
        ir = IRTranspiler.transpile(original_source, @rubocop_config.target_ruby_version)
        team = build_team

        block_alignment_cop = team.cops.find { |cop| cop.is_a?(::ERBLint::Linters::Indentation::BlockAlignment) }
        block_alignment_cop.bind_to(ir)

        each_offense_in(ir, team) do |offense, correction|
          add_offense(original_source, offense, correction, ir)
        end
      end

      if ::RuboCop::Version::STRING.to_f >= 0.87
        def autocorrect(original_source, offense)
          return unless offense.context

          rubocop_correction = offense.context[:rubocop_correction]
          return unless rubocop_correction

          ir = offense.context[:ir]
          return unless ir

          lambda do |corrector|
            rubocop_correction.as_nested_actions.each do |(action, ir_range, *replacement_args)|
              if (original_range = ir.translate(ir_range))
                corrector.send(action, original_range, *replacement_args)
              end
            end
          end
        end
      else
        def autocorrect(original_source, offense)
          return unless offense.context

          lambda do |corrector|
            passthrough = Utils::SourceMapCorrector.new(
              original_source,
              corrector,
              offense.context[:source_map],
            )
            offense.context[:rubocop_correction].call(passthrough)
          end
        end
      end

      private

      def cop_config
        @cop_config ||= begin
          default_config = RuboCop::ConfigLoader.default_configuration

          cop_classes.each_with_object({}) do |cop_class, memo|
            map = SCHEMA_TO_COP_MAP[cop_class.cop_name] || {}

            custom_config = map.each_with_object({}) do |(cop_option, config_option), config_memo|
              config_memo[cop_option] = @config.send(config_option)
            end

            memo[cop_class.cop_name] = {
              **default_config[cop_class.cop_name],
              **custom_config,
              "Enabled" => true,
            }
          end
        end
      end

      if ::RuboCop::Version::STRING.to_f >= 0.87
        def each_offense_in(ir, team)
          report = team.investigate(ir.ir_source)
          report.offenses.each do |offense|
            yield offense, offense.corrector
          end
        end
      else
        def each_offense_in(ir, team)
          team.inspect_file(ir.ir_source)

          team.cops.each do |cop|
            correction_offset = 0
            cop.offenses.reject(&:disabled?).each do |offense|
              if offense.corrected?
                correction = cop.corrections[correction_offset]
                correction_offset += 1
              end

              yield offense, correction
            end
          end
        end
      end

      def cop_classes
        @cop_classes ||= ::RuboCop::Cop::Registry.new([
          ::RuboCop::Cop::Layout::IndentationWidth,
          ::RuboCop::Cop::Layout::IndentationConsistency,
          # ::RuboCop::Cop::Layout::BlockAlignment,
          ::ERBLint::Linters::Indentation::BlockAlignment,
          ::RuboCop::Cop::Layout::BeginEndAlignment,
          ::RuboCop::Cop::Layout::EndAlignment,
          ::RuboCop::Cop::Layout::ElseAlignment,
        ])
      end

      def build_team
        ::RuboCop::Cop::Team.new(
          cop_classes,
          @rubocop_config,
          extra_details: true,
          display_cop_names: true,
          autocorrect: true,
          auto_correct: true,
          stdin: "",
          parallel: false,
          debug: true,
        )
      end

      def add_offense(original_source, rubocop_offense, correction, ir)
        context = if rubocop_offense.corrected?
          { rubocop_correction: correction, ir: ir }
        end

        origin_loc = ir.translate(rubocop_offense.location)

        unless origin_loc
          begin_pos = ir.translate_beginning(rubocop_offense.location.begin_pos)
          return unless begin_pos

          origin_loc = begin_pos...begin_pos
        end

        origin_loc = original_source.to_source_range(origin_loc)

        super(
          origin_loc,
          rubocop_offense.message.strip,
          context,
          rubocop_offense.severity.name
        )
      end
    end
  end
end
