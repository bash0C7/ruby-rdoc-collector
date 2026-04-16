module RubyRdocCollector
  class Collector
    SOURCE_PREFIX  = 'ruby/ruby:rdoc/trunk'
    THREAD_POOL_SIZE = 4

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
      en_desc    = entity.description

      jp_methods = parallel_translate(entity.methods, threads: THREAD_POOL_SIZE) do |m|
        begin
          [m.name, @translator.translate(m.description)]
        rescue Translator::TranslationError => e
          warn "[RubyRdocCollector::Collector] skip method #{entity.name}##{m.name}: #{e.message}"
          [m.name, '']
        end
      end.to_h

      en_methods = entity.methods.to_h { |m| [m.name, m.description || ''] }

      content = @formatter.format(entity,
        jp_description:         jp_desc,
        jp_method_descriptions: jp_methods,
        en_description:         en_desc,
        en_method_descriptions: en_methods)
      { content: content, source: "#{SOURCE_PREFIX}/#{entity.name}" }
    rescue Translator::TranslationError => e
      warn "[RubyRdocCollector::Collector] skip #{entity.name}: #{e.message}"
      nil
    end

    # Parallel translation helper using a fixed-size thread pool.
    # @param items  [Array]  items to process
    # @param threads [Integer] pool size
    # @yield [item] block receives each item; must return the result
    # @return [Array] results in the same order as items
    def parallel_translate(items, threads:, &block)
      return [] if items.empty?

      results  = Array.new(items.size)
      queue    = Queue.new
      items.each_with_index { |item, i| queue << [i, item] }

      workers = [threads, items.size].min.times.map do
        Thread.new do
          until queue.empty?
            begin
              idx, item = queue.pop(true)  # non-blocking
            rescue ThreadError
              break  # queue empty
            end
            results[idx] = block.call(item)
          end
        end
      end
      workers.each(&:join)
      results
    end
  end
end
