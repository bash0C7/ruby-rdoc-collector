require_relative 'test_helper'

class TestTranslator < Test::Unit::TestCase
  def setup
    @dir   = Dir.mktmpdir('tcache')
    @cache = RubyRdocCollector::TranslationCache.new(cache_dir: @dir)
    @no_sleep = ->(_sec) {}
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_returns_runner_output_and_caches_it
    runner = EchoRunner.new(response: 'JP output')
    t = RubyRdocCollector::Translator.new(runner: runner, cache: @cache, sleeper: @no_sleep)
    result = t.translate('English input')
    assert_equal 'JP output', result
    assert_equal 1, runner.calls
  end

  def test_second_call_with_same_input_hits_cache
    runner = EchoRunner.new(response: 'JP output')
    t = RubyRdocCollector::Translator.new(runner: runner, cache: @cache, sleeper: @no_sleep)
    t.translate('Same input')
    t.translate('Same input')
    assert_equal 1, runner.calls
  end

  def test_different_input_misses_cache
    runner = EchoRunner.new(response: 'JP')
    t = RubyRdocCollector::Translator.new(runner: runner, cache: @cache, sleeper: @no_sleep)
    t.translate('input A')
    t.translate('input B')
    assert_equal 2, runner.calls
  end

  def test_retries_on_transient_failure
    runner = FailingRunner.new(fail_count: 2, eventual: 'JP ok')
    t = RubyRdocCollector::Translator.new(runner: runner, cache: @cache, max_retries: 3, sleeper: @no_sleep)
    assert_equal 'JP ok', t.translate('x')
    assert_equal 3, runner.calls
  end

  def test_raises_after_max_retries
    runner = FailingRunner.new(fail_count: 99)
    t = RubyRdocCollector::Translator.new(runner: runner, cache: @cache, max_retries: 2, sleeper: @no_sleep)
    assert_raise(RubyRdocCollector::Translator::TranslationError) do
      t.translate('x')
    end
  end

  def test_empty_input_returns_empty_without_runner_call
    runner = EchoRunner.new
    t = RubyRdocCollector::Translator.new(runner: runner, cache: @cache, sleeper: @no_sleep)
    assert_equal '', t.translate('')
    assert_equal 0, runner.calls
  end
end
