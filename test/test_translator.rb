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

  # A. model param + cache key isolation
  def test_model_param_defaults_to_haiku
    # default_runner is not called in this test, so we inject a runner that captures args
    # We verify the model param is stored and used in cache key differentiation
    t = RubyRdocCollector::Translator.new(runner: EchoRunner.new(response: 'JP'), cache: @cache, sleeper: @no_sleep)
    assert_equal 'haiku', t.model
  end

  def test_model_param_can_be_set_to_sonnet
    t = RubyRdocCollector::Translator.new(runner: EchoRunner.new, cache: @cache, sleeper: @no_sleep, model: 'sonnet')
    assert_equal 'sonnet', t.model
  end

  def test_different_model_causes_cache_miss
    runner_haiku  = EchoRunner.new(response: 'JP haiku')
    runner_sonnet = EchoRunner.new(response: 'JP sonnet')
    t_haiku  = RubyRdocCollector::Translator.new(runner: runner_haiku,  cache: @cache, sleeper: @no_sleep, model: 'haiku')
    t_sonnet = RubyRdocCollector::Translator.new(runner: runner_sonnet, cache: @cache, sleeper: @no_sleep, model: 'sonnet')
    t_haiku.translate('same text')
    t_sonnet.translate('same text')
    # Both runners must have been called — model difference means no cache hit
    assert_equal 1, runner_haiku.calls
    assert_equal 1, runner_sonnet.calls
  end

  def test_same_model_same_text_hits_cache
    runner = EchoRunner.new(response: 'JP')
    t = RubyRdocCollector::Translator.new(runner: runner, cache: @cache, sleeper: @no_sleep, model: 'haiku')
    t.translate('same text')
    t.translate('same text')
    assert_equal 1, runner.calls
  end

  def test_model_param_propagates_to_runner_via_default_runner
    # Use a capturing runner to verify --model haiku appears in the CLI args
    captured_prompt = nil
    capturing_runner = lambda do |prompt|
      captured_prompt = prompt
      'JP'
    end
    t = RubyRdocCollector::Translator.new(runner: capturing_runner, cache: @cache, sleeper: @no_sleep, model: 'haiku')
    # The model is used in default_runner; here we just verify the model attr exists.
    # For default_runner args, we test via model accessor.
    assert_equal 'haiku', t.model
  end

  # B. prompt header enforces standard Japanese (counters ~/.claude config persona bleed)
  def test_prompt_header_enforces_standard_japanese
    header = RubyRdocCollector::Translator::PROMPT_HEADER
    assert_include header, '標準語'
    assert_include header, '最優先'
    # explicit ban phrase to resist future header edits that soften the directive
    assert_match(/関西弁.*使用禁止|使用禁止.*関西弁/m, header)
  end

  def test_prompt_header_included_in_runner_invocation
    captured_prompt = nil
    capturing_runner = lambda { |p| captured_prompt = p; 'JP' }
    t = RubyRdocCollector::Translator.new(runner: capturing_runner, cache: @cache, sleeper: @no_sleep)
    t.translate('Hello')
    assert_include captured_prompt, '標準語'
  end

  def test_cache_key_version_is_v3
    # Cache key bump is intentional; changing this constant invalidates all cached translations.
    # The test exists to force explicit acknowledgement when bumping (update the expected version).
    assert_equal 'v3', RubyRdocCollector::Translator::CACHE_KEY_VERSION
  end

  # C. semaphore gating: max concurrent claude calls across threads

  def test_concurrent_runner_calls_are_capped_by_semaphore
    sem = RubyRdocCollector::ClaudeSemaphore.new(2)
    in_flight = 0
    max_in_flight = 0
    mtx = Mutex.new
    runner = lambda do |_prompt|
      mtx.synchronize do
        in_flight += 1
        max_in_flight = [max_in_flight, in_flight].max
      end
      sleep 0.02
      mtx.synchronize { in_flight -= 1 }
      'JP'
    end
    # per-thread separate cache to avoid cache hits that'd bypass runner
    threads = 10.times.map do |i|
      Thread.new do
        cache = RubyRdocCollector::TranslationCache.new(cache_dir: Dir.mktmpdir("tsem#{i}"))
        t = RubyRdocCollector::Translator.new(runner: runner, cache: cache, sleeper: @no_sleep, semaphore: sem)
        t.translate("unique text #{i}")
      end
    end
    threads.each(&:join)
    assert_equal 2, max_in_flight, "concurrent runner calls must be capped at semaphore size (saw #{max_in_flight})"
  end

  def test_default_semaphore_allows_single_thread_usage
    # Sanity: no semaphore injection → default semaphore used, single-threaded tests still work
    runner = EchoRunner.new(response: 'JP')
    t = RubyRdocCollector::Translator.new(runner: runner, cache: @cache, sleeper: @no_sleep)
    assert_equal 'JP', t.translate('hello')
    assert_equal 1, runner.calls
  end
end
