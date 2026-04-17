require_relative 'test_helper'

class TestCollector < Test::Unit::TestCase
  include RubyRdocCollectorTestSupport

  def setup
    @dir        = Dir.mktmpdir('collector')
    @baseline   = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'baseline.yml'))
    @output_dir = File.join(@dir, 'out')
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
    c = build_collector(entities)
    results = c.collect.to_a
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
    c = build_collector(entities, translator: boom_translator)
    results = c.collect.to_a
    sources = results.map { |r| r[:source] }
    assert_equal 1, results.size
    assert_include sources, 'ruby/ruby:rdoc/trunk/String'
    assert_not_include sources, 'ruby/ruby:rdoc/trunk/Integer'
  end

  def test_since_and_before_are_ignored
    entities = [build_entity('A')]
    c = build_collector(entities)
    r1 = c.collect(since: '2020-01-01', before: '2020-01-02').to_a
    # fresh baseline + output_dir so second run yields too (else source_hash would skip)
    fresh_baseline = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'baseline2.yml'))
    c2 = build_collector(entities, baseline: fresh_baseline, output_dir: File.join(@dir, 'out2'))
    r2 = c2.collect.to_a
    # since/before ignored: content/source should be identical
    assert_equal r1.map { |r| r[:source] }, r2.map { |r| r[:source] }
    assert_equal r1.map { |r| r[:content] }, r2.map { |r| r[:content] }
  end

  # C. parallel method translation + en_ wiring
  def test_all_methods_translated_in_parallel
    methods = (1..5).map do |i|
      RubyRdocCollector::MethodEntry.new(
        name: "method_#{i}", call_seq: nil, description: "desc #{i}"
      )
    end
    entity = RubyRdocCollector::ClassEntity.new(
      name: 'Multi', description: 'class desc', methods: methods, constants: [], superclass: 'Object'
    )

    mutex   = Mutex.new
    counter = 0
    counting_runner = lambda do |_prompt|
      mutex.synchronize { counter += 1 }
      'JP'
    end
    cache = RubyRdocCollector::TranslationCache.new(cache_dir: Dir.mktmpdir('cpara'))
    counting_translator = RubyRdocCollector::Translator.new(runner: counting_runner, cache: cache, sleeper: ->(_s) {})

    c = build_collector([entity], translator: counting_translator)
    results = c.collect.to_a
    assert_equal 1, results.size
    # 1 call for class description + 5 for methods = 6 total
    assert_equal 6, counter
  end

  def test_method_translation_error_per_method_does_not_kill_class
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
    c = build_collector([entity], translator: boom_translator)
    results = c.collect.to_a
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
    c = build_collector(entities)
    results = with_env('RUBY_RDOC_TARGETS' => 'Keep1, Keep2') { c.collect.to_a }
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
    c = build_collector([entity], translator: t)
    with_env('RUBY_RDOC_MAX_METHODS' => '3') { c.collect.to_a }
    # 1 class desc + 3 methods (capped from 10) = 4 calls
    assert_equal 4, counter
  end

  def test_en_description_and_method_descriptions_wired_to_formatter
    methods = [
      RubyRdocCollector::MethodEntry.new(name: 'greet', call_seq: nil, description: 'Says hello.')
    ]
    entity = RubyRdocCollector::ClassEntity.new(
      name: 'Greeter', description: 'A greeter class.', methods: methods, constants: [], superclass: 'Object'
    )
    c = build_collector([entity])
    results = c.collect.to_a
    assert_equal 1, results.size
    content = results.first[:content]
    assert_include content, '<details>'
    assert_include content, 'A greeter class.'
    assert_include content, 'Says hello.'
  end
end
