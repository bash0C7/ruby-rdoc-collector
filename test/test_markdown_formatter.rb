require_relative 'test_helper'

class TestMarkdownFormatter < Test::Unit::TestCase
  def setup
    @entity = RubyRdocCollector::ClassEntity.new(
      name:        'Ruby::Box',
      description: 'A Ruby::Box wraps a single value.',
      methods: [
        RubyRdocCollector::MethodEntry.new(
          name:        'value',
          call_seq:    'box.value -> object',
          description: 'Returns the wrapped value.'
        ),
        RubyRdocCollector::MethodEntry.new(
          name:        'replace',
          call_seq:    'box.replace(obj) -> obj',
          description: 'Replaces the wrapped value.'
        )
      ],
      constants:  [],
      superclass: 'Module'
    )
    @formatter = RubyRdocCollector::MarkdownFormatter.new
  end

  def test_emits_class_header_with_superclass
    md = @formatter.format(@entity, jp_description: 'Ruby::Box は単一の値をラップする。', jp_method_descriptions: {})
    assert_match(/\A# Ruby::Box/, md)
    assert_include md, '(< Module)'
  end

  def test_includes_jp_description_in_overview
    md = @formatter.format(@entity, jp_description: 'Ruby::Box は単一の値をラップする。', jp_method_descriptions: {})
    assert_include md, 'Ruby::Box は単一の値をラップする。'
    assert_not_include md, 'A Ruby::Box wraps a single value.'
  end

  def test_method_section_keeps_original_call_seq
    md = @formatter.format(@entity, jp_description: 'JP', jp_method_descriptions: {})
    assert_include md, 'box.value -> object'
    assert_include md, 'box.replace(obj) -> obj'
  end

  def test_jp_method_descriptions_override_when_provided
    md = @formatter.format(@entity,
      jp_description: 'JP',
      jp_method_descriptions: { 'value' => '包んだ値を返す。' })
    assert_include md, '包んだ値を返す。'
  end

  def test_empty_methods_omits_methods_section
    entity = RubyRdocCollector::ClassEntity.new(
      name: 'Empty', description: '', methods: [], constants: [], superclass: 'Object'
    )
    md = @formatter.format(entity, jp_description: '空。', jp_method_descriptions: {})
    assert_not_match(/^## Methods/, md)
  end
end
