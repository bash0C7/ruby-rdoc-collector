require_relative 'test_helper'

class TestHtmlParser < Test::Unit::TestCase
  def setup
    @parser = RubyRdocCollector::HtmlParser.new
  end

  def test_parses_classes_from_fixtures
    entities = @parser.parse(FIXTURE_DIR)
    names = entities.map(&:name)
    assert_include names, 'TestClass'
    assert_include names, 'Ruby::Box'
  end

  def test_extracts_class_description_from_html
    entities = @parser.parse(FIXTURE_DIR)
    tc = entities.find { |e| e.name == 'TestClass' }
    assert_match(/test class for unit testing/, tc.description)
  end

  def test_extracts_superclass
    entities = @parser.parse(FIXTURE_DIR)
    tc = entities.find { |e| e.name == 'TestClass' }
    assert_equal 'Object', tc.superclass

    box = entities.find { |e| e.name == 'Ruby::Box' }
    assert_equal 'Module', box.superclass
  end

  def test_extracts_methods_with_call_seq
    entities = @parser.parse(FIXTURE_DIR)
    tc = entities.find { |e| e.name == 'TestClass' }
    method_names = tc.methods.map(&:name)
    assert_include method_names, 'new'
    assert_include method_names, 'value'

    new_method = tc.methods.find { |m| m.name == 'new' }
    assert_match(/TestClass\.new/, new_method.call_seq)
  end

  def test_extracts_method_description_from_html
    entities = @parser.parse(FIXTURE_DIR)
    tc = entities.find { |e| e.name == 'TestClass' }
    new_method = tc.methods.find { |m| m.name == 'new' }
    assert_match(/Creates a new TestClass instance/, new_method.description)
  end

  def test_handles_nested_namespace_path
    entities = @parser.parse(FIXTURE_DIR)
    box = entities.find { |e| e.name == 'Ruby::Box' }
    assert_not_nil box
    assert_equal 1, box.methods.size
    assert_equal 'current', box.methods.first.name
    assert_match(/Ruby::Box\.current/, box.methods.first.call_seq)
  end

  def test_skips_entries_without_html_file
    entities = @parser.parse(FIXTURE_DIR)
    entities.each do |e|
      assert_not_nil e.name
      assert_not_nil e.description
    end
  end

  def test_handles_css_special_char_tilde_in_fragment
    # Real rdoc search_data.js has fragments like "method-i-tilde~" where ~ is a
    # CSS general sibling combinator — using css("#method-i-tilde~") crashes Oga.
    # XPath attribute match must be used instead.
    entities = @parser.parse(FIXTURE_DIR)
    tc = entities.find { |e| e.name == 'TestClass' }
    tilde_method = tc.methods.find { |m| m.name == 'tilde~' }
    assert_not_nil tilde_method, "tilde~ method should be extracted despite CSS-special char in fragment"
    assert_match(/tilde~/, tilde_method.call_seq)
    assert_match(/tilde in its name/, tilde_method.description)
  end
end
