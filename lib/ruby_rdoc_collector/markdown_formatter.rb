module RubyRdocCollector
  class MarkdownFormatter
    def format(entity)
      lines = []
      header = "# #{entity.name}"
      header += " (< #{entity.superclass})" if entity.superclass && !entity.superclass.empty?
      lines << header
      lines << ''
      lines << '## Overview'
      lines << ''
      lines << (entity.description.to_s.empty? ? '' : entity.description)
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
          lines << (m.description || '')
          lines << ''
        end
      end

      lines.join("\n").rstrip + "\n"
    end
  end
end
