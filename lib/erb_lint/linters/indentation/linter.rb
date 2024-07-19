# frozen_string_literal: true

require "erb_lint/utils/source_map_corrector"
require "erb_lint/linters/indentation/block_alignment"
require "erb_lint/linters/indentation/ir_transpiler"

module ERBLint
  module Linters
    module Indentation
      # Warns when HTML and ERB tags are not indented properly.
      class Linter < ::ERBLint::Linter
        include LinterRegistry

        class ConfigSchema < LinterConfig
          INDENTATION_WIDTH_DEFAULTS = RuboCop::ConfigLoader.default_configuration["Layout/IndentationWidth"]
          BLOCK_ALIGNMENT_DEFAULTS = RuboCop::ConfigLoader.default_configuration["Layout/BlockAlignment"]
          BEGIN_END_ALIGNMENT_DEFAULTS = RuboCop::ConfigLoader.default_configuration["Layout/BeginEndAlignment"]
          END_ALIGNMENT_DEFAULTS = RuboCop::ConfigLoader.default_configuration["Layout/EndAlignment"]
          ARGUMENT_ALIGNMENT_DEFAULTS = RuboCop::ConfigLoader.default_configuration["Layout/ArgumentAlignment"]

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
            :enforced_style_argument_alignment,
            accepts: ARGUMENT_ALIGNMENT_DEFAULTS["SupportedStyles"],
            default: ARGUMENT_ALIGNMENT_DEFAULTS["EnforcedStyle"]
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

          "Layout/ArgumentAlignment" => {
            "EnforcedStyle" => :enforced_style_argument_alignment
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

        def run(original_source)
          ir = IRTranspiler.transpile(original_source, @rubocop_config.target_ruby_version)
          puts(ir.ir_source.raw_source) if ENV["ERBLINT_DEBUG"] == "true"
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
            ::ERBLint::Linters::Indentation::BlockAlignment,
            ::RuboCop::Cop::Layout::BeginEndAlignment,
            ::RuboCop::Cop::Layout::EndAlignment,
            ::RuboCop::Cop::Layout::ElseAlignment,
            ::RuboCop::Cop::Layout::ArgumentAlignment,
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
end
