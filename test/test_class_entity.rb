require_relative 'test_helper'

class TestClassEntity < Test::Unit::TestCase
  def test_class_entity_fields
    m = RubyRdocCollector::MethodEntry.new(name: 'length', call_seq: 'length -> int', description: 'Returns the length.')
    e = RubyRdocCollector::ClassEntity.new(
      name:        'String',
      description: 'A string is a sequence of bytes.',
      methods:     [m],
      constants:   [],
      superclass:  'Object'
    )
    assert_equal 'String', e.name
    assert_equal 1, e.methods.size
    assert_equal 'length', e.methods.first.name
    assert_equal 'Object', e.superclass
  end

  def test_method_entry_accepts_nil_call_seq
    m = RubyRdocCollector::MethodEntry.new(name: 'hash', call_seq: nil, description: '')
    assert_nil m.call_seq
  end
end
