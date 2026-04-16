require_relative 'test_helper'

class TestCollector < Test::Unit::TestCase
  class StubFetcher
    def initialize(dir); @dir = dir; end
    def fetch; @dir; end
  end

  class StubParser
    def initialize(entities); @entities = entities; end
    def parse(_dir); @entities; end
  end

  def setup
    @dir   = Dir.mktmpdir('collector')
    cache  = RubyRdocCollector::TranslationCache.new(cache_dir: @dir)
    @translator = RubyRdocCollector::Translator.new(runner: EchoRunner.new(response: 'JP'), cache: cache, sleeper: ->(_s) {})
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def build_entity(name)
    RubyRdocCollector::ClassEntity.new(
      name: name, description: "desc of #{name}", methods: [], constants: [], superclass: 'Object'
    )
  end

  def test_collect_returns_content_and_source_per_class
    entities = [build_entity('String'), build_entity('Integer')]
    c = RubyRdocCollector::Collector.new({},
      fetcher:    StubFetcher.new('/fake'),
      parser:     StubParser.new(entities),
      translator: @translator,
      formatter:  RubyRdocCollector::MarkdownFormatter.new)
    results = c.collect
    assert_equal 2, results.size
    results.each do |r|
      assert_kind_of String, r[:content]
      assert_match %r{\Aruby/ruby:rdoc/trunk/}, r[:source]
    end
    sources = results.map { |r| r[:source] }
    assert_include sources, 'ruby/ruby:rdoc/trunk/String'
  end

  def test_partial_failure_skips_single_class_not_whole_batch
    entities = [build_entity('String'), build_entity('Integer')]
    always_fail_on_integer = lambda do |prompt|
      raise RubyRdocCollector::Translator::TranslationError, 'always' if prompt.include?('desc of Integer')
      'JP'
    end
    boom_translator = RubyRdocCollector::Translator.new(
      runner: always_fail_on_integer,
      cache:  RubyRdocCollector::TranslationCache.new(cache_dir: Dir.mktmpdir('c2')),
      max_retries: 1,
      sleeper: ->(_s) {}
    )
    c = RubyRdocCollector::Collector.new({},
      fetcher:    StubFetcher.new('/fake'),
      parser:     StubParser.new(entities),
      translator: boom_translator,
      formatter:  RubyRdocCollector::MarkdownFormatter.new)
    results = c.collect
    sources = results.map { |r| r[:source] }
    assert_equal 1, results.size
    assert_include sources, 'ruby/ruby:rdoc/trunk/String'
    assert_not_include sources, 'ruby/ruby:rdoc/trunk/Integer'
  end

  def test_since_and_before_are_ignored
    entities = [build_entity('A')]
    c = RubyRdocCollector::Collector.new({},
      fetcher:    StubFetcher.new('/fake'),
      parser:     StubParser.new(entities),
      translator: @translator,
      formatter:  RubyRdocCollector::MarkdownFormatter.new)
    r1 = c.collect(since: '2020-01-01', before: '2020-01-02')
    r2 = c.collect
    assert_equal r1, r2
  end
end
