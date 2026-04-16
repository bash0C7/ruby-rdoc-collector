module RubyRdocCollector
  class MarkdownFormatter
    def format(entity, jp_description:, jp_method_descriptions:, en_description: nil, en_method_descriptions: nil)
      lines = []
      header = "# #{entity.name}"
      header += " (< #{entity.superclass})" if entity.superclass && !entity.superclass.empty?
      lines << header
      lines << ''
      lines << '## 概要'
      lines << ''
      lines << jp_description
      if en_description && !en_description.strip.empty?
        lines << ''
        lines << details_block(en_description)
      end
      lines << ''

      unless entity.methods.empty?
        lines << '## Methods'
        lines << ''
        entity.methods.each do |m|
          lines << "### #{m.name}"
          lines << ''
          if m.call_seq && !m.call_seq.empty?
            lines << '```'
            lines << m.call_seq
            lines << '```'
            lines << ''
          end
          jp = jp_method_descriptions[m.name]
          lines << (jp && !jp.empty? ? jp : (m.description || ''))
          en_m = en_method_descriptions && en_method_descriptions[m.name]
          if en_m && !en_m.strip.empty?
            lines << ''
            lines << details_block(en_m)
          end
          lines << ''
        end
      end

      lines.join("\n").rstrip + "\n"
    end

    private

    def details_block(text)
      "<details>\n<summary>Original (en)</summary>\n\n#{text}\n</details>"
    end
  end
end
