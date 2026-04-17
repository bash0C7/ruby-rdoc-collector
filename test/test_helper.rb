require 'test/unit'
require 'fileutils'
require 'tmpdir'
require 'json'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'ruby_rdoc_collector'

FIXTURE_DIR = File.expand_path('fixtures', __dir__)

StubRunner = ->(_prompt) { 'これは翻訳されたテキスト。' }

class EchoRunner
  attr_reader :calls

  def initialize(response: 'JP')
    @response = response
    @calls    = 0
  end

  def call(_prompt)
    @calls += 1
    @response
  end
end

class FailingRunner
  attr_reader :calls

  def initialize(fail_count: 1, eventual: 'JP')
    @fail_count = fail_count
    @eventual   = eventual
    @calls      = 0
  end

  def call(_prompt)
    @calls += 1
    if @calls <= @fail_count
      raise RubyRdocCollector::Translator::TranslationError, 'transient'
    end
    @eventual
  end
end

# Shared test doubles and factory for Collector tests.
# Tests include this module to access StubFetcher/StubParser/build_collector.
module RubyRdocCollectorTestSupport
  class StubFetcher
    def initialize(dir); @dir = dir; end
    def fetch; @dir; end
  end

  class StubParser
    def initialize(entities); @entities = entities; end
    def parse(_dir); @entities; end
  end

  # Build a Collector wired with stubs. Defaults draw from instance variables
  # set by the including test (@translator, @baseline, @output_dir).
  def build_collector(entities, translator: nil, baseline: nil, output_dir: nil, file_writer: nil)
    opts = {
      fetcher:    StubFetcher.new('/fake'),
      parser:     StubParser.new(entities),
      translator: translator || @translator,
      formatter:  RubyRdocCollector::MarkdownFormatter.new,
      baseline:   baseline   || @baseline,
      output_dir: output_dir || @output_dir
    }
    opts[:file_writer] = file_writer if file_writer
    RubyRdocCollector::Collector.new({}, **opts)
  end
end
