module RubyRdocCollector
  class Collector
    SOURCE_PREFIX = 'ruby/ruby:rdoc/trunk'

    def initialize(config,
                   fetcher:    nil,
                   parser:     nil,
                   translator: nil,
                   formatter:  nil)
      @config     = config || {}
      @fetcher    = fetcher    || TarballFetcher.new(
        url: @config['url'] || TarballFetcher::DEFAULT_URL
      )
      @parser     = parser     || HtmlParser.new
      @translator = translator || Translator.new
      @formatter  = formatter  || MarkdownFormatter.new
    end

    def collect(since: nil, before: nil)
      content_dir = @fetcher.fetch
      entities = @parser.parse(content_dir)
      entities.filter_map { |e| safe_translate_and_format(e) }
    end

    private

    def safe_translate_and_format(entity)
      jp_desc    = @translator.translate(entity.description)
      jp_methods = entity.methods.to_h do |m|
        [m.name, @translator.translate(m.description)]
      end
      content = @formatter.format(entity, jp_description: jp_desc, jp_method_descriptions: jp_methods)
      { content: content, source: "#{SOURCE_PREFIX}/#{entity.name}" }
    rescue Translator::TranslationError => e
      warn "[RubyRdocCollector::Collector] skip #{entity.name}: #{e.message}"
      nil
    end
  end
end
