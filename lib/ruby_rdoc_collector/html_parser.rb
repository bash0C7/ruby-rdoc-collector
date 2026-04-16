require 'json'
require 'oga'
require 'cgi'

module RubyRdocCollector
  class HtmlParser
    class ParseError < StandardError; end

    def parse(extracted_dir)
      index = load_search_index(extracted_dir)
      class_entries = index.select { |e| e['type'] == 'class' || e['type'] == 'module' }
      method_entries = index.select { |e| %w[class_method instance_method].include?(e['type']) }

      class_entries.filter_map do |cls|
        html_path = File.join(extracted_dir, cls['path'])
        next unless File.exist?(html_path)

        doc = Oga.parse_html(File.read(html_path))
        methods = build_methods(cls['full_name'], method_entries, doc)

        ClassEntity.new(
          name:        cls['full_name'],
          description: extract_description(doc),
          methods:     methods,
          constants:   [],
          superclass:  extract_superclass(doc)
        )
      end
    end

    private

    def load_search_index(dir)
      js_path = File.join(dir, 'js', 'search_data.js')
      js_path = File.join(dir, 'search_data.js') unless File.exist?(js_path)
      raise ParseError, "search_data.js not found in #{dir}" unless File.exist?(js_path)

      content = File.read(js_path)
      json_str = content.sub(/\Avar search_data = /, '').sub(/;\s*\z/, '')
      JSON.parse(json_str)['index']
    rescue JSON::ParserError => e
      raise ParseError, "search_data.js parse error: #{e.message}"
    end

    def extract_description(doc)
      section = doc.css('section.description').first
      section ? inner_html(section).strip : ''
    end

    def extract_superclass(doc)
      parent_section = doc.css('#parent-class-section').first
      return nil unless parent_section

      first_link = parent_section.css('a').first
      first_link ? first_link.text.strip : nil
    end

    def build_methods(class_full_name, all_method_entries, doc)
      class_methods = all_method_entries.select do |m|
        m['full_name'].start_with?("#{class_full_name}#") ||
          m['full_name'].start_with?("#{class_full_name}::")
      end

      class_methods.filter_map do |m|
        fragment = m['path'].split('#', 2).last
        next unless fragment

        method_div = doc.xpath(".//*[@id='#{fragment}']").first

        call_seq = nil
        description = m['snippet'] || ''

        if method_div
          cs_el = method_div.css('.method-callseq').first
          call_seq = CGI.unescapeHTML(cs_el.text.strip) if cs_el

          desc_el = method_div.css('.method-description').first
          description = inner_html(desc_el).strip if desc_el
        end

        MethodEntry.new(
          name:        m['name'],
          call_seq:    call_seq,
          description: description
        )
      end
    end

    def inner_html(node)
      node.children.map { |c| c.to_xml }.join
    end
  end
end
