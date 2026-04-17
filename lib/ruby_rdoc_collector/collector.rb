require 'fileutils'

module RubyRdocCollector
  class Collector
    SOURCE_PREFIX    = 'ruby/ruby:rdoc/trunk'
    THREAD_POOL_SIZE = 4

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
      entities    = apply_smoke_filters(@parser.parse(content_dir))

      entities.each { |entity| process_entity(entity, &block) }

      @baseline.cleanup_orphans unless smoke_filter_active? || entities.empty?
    end

    private

    def smoke_filter_active?
      targets_raw = ENV['RUBY_RDOC_TARGETS']
      return true if targets_raw && !targets_raw.strip.empty?
      max_methods = ENV['RUBY_RDOC_MAX_METHODS']&.to_i
      max_methods && max_methods > 0
    end

    def process_entity(entity, &block)
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
        yield record
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

    # Smoke / integration-test escape hatches via env vars.
    # Default behavior unchanged (no filter, no cap) when both vars are unset/empty.
    #   RUBY_RDOC_TARGETS=Ruby::Box,Complex,Rational  → keep only those classes
    #   RUBY_RDOC_MAX_METHODS=20                      → cap methods/class to first N
    def apply_smoke_filters(entities)
      targets_raw = ENV['RUBY_RDOC_TARGETS']
      if targets_raw && !targets_raw.strip.empty?
        target_set = targets_raw.split(',').map(&:strip)
        entities = entities.select { |e| target_set.include?(e.name) }
      end
      max_methods = ENV['RUBY_RDOC_MAX_METHODS']&.to_i
      if max_methods && max_methods > 0
        entities = entities.map { |e| e.with(methods: e.methods.first(max_methods)) }
      end
      entities
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
