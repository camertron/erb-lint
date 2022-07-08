# frozen_string_literal: true

require "pry-byebug"
require "erb_lint/utils/source_map"
require "erb_lint/utils/source_map_corrector"

module ERBLint
  module Linters
    # Warns when HTML and ERB tags are not indented properly.
    class Indentation < Linter
      include LinterRegistry

      class IR
        attr_reader :source, :source_map

        def initialize(source, source_map)
          @source = source
          @source_map = source_map
        end
      end

      class IRTranspiler
        def self.transpile(ast)
          transpiler = new
          transpiler.visit(ast)
          IR.new(transpiler.output, transpiler.source_map)
        end

        attr_reader :source_map, :output

        def initialize
          @output = +""
          @source_map = ::ERBLint::Utils::SourceMap.new
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

          if tag.closing?
            emit(node.loc.source, node.loc.begin_pos, "}")
            @output << ";"
          elsif !tag.self_closing?
            emit(node.loc.source, node.loc.begin_pos, "__tag")
            @output << "{"
          end
        end

        def visit_erb(node)
          _, _, code_node, = *node
          code = code_node.loc.source
          is_multiline = code.start_with?("\n")
          leading_ws, code, trailing_ws = ws_split(code)

          if is_multiline
            @output << "begin"

            @source_map.add(
              origin: node.loc.begin_pos...(code_node.loc.begin_pos + leading_ws.size),
              dest: @output.size...(@output.size + leading_ws.size)
            )

            @output << leading_ws
          else
            @source_map.add(
              origin: node.loc.begin_pos...(code_node.loc.begin_pos + leading_ws.size),
              dest: @output.size...@output.size
            )
          end

          @source_map.add(
            origin: (code_node.loc.begin_pos + leading_ws.size)...(code_node.loc.end_pos - trailing_ws.size),
            dest: @output.size...(@output.size + code.size)
          )

          @output << code

          if is_multiline
            @source_map.add(
              origin: (code_node.loc.end_pos - trailing_ws.size)...node.loc.end_pos,
              dest: @output.size...(@output.size + trailing_ws.size)
            )

            @output << trailing_ws
            @output << ";" unless code_node.loc.source.end_with?("\n")
            @output << "end;"
          else
            @source_map.add(
              origin: (code_node.loc.end_pos - trailing_ws.size)...node.loc.end_pos,
              dest: @output.size...@output.size
            )
          end
        end

        def ws_split(str)
          leading_ws = str.match(/\A\s*/)[0]
          trailing_ws = str.match(/\s*\z/, leading_ws.size)[0]
          text = str[leading_ws.size...(str.size - trailing_ws.size)]

          [leading_ws, text, trailing_ws]
        end

        def visit_text(node)
          pos = node.loc.begin_pos

          node.children.each do |child_node|
            if child_node.is_a?(String)
              leading_ws, text, trailing_ws = ws_split(child_node)

              pos = emit(leading_ws, pos, leading_ws) unless leading_ws.empty?

              unless text.empty?
                pos = emit(text, pos, "__text")
                @output << ";"
              end

              emit(trailing_ws, pos, trailing_ws) unless trailing_ws.empty?
            else
              visit(child_node)
              pos += child_node.loc.source.size
            end
          end
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
          emit(node.loc.source, node.loc.begin_pos, "__comment")
          @output << ";"
        end

        def visit_children(node)
          node.children.each do |child_node|
            visit(child_node) if child_node.is_a?(BetterHtml::AST::Node)
          end
        end
      end

      class ConfigSchema < LinterConfig
        INDENTATION_WIDTH_DEFAULTS = RuboCop::ConfigLoader.default_configuration["Layout/IndentationWidth"]
        BLOCK_ALIGNMENT_DEFAULTS = RuboCop::ConfigLoader.default_configuration["Layout/BlockAlignment"]
        BEGIN_END_ALIGNMENT_DEFAULTS = RuboCop::ConfigLoader.default_configuration["Layout/BeginEndAlignment"]

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
        }
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

      def run(processed_source)
        ir = IRTranspiler.transpile(processed_source.ast)
        ir_source = rubocop_processed_source(ir.source, "(intermediate)")

        each_offense_in(ir_source, build_team) do |offense, correction|
          add_offense(processed_source, offense, correction, ir.source_map)
        end
      end

      if ::RuboCop::Version::STRING.to_f >= 0.87
        def autocorrect(processed_source, offense)
          return unless offense.context

          rubocop_correction = offense.context[:rubocop_correction]
          return unless rubocop_correction

          source_map = offense.context[:source_map]
          return unless source_map

          lambda do |corrector|
            rubocop_correction.as_nested_actions.each do |(action, range, *replacement_args)|
              if (origin_range = source_map.translate(range.to_range))
                corrector.send(action, processed_source.to_source_range(origin_range), *replacement_args)
              end
            end
          end
        end
      else
        def autocorrect(processed_source, offense)
          return unless offense.context

          lambda do |corrector|
            passthrough = Utils::SourceMapCorrector.new(
              processed_source,
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
        def each_offense_in(source, team)
          report = team.investigate(source)
          report.offenses.each do |offense|
            yield offense, offense.corrector
          end
        end
      else
        def each_offense_in(source, team)
          team.inspect_file(source)

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

      def rubocop_processed_source(content, filename)
        ::RuboCop::ProcessedSource.new(
          content,
          @rubocop_config.target_ruby_version,
          filename
        )
      end

      def cop_classes
        @cop_classes ||= ::RuboCop::Cop::Registry.new([
          ::RuboCop::Cop::Layout::IndentationWidth,
          ::RuboCop::Cop::Layout::IndentationConsistency,
          ::RuboCop::Cop::Layout::BlockAlignment,
          ::RuboCop::Cop::Layout::BeginEndAlignment,
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

      def add_offense(processed_source, rubocop_offense, correction, source_map)
        context = if rubocop_offense.corrected?
          { rubocop_correction: correction, source_map: source_map }
        end

        origin_loc = source_map.translate(rubocop_offense.location.to_range)
        unless origin_loc
          begin_pos = source_map.translate_beginning(rubocop_offense.location.begin_pos)
          origin_loc = begin_pos...begin_pos
        end

        origin_loc = processed_source.to_source_range(origin_loc)

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
