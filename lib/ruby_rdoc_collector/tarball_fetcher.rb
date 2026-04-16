require 'fileutils'
require 'open3'

module RubyRdocCollector
  class TarballFetcher
    class FetchError < StandardError; end

    DEFAULT_URL = 'https://cache.ruby-lang.org/pub/ruby/doc/ruby-docs-en-master.tar.xz'
    DEFAULT_CACHE_DIR = File.expand_path('~/.cache/ruby-rdoc-collector/tarball')

    def initialize(url: DEFAULT_URL, cache_dir: DEFAULT_CACHE_DIR, downloader: nil)
      @url        = url
      @cache_dir  = cache_dir
      @downloader = downloader || method(:default_download)
    end

    def fetch
      FileUtils.mkdir_p(@cache_dir)
      tarball_path  = File.join(@cache_dir, File.basename(@url))
      extracted_dir = File.join(@cache_dir, 'extracted')

      begin
        @downloader.call(@url, tarball_path)
      rescue => e
        raise FetchError, "download failed: #{e.message}"
      end

      extract(tarball_path, extracted_dir)
      resolve_content_dir(extracted_dir)
    end

    private

    def extract(tarball_path, dest)
      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(dest)
      out, status = Open3.capture2e('tar', 'xf', tarball_path, '-C', dest)
      raise FetchError, "tar extraction failed: #{out}" unless status.success?
    end

    def resolve_content_dir(extracted_dir)
      entries = Dir.children(extracted_dir)
      if entries.size == 1 && File.directory?(File.join(extracted_dir, entries.first))
        File.join(extracted_dir, entries.first)
      else
        extracted_dir
      end
    end

    def default_download(url, dest)
      out, status = Open3.capture2e('curl', '-sSL', '-o', dest, url)
      raise FetchError, "curl failed: #{out}" unless status.success?
    end
  end
end
