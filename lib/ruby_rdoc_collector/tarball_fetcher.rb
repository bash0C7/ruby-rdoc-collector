require 'digest'
require 'fileutils'
require 'open3'

module RubyRdocCollector
  class TarballFetcher
    class FetchError < StandardError; end

    DEFAULT_URL       = 'https://cache.ruby-lang.org/pub/ruby/doc/ruby-docs-en-master.tar.xz'
    DEFAULT_CACHE_DIR = File.expand_path('~/.cache/ruby-rdoc-collector/tarball')

    attr_reader :tarball_sha

    def initialize(url: DEFAULT_URL, cache_dir: DEFAULT_CACHE_DIR, downloader: nil)
      @url        = url
      @cache_dir  = cache_dir
      @downloader = downloader || method(:default_download)
      @unchanged  = false
      @tarball_sha = nil
    end

    def fetch
      FileUtils.mkdir_p(@cache_dir)
      tarball_path  = File.join(@cache_dir, File.basename(@url))
      extracted_dir = File.join(@cache_dir, 'extracted')
      sha_file      = File.join(@cache_dir, 'tarball.sha256')

      begin
        @downloader.call(@url, tarball_path)
      rescue => e
        raise FetchError, "download failed: #{e.message}"
      end

      @tarball_sha = Digest::SHA256.file(tarball_path).hexdigest
      cached_sha   = File.exist?(sha_file) ? File.read(sha_file).strip : nil
      @unchanged   = (cached_sha == @tarball_sha && Dir.exist?(extracted_dir))

      unless @unchanged
        extract(tarball_path, extracted_dir)
        File.write(sha_file, @tarball_sha)
      end

      resolve_content_dir(extracted_dir)
    end

    def unchanged?
      @unchanged
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
      etag_file = "#{dest}.etag"
      args = ['curl', '-sSL', '-o', dest]
      args += ['--etag-save', etag_file]
      args += ['--etag-compare', etag_file] if File.exist?(etag_file) && File.exist?(dest)
      out, status = Open3.capture2e(*args, url)
      raise FetchError, "curl failed: #{out}" unless status.success?
    end
  end
end
