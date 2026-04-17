require_relative 'test_helper'

class TestCollector < Test::Unit::TestCase
  include RubyRdocCollectorTestSupport

  def setup
    @dir        = Dir.mktmpdir('collector')
    @baseline   = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'baseline.yml'))
    @output_dir = File.join(@dir, 'out')
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

  def test_since_and_before_are_ignored
    entities = [build_entity('A')]
    c = build_collector(entities)
    r1 = c.collect(since: '2020-01-01', before: '2020-01-02').to_a
    fresh_baseline = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'baseline2.yml'))
    c2 = build_collector(entities, baseline: fresh_baseline, output_dir: File.join(@dir, 'out2'))
    r2 = c2.collect.to_a
    assert_equal r1.map { |r| r[:source] }, r2.map { |r| r[:source] }
    assert_equal r1.map { |r| r[:content] }, r2.map { |r| r[:content] }
  end

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
    c = build_collector([entity])
    results = with_env('RUBY_RDOC_MAX_METHODS' => '3') { c.collect.to_a }
    assert_equal 1, results.size
    # content should include only first 3 methods
    content = results.first[:content]
    assert_include content, '### m1'
    assert_include content, '### m3'
    assert_not_include content, '### m4'
  end

  def test_english_description_appears_verbatim_in_content
    methods = [
      RubyRdocCollector::MethodEntry.new(name: 'greet', call_seq: nil, description: 'Says hello.')
    ]
    entity = RubyRdocCollector::ClassEntity.new(
      name: 'Greeter', description: 'A greeter class.', methods: methods, constants: [], superclass: 'Object'
    )
    c = build_collector([entity])
    results = c.collect.to_a
    content = results.first[:content]
    assert_include content, 'A greeter class.'
    assert_include content, 'Says hello.'
    assert_not_include content, '<details>'
  end
end
