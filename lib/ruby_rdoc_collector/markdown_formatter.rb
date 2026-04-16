module RubyRdocCollector
  class MarkdownFormatter
    def format(entity, jp_description:, jp_method_descriptions:)
      lines = []
      header = "# #{entity.name}"
      header += " (< #{entity.superclass})" if entity.superclass && !entity.superclass.empty?
      lines << header
      lines << ''
      lines << '## 概要'
      lines << ''
      lines << jp_description
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
          lines << ''
        end
      end

      lines.join("\n").rstrip + "\n"
    end
  end
end
