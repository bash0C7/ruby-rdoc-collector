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
    md = @formatter.format(@entity)
    assert_match(/\A# Ruby::Box/, md)
    assert_include md, '(< Module)'
  end

  def test_includes_english_description_in_overview
    md = @formatter.format(@entity)
    assert_include md, 'A Ruby::Box wraps a single value.'
  end

  def test_method_section_keeps_call_seq_and_description
    md = @formatter.format(@entity)
    assert_include md, 'box.value -> object'
    assert_include md, 'Returns the wrapped value.'
    assert_include md, 'box.replace(obj) -> obj'
    assert_include md, 'Replaces the wrapped value.'
  end

  def test_empty_methods_omits_methods_section
    entity = RubyRdocCollector::ClassEntity.new(
      name: 'Empty', description: '', methods: [], constants: [], superclass: 'Object'
    )
    md = @formatter.format(entity)
    assert_not_match(/^## Methods/, md)
  end

  def test_no_details_block_emitted_anywhere
    md = @formatter.format(@entity)
    assert_not_include md, '<details>'
    assert_not_include md, '<summary>'
  end

  def test_missing_method_description_falls_back_to_empty_string
    entity = RubyRdocCollector::ClassEntity.new(
      name: 'NoDesc', description: 'c', methods: [
        RubyRdocCollector::MethodEntry.new(name: 'm', call_seq: nil, description: nil)
      ], constants: [], superclass: 'Object'
    )
    md = @formatter.format(entity)
    assert_include md, '### m'
  end
end
