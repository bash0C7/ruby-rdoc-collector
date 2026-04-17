require 'fileutils'

module RubyRdocCollector
  class Collector
    SOURCE_PREFIX = 'ruby/ruby:rdoc/trunk'

    attr_reader :output_dir

    def initialize(config,
                   fetcher:     nil,
                   parser:      nil,
                   formatter:   nil,
                   baseline:    nil,
                   output_dir:  nil,
                   file_writer: nil)
      @config      = config || {}
      @fetcher     = fetcher    || TarballFetcher.new(
        url: @config['url'] || TarballFetcher::DEFAULT_URL
      )
      @parser      = parser     || HtmlParser.new
      @formatter   = formatter  || MarkdownFormatter.new
      @baseline    = baseline   || SourceHashBaseline.new
      @output_dir  = output_dir || default_output_dir
      @file_writer = file_writer || method(:default_file_write)
    end

    def collect(since: nil, before: nil, &block)
      return enum_for(:collect, since: since, before: before) unless block_given?

      content_dir = @fetcher.fetch

      return if @fetcher.unchanged? && @baseline.completed? && !smoke_filter_active?

      smoke = smoke_filter_active?
      @baseline.mark_started unless smoke

      targets  = smoke_targets
      entities = @parser.parse(content_dir, targets: targets)
      entities = apply_max_methods_filter(entities)

      entities.each { |entity| process_entity(entity, &block) }

      unless smoke
        @baseline.cleanup_orphans unless entities.empty?
        @baseline.mark_completed
      end
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

    def process_entity(entity, &block)
      @baseline.mark_seen(entity.name)
      new_hash = @baseline.hash_for(entity)
      return unless @baseline.changed?(entity.name, new_hash)

      content  = @formatter.format(entity)
      record   = { content: content, source: "#{SOURCE_PREFIX}/#{entity.name}" }

      filename = sanitize_filename(entity.name) + '.md'
      begin
        @file_writer.call(@output_dir, filename, record[:content])
      rescue => e
        warn "[RubyRdocCollector::Collector] file save failed for #{entity.name}: #{e.message}"
        return
      end

      begin
        block.call(record)
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

    def apply_max_methods_filter(entities)
      max_methods = ENV['RUBY_RDOC_MAX_METHODS']&.to_i
      return entities unless max_methods && max_methods > 0
      entities.map { |e| e.with(methods: e.methods.first(max_methods)) }
    end
  end
end
