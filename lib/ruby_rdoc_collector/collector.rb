require 'fileutils'

module RubyRdocCollector
  class Collector
    SOURCE_PREFIX    = 'ruby/ruby:rdoc/trunk'
    THREAD_POOL_SIZE = 4   # method-level concurrency within a class
    CLASS_POOL_SIZE  = 4   # class-level concurrency; total claude calls are globally
                           # capped by Translator's semaphore, so this can safely be
                           # >= THREAD_POOL_SIZE without exceeding claude budget.

    attr_reader :output_dir

    def initialize(config,
                   fetcher:     nil,
                   parser:      nil,
                   translator:  nil,
                   formatter:   nil,
                   baseline:    nil,
                   output_dir:  nil,
                   file_writer: nil)
      @config      = config || {}
      @fetcher     = fetcher    || TarballFetcher.new(
        url: @config['url'] || TarballFetcher::DEFAULT_URL
      )
      @parser      = parser     || HtmlParser.new
      @translator  = translator || Translator.new
      @formatter   = formatter  || MarkdownFormatter.new
      @baseline    = baseline   || SourceHashBaseline.new
      @output_dir  = output_dir || default_output_dir
      @file_writer = file_writer || method(:default_file_write)
    end

    def collect(since: nil, before: nil, &block)
      return enum_for(:collect, since: since, before: before) unless block_given?

      content_dir = @fetcher.fetch

      # Fast path: tarball unchanged AND baseline populated → nothing to do.
      # Smoke filters bypass this so TARGETS/MAX_METHODS always run.
      return if @fetcher.unchanged? && @baseline.populated? && !smoke_filter_active?

      targets  = smoke_targets
      entities = @parser.parse(content_dir, targets: targets)
      entities = apply_max_methods_filter(entities)

      process_entities_in_pool(entities, &block)

      @baseline.cleanup_orphans unless smoke_filter_active? || entities.empty?
    end

    private

    def smoke_targets
      raw = ENV['RUBY_RDOC_TARGETS']
      return nil if raw.nil? || raw.strip.empty?
      raw.split(',').map(&:strip)
    end

    def smoke_filter_active?
      return true if smoke_targets
      max_methods = ENV['RUBY_RDOC_MAX_METHODS']&.to_i
      max_methods && max_methods > 0
    end

    # Spawn CLASS_POOL_SIZE worker threads that pull entities from a shared
    # queue. Each worker does the full per-entity pipeline; the final yield
    # is serialized via @yield_mutex so the caller's block (typically
    # store.store) observes a single-writer DB contract.
    def process_entities_in_pool(entities, &block)
      return if entities.empty?

      yield_mutex = Mutex.new
      queue       = Queue.new
      entities.each { |e| queue << e }

      workers = [CLASS_POOL_SIZE, entities.size].min.times.map do
        Thread.new do
          until queue.empty?
            begin
              entity = queue.pop(true)
            rescue ThreadError
              break
            end
            process_entity(entity, yield_mutex, &block)
          end
        end
      end
      workers.each(&:join)
    end

    def process_entity(entity, yield_mutex, &block)
      @baseline.mark_seen(entity.name)
      new_hash = @baseline.hash_for(entity)
      return unless @baseline.changed?(entity.name, new_hash)

      record = safe_translate_and_format(entity)
      return unless record

      filename = sanitize_filename(entity.name) + '.md'
      begin
        @file_writer.call(@output_dir, filename, record[:content])
      rescue => e
        warn "[RubyRdocCollector::Collector] file save failed for #{entity.name}: #{e.message}"
        return
      end

      begin
        yield_mutex.synchronize { block.call(record) }
      rescue => e
        warn "[RubyRdocCollector::Collector] yield failed for #{entity.name}: #{e.message}"
        return
      end

      @baseline.persist_one(entity.name, new_hash)
    end

    def sanitize_filename(class_name)
      class_name.gsub('::', '__').gsub(/[^A-Za-z0-9_\-]/, '_')
    end

    def default_output_dir
      "/tmp/ruby-rdoc-#{Time.now.strftime('%Y%m%d%H%M%S')}"
    end

    def default_file_write(dir, filename, content)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, filename), content)
    end

    # RUBY_RDOC_MAX_METHODS=N caps methods/class to first N after parse.
    # (TARGETS filtering is applied earlier at parse-time via @parser.parse(..., targets:))
    def apply_max_methods_filter(entities)
      max_methods = ENV['RUBY_RDOC_MAX_METHODS']&.to_i
      return entities unless max_methods && max_methods > 0
      entities.map { |e| e.with(methods: e.methods.first(max_methods)) }
    end

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

    def parallel_translate(items, threads:, &block)
      return [] if items.empty?

      results  = Array.new(items.size)
      queue    = Queue.new
      items.each_with_index { |item, i| queue << [i, item] }

      workers = [threads, items.size].min.times.map do
        Thread.new do
          until queue.empty?
            begin
              idx, item = queue.pop(true)
            rescue ThreadError
              break
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
