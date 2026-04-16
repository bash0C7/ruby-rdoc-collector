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
end
