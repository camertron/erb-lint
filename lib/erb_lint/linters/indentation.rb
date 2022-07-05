# frozen_string_literal: true

require "pry-byebug"

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
          @source_map = ::ERBLint::SourceMap.new
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
          start_pos = @output.size

          if tag.closing?
            @output << "}"
          elsif !tag.self_closing?
            @output << "__tag {"
          end
        end

        def visit_erb(node)
          indicator_node, _, code_node, = *node
          code = code_node.loc.source
          len = code.size

          code.lstrip!
          leading_ws_len = len - code.size
          code.rstrip!
          trailing_ws_len = len - code.size - leading_ws_len

          @source_map.add(
            origin: node.loc.begin_pos...(code_node.loc.begin_pos + leading_ws_len),
            dest: @output.size...@output.size
          )

          code_loc = code_node.loc

          @source_map.add(
            origin: (code_loc.begin_pos + leading_ws_len)...(code_loc.end_pos - trailing_ws_len),
            dest: @output.size...(@output.size + code.size)
          )

          @output << code

          @source_map.add(
            origin: (code_node.loc.end_pos - trailing_ws_len)...node.loc.end_pos,
            dest: @output.size...@output.size
          )
        end

        def visit_text(node)
          pos = node.loc.begin_pos

          node.children.each do |child_node|
            if child_node.is_a?(String)
              if child_node =~ /\A\s*\z/
                @source_map.add(
                  origin: pos...(pos + child_node.size),
                  dest: @output.size...(@output.size + child_node.size)
                )

                @output << child_node
                pos += child_node.size
              end
            else
              visit(child_node)
              pos += child_node.loc.source.size
            end
          end
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
      end
      self.config_schema = ConfigSchema

      SCHEMA_TO_COP_MAP = {
        "Layout/IndentationWidth" => {
          "Width" => :width
        },

        "Layout/BlockAlignment" => {
          "EnforcedStyleAlignWith" => :enforced_style_block_align_with
        }
      }

      SCHEMA_TO_COP_MAP.freeze

      def initialize(file_loader, config)
        super

        @rubocop_config = ::RuboCop::Config.create(
          cop_config, "file.yml", check: false
        )
      end

      def run(processed_source)
        ir = IRTranspiler.transpile(processed_source.ast)
        ir_source = rubocop_processed_source(ir.source, "(intermediate)")
        report = build_team.investigate(ir_source)

        report.offenses.each do |offense|
          add_offense(processed_source, offense, ir.source_map)
        end
      end

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
              "Enabled" => true
            }
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
        )
      end

      def add_offense(processed_source, rubocop_offense, source_map)
        context = if rubocop_offense.corrected?
          { rubocop_correction: rubocop_offense.corrector, source_map: source_map }
        end

        loc = processed_source.to_source_range(
          source_map.translate(rubocop_offense.location.to_range)
        )

        super(
          loc,
          rubocop_offense.message.strip,
          context,
          rubocop_offense.severity.name
        )
      end
    end
  end
end
