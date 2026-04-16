require 'fileutils'
require 'tempfile'

module RubyRdocCollector
  class TranslationCache
    DEFAULT_DIR = File.expand_path('~/.cache/ruby-rdoc-collector/translations')

    def initialize(cache_dir: DEFAULT_DIR)
      @cache_dir = cache_dir
      FileUtils.mkdir_p(@cache_dir)
    end

    def read(key)
      path = path_for(key)
      File.exist?(path) ? File.read(path) : nil
    end

    def write(key, value)
      path = path_for(key)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = Tempfile.new(['rdoc_cache_', '.tmp'], File.dirname(path))
      begin
        tmp.write(value)
        tmp.close
        File.rename(tmp.path, path)
      ensure
        tmp.close unless tmp.closed?
        File.unlink(tmp.path) if File.exist?(tmp.path)
      end
    end

    private

    def path_for(key)
      File.join(@cache_dir, key[0, 2], key)
    end
  end
end
