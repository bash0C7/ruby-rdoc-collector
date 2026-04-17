require 'test/unit'
require 'fileutils'
require 'tmpdir'
require 'json'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'ruby_rdoc_collector'

FIXTURE_DIR = File.expand_path('fixtures', __dir__)

# Shared test doubles and factory for Collector tests.
module RubyRdocCollectorTestSupport
  class StubFetcher
    def initialize(dir); @dir = dir; end
    def fetch; @dir; end
    def unchanged?; false; end
  end

  class StubParser
    def initialize(entities); @entities = entities; end
    def parse(_dir, targets: nil)
      return @entities if targets.nil?
      @entities.select { |e| targets.include?(e.name) }
    end
  end

  def build_collector(entities, baseline: nil, output_dir: nil, file_writer: nil)
    opts = {
      fetcher:    StubFetcher.new('/fake'),
      parser:     StubParser.new(entities),
      formatter:  RubyRdocCollector::MarkdownFormatter.new,
      baseline:   baseline   || @baseline,
      output_dir: output_dir || @output_dir
    }
    opts[:file_writer] = file_writer if file_writer
    RubyRdocCollector::Collector.new({}, **opts)
  end
end
