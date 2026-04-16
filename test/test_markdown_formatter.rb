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

  # B. English original in collapsible details
  def test_en_description_emits_details_block_after_jp
    md = @formatter.format(@entity,
      jp_description: 'Ruby::Box は単一の値をラップする。',
      jp_method_descriptions: {},
      en_description: 'A Ruby::Box wraps a single value.')
    # JP appears before details block
    jp_pos = md.index('Ruby::Box は単一の値をラップする。')
    details_pos = md.index('<details>')
    assert_not_nil jp_pos, 'JP description must be present'
    assert_not_nil details_pos, '<details> block must be present'
    assert jp_pos < details_pos, 'JP must appear before <details>'
    assert_include md, '<details>'
    assert_include md, '<summary>Original (en)</summary>'
    assert_include md, 'A Ruby::Box wraps a single value.'
    assert_include md, '</details>'
  end

  def test_en_description_absent_means_no_details_block
    md = @formatter.format(@entity,
      jp_description: 'Ruby::Box は単一の値をラップする。',
      jp_method_descriptions: {})
    assert_not_include md, '<details>'
  end

  def test_en_method_descriptions_emits_details_block_per_method
    md = @formatter.format(@entity,
      jp_description: 'JP desc',
      jp_method_descriptions: { 'value' => '包んだ値を返す。', 'replace' => '値を置き換える。' },
      en_method_descriptions: { 'value' => 'Returns the wrapped value.', 'replace' => 'Replaces the wrapped value.' })
    # Both methods have details blocks
    assert_equal 2, md.scan('<details>').size
    assert_include md, 'Returns the wrapped value.'
    assert_include md, 'Replaces the wrapped value.'
  end

  def test_en_method_descriptions_jp_before_details_per_method
    md = @formatter.format(@entity,
      jp_description: 'JP desc',
      jp_method_descriptions: { 'value' => '包んだ値を返す。' },
      en_method_descriptions: { 'value' => 'Returns the wrapped value.' })
    jp_pos = md.index('包んだ値を返す。')
    details_pos = md.index('<details>')
    assert jp_pos < details_pos, 'JP method desc must appear before <details>'
  end

  def test_backward_compat_no_en_params_still_passes
    # Existing signature without en_ params must still work
    md = @formatter.format(@entity,
      jp_description: 'JP desc',
      jp_method_descriptions: { 'value' => '包んだ値を返す。' })
    assert_include md, 'JP desc'
    assert_not_include md, '<details>'
  end
end
