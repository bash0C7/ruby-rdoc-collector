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

  # C. parallel method translation + en_ wiring
  def test_all_methods_translated_in_parallel
    # Entity with 5 methods
    methods = (1..5).map do |i|
      RubyRdocCollector::MethodEntry.new(
        name: "method_#{i}", call_seq: nil, description: "desc #{i}"
      )
    end
    entity = RubyRdocCollector::ClassEntity.new(
      name: 'Multi', description: 'class desc', methods: methods, constants: [], superclass: 'Object'
    )

    invocation_count = Concurrent::AtomicFixnum.new(0) rescue nil
    # Use a thread-safe counter via Mutex
    mutex   = Mutex.new
    counter = 0
    counting_runner = lambda do |_prompt|
      mutex.synchronize { counter += 1 }
      'JP'
    end
    cache = RubyRdocCollector::TranslationCache.new(cache_dir: Dir.mktmpdir('cpara'))
    counting_translator = RubyRdocCollector::Translator.new(runner: counting_runner, cache: cache, sleeper: ->(_s) {})

    c = RubyRdocCollector::Collector.new({},
      fetcher:    StubFetcher.new('/fake'),
      parser:     StubParser.new([entity]),
      translator: counting_translator,
      formatter:  RubyRdocCollector::MarkdownFormatter.new)
    results = c.collect
    assert_equal 1, results.size
    # 1 call for class description + 5 for methods = 6 total
    assert_equal 6, counter
  end

  def test_method_translation_error_per_method_does_not_kill_class
    # One method always fails, others succeed; class should still appear in results
    methods = [
      RubyRdocCollector::MethodEntry.new(name: 'ok1',    call_seq: nil, description: 'ok desc 1'),
      RubyRdocCollector::MethodEntry.new(name: 'bad',    call_seq: nil, description: 'FAIL THIS'),
      RubyRdocCollector::MethodEntry.new(name: 'ok2',    call_seq: nil, description: 'ok desc 2'),
    ]
    entity = RubyRdocCollector::ClassEntity.new(
      name: 'PartialMethod', description: 'class desc', methods: methods, constants: [], superclass: 'Object'
    )
    error_runner = lambda do |prompt|
      raise RubyRdocCollector::Translator::TranslationError, 'boom' if prompt.include?('FAIL THIS')
      'JP'
    end
    cache = RubyRdocCollector::TranslationCache.new(cache_dir: Dir.mktmpdir('cperr'))
    boom_translator = RubyRdocCollector::Translator.new(runner: error_runner, cache: cache, max_retries: 1, sleeper: ->(_s) {})
    c = RubyRdocCollector::Collector.new({},
      fetcher:    StubFetcher.new('/fake'),
      parser:     StubParser.new([entity]),
      translator: boom_translator,
      formatter:  RubyRdocCollector::MarkdownFormatter.new)
    results = c.collect
    # Class should still be in results (not skipped entirely)
    assert_equal 1, results.size
    assert_include results.first[:source], 'PartialMethod'
  end

  # D. smoke escape hatches: RUBY_RDOC_TARGETS / RUBY_RDOC_MAX_METHODS env vars
  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def test_targets_env_filters_to_listed_classes_only
    entities = [build_entity('Keep1'), build_entity('Drop'), build_entity('Keep2')]
    c = RubyRdocCollector::Collector.new({},
      fetcher:    StubFetcher.new('/fake'),
      parser:     StubParser.new(entities),
      translator: @translator,
      formatter:  RubyRdocCollector::MarkdownFormatter.new)
    results = with_env('RUBY_RDOC_TARGETS' => 'Keep1, Keep2') { c.collect }
    sources = results.map { |r| r[:source] }
    assert_equal 2, results.size
    assert_include sources, 'ruby/ruby:rdoc/trunk/Keep1'
    assert_include sources, 'ruby/ruby:rdoc/trunk/Keep2'
    assert_not_include sources, 'ruby/ruby:rdoc/trunk/Drop'
  end

  def test_max_methods_env_caps_methods_per_class
    methods = (1..10).map do |i|
      RubyRdocCollector::MethodEntry.new(name: "m#{i}", call_seq: nil, description: "d#{i}")
    end
    entity = RubyRdocCollector::ClassEntity.new(
      name: 'Big', description: 'desc', methods: methods, constants: [], superclass: 'Object'
    )
    counter = 0
    mutex   = Mutex.new
    counting = lambda { |_p| mutex.synchronize { counter += 1 }; 'JP' }
    cache = RubyRdocCollector::TranslationCache.new(cache_dir: Dir.mktmpdir('csmoke'))
    t = RubyRdocCollector::Translator.new(runner: counting, cache: cache, sleeper: ->(_s) {})
    c = RubyRdocCollector::Collector.new({},
      fetcher:    StubFetcher.new('/fake'),
      parser:     StubParser.new([entity]),
      translator: t,
      formatter:  RubyRdocCollector::MarkdownFormatter.new)
    with_env('RUBY_RDOC_MAX_METHODS' => '3') { c.collect }
    # 1 class desc + 3 methods (capped from 10) = 4 calls
    assert_equal 4, counter
  end

  def test_en_description_and_method_descriptions_wired_to_formatter
    # Verify that en_ fields appear in the output via <details> blocks
    methods = [
      RubyRdocCollector::MethodEntry.new(name: 'greet', call_seq: nil, description: 'Says hello.')
    ]
    entity = RubyRdocCollector::ClassEntity.new(
      name: 'Greeter', description: 'A greeter class.', methods: methods, constants: [], superclass: 'Object'
    )
    c = RubyRdocCollector::Collector.new({},
      fetcher:    StubFetcher.new('/fake'),
      parser:     StubParser.new([entity]),
      translator: @translator,
      formatter:  RubyRdocCollector::MarkdownFormatter.new)
    results = c.collect
    assert_equal 1, results.size
    content = results.first[:content]
    # English original details block for class description
    assert_include content, '<details>'
    assert_include content, 'A greeter class.'
    assert_include content, 'Says hello.'
  end
end
