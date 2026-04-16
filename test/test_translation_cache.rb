require_relative 'test_helper'

class TestTranslationCache < Test::Unit::TestCase
  def setup
    @dir   = Dir.mktmpdir('cache')
    @cache = RubyRdocCollector::TranslationCache.new(cache_dir: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_miss_returns_nil
    assert_nil @cache.read('abc123')
  end

  def test_write_then_read
    @cache.write('abc123', '日本語訳')
    assert_equal '日本語訳', @cache.read('abc123')
  end

  def test_write_leaves_no_tmp_file
    @cache.write('key1', 'final content')
    shard_dir = File.join(@dir, 'ke')
    assert_equal ['key1'], Dir.children(shard_dir)
  end

  def test_shards_by_first_two_chars
    @cache.write('ffaa00', 'v')
    assert Dir.exist?(File.join(@dir, 'ff')), 'should shard by first 2 chars'
  end
end
