require_relative 'test_helper'

class TestTarballFetcher < Test::Unit::TestCase
  def test_raises_on_download_failure
    failing_downloader = ->(_url, _dest) { raise RubyRdocCollector::TarballFetcher::FetchError, 'network down' }
    Dir.mktmpdir do |dir|
      fetcher = RubyRdocCollector::TarballFetcher.new(
        url: 'https://example.com/fake.tar.xz',
        cache_dir: dir,
        downloader: failing_downloader
      )
      assert_raise(RubyRdocCollector::TarballFetcher::FetchError) { fetcher.fetch }
    end
  end

  def test_extracts_tarball_and_returns_content_dir
    Dir.mktmpdir do |dir|
      content_dir = File.join(dir, 'build', 'master')
      FileUtils.mkdir_p(content_dir)
      File.write(File.join(content_dir, 'index.html'), '<h1>test</h1>')
      tarball_src = File.join(dir, 'test.tar.xz')
      system('tar', 'cJf', tarball_src, '-C', File.join(dir, 'build'), 'master')

      cache_dir = File.join(dir, 'cache')
      stub_downloader = lambda do |_url, dest|
        FileUtils.cp(tarball_src, dest)
      end

      fetcher = RubyRdocCollector::TarballFetcher.new(
        url: 'https://example.com/fake.tar.xz',
        cache_dir: cache_dir,
        downloader: stub_downloader
      )
      result = fetcher.fetch
      assert File.exist?(File.join(result, 'index.html')), "extracted content should contain index.html"
    end
  end

  def test_returns_top_level_subdir_when_single_entry
    Dir.mktmpdir do |dir|
      content_dir = File.join(dir, 'build', 'master')
      FileUtils.mkdir_p(content_dir)
      File.write(File.join(content_dir, 'test.html'), 'ok')
      tarball_src = File.join(dir, 'test.tar.xz')
      system('tar', 'cJf', tarball_src, '-C', File.join(dir, 'build'), 'master')

      cache_dir = File.join(dir, 'cache')
      fetcher = RubyRdocCollector::TarballFetcher.new(
        url: 'https://example.com/fake.tar.xz',
        cache_dir: cache_dir,
        downloader: ->(_url, dest) { FileUtils.cp(tarball_src, dest) }
      )
      result = fetcher.fetch
      assert result.end_with?('/master'), "should resolve to the 'master' subdirectory, got: #{result}"
    end
  end

  # freshness / caching behavior

  def build_tarball(dir, variant: 'v1')
    content_dir = File.join(dir, 'build', 'master')
    FileUtils.mkdir_p(content_dir)
    File.write(File.join(content_dir, 'index.html'), "<h1>#{variant}</h1>")
    tarball_src = File.join(dir, "#{variant}.tar.xz")
    system('tar', 'cJf', tarball_src, '-C', File.join(dir, 'build'), 'master')
    FileUtils.rm_rf(File.join(dir, 'build'))
    tarball_src
  end

  def test_unchanged_is_false_on_first_fetch
    Dir.mktmpdir do |dir|
      tarball_src = build_tarball(dir)
      cache_dir   = File.join(dir, 'cache')
      fetcher = RubyRdocCollector::TarballFetcher.new(
        url: 'https://example.com/fake.tar.xz', cache_dir: cache_dir,
        downloader: ->(_u, dest) { FileUtils.cp(tarball_src, dest) }
      )
      fetcher.fetch
      assert_false fetcher.unchanged?, 'first fetch cannot be unchanged'
    end
  end

  def test_unchanged_is_true_on_second_fetch_with_identical_content
    Dir.mktmpdir do |dir|
      tarball_src = build_tarball(dir)
      cache_dir   = File.join(dir, 'cache')
      download_count = 0
      downloader = lambda do |_u, dest|
        download_count += 1
        FileUtils.cp(tarball_src, dest)
      end
      fetcher1 = RubyRdocCollector::TarballFetcher.new(
        url: 'https://example.com/fake.tar.xz', cache_dir: cache_dir, downloader: downloader
      )
      fetcher1.fetch
      fetcher2 = RubyRdocCollector::TarballFetcher.new(
        url: 'https://example.com/fake.tar.xz', cache_dir: cache_dir, downloader: downloader
      )
      fetcher2.fetch
      assert fetcher2.unchanged?, 'second fetch with identical tarball must report unchanged'
      assert_equal 2, download_count, 'downloader still called (HEAD semantics are downloader-level)'
    end
  end

  def test_unchanged_is_false_when_tarball_content_differs
    Dir.mktmpdir do |dir|
      src_v1 = build_tarball(dir, variant: 'v1')
      src_v2 = build_tarball(dir, variant: 'v2')
      cache_dir = File.join(dir, 'cache')
      current_src = src_v1
      downloader  = ->(_u, dest) { FileUtils.cp(current_src, dest) }

      RubyRdocCollector::TarballFetcher.new(
        url: 'https://x.y/z.tar.xz', cache_dir: cache_dir, downloader: downloader
      ).fetch
      current_src = src_v2
      f2 = RubyRdocCollector::TarballFetcher.new(
        url: 'https://x.y/z.tar.xz', cache_dir: cache_dir, downloader: downloader
      )
      f2.fetch
      assert_false f2.unchanged?, 'differing tarball content must report changed'
    end
  end

  def test_tarball_sha_is_exposed_after_fetch
    Dir.mktmpdir do |dir|
      tarball_src = build_tarball(dir)
      cache_dir   = File.join(dir, 'cache')
      fetcher = RubyRdocCollector::TarballFetcher.new(
        url: 'https://x.y/z.tar.xz', cache_dir: cache_dir,
        downloader: ->(_u, dest) { FileUtils.cp(tarball_src, dest) }
      )
      fetcher.fetch
      assert_match(/\A[0-9a-f]{64}\z/, fetcher.tarball_sha)
    end
  end

  def test_skips_re_extract_when_unchanged
    Dir.mktmpdir do |dir|
      tarball_src = build_tarball(dir)
      cache_dir   = File.join(dir, 'cache')
      fetcher1 = RubyRdocCollector::TarballFetcher.new(
        url: 'https://x.y/z.tar.xz', cache_dir: cache_dir,
        downloader: ->(_u, dest) { FileUtils.cp(tarball_src, dest) }
      )
      fetcher1.fetch
      extracted_marker = File.join(cache_dir, 'extracted', 'master', 'marker.txt')
      File.write(extracted_marker, 'sentinel')

      fetcher2 = RubyRdocCollector::TarballFetcher.new(
        url: 'https://x.y/z.tar.xz', cache_dir: cache_dir,
        downloader: ->(_u, dest) { FileUtils.cp(tarball_src, dest) }
      )
      fetcher2.fetch
      # sentinel MUST survive the second fetch — extract would rm_rf the tree
      assert File.exist?(extracted_marker), 'extract must be skipped when tarball unchanged'
    end
  end

  def test_re_extracts_when_content_changes
    Dir.mktmpdir do |dir|
      src_v1 = build_tarball(dir, variant: 'v1')
      src_v2 = build_tarball(dir, variant: 'v2')
      cache_dir = File.join(dir, 'cache')
      current_src = src_v1

      fetcher1 = RubyRdocCollector::TarballFetcher.new(
        url: 'https://x.y/z.tar.xz', cache_dir: cache_dir,
        downloader: ->(_u, dest) { FileUtils.cp(current_src, dest) }
      )
      fetcher1.fetch
      extracted_marker = File.join(cache_dir, 'extracted', 'master', 'sentinel.txt')
      File.write(extracted_marker, 'should be wiped')

      current_src = src_v2
      fetcher2 = RubyRdocCollector::TarballFetcher.new(
        url: 'https://x.y/z.tar.xz', cache_dir: cache_dir,
        downloader: ->(_u, dest) { FileUtils.cp(current_src, dest) }
      )
      fetcher2.fetch
      assert_false File.exist?(extracted_marker), 'extract must re-run when content changes'
      assert_match(/v2/, File.read(File.join(cache_dir, 'extracted', 'master', 'index.html')))
    end
  end
end
