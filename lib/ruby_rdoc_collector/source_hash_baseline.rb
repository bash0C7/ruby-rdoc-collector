require 'digest'
require 'fileutils'
require 'set'
require 'tempfile'
require 'yaml'

module RubyRdocCollector
  class SourceHashBaseline
    DEFAULT_PATH = File.expand_path('~/.cache/ruby-rdoc-collector/source_hashes.yml')

    def initialize(path: DEFAULT_PATH)
      @path  = path
      @map   = load_from_disk
      @seen  = Set.new
      @mutex = Mutex.new
    end

    def hash_for(entity)
      parts = [entity.description.to_s, entity.superclass.to_s]
      entity.methods.each do |m|
        parts << m.name.to_s
        parts << m.call_seq.to_s
        parts << m.description.to_s
      end
      Digest::SHA256.hexdigest(parts.join("\x00"))
    end

    def changed?(class_name, new_hash)
      @mutex.synchronize { @map[class_name] != new_hash }
    end

    def populated?
      @mutex.synchronize { !@map.empty? }
    end

    def mark_seen(class_name)
      @mutex.synchronize { @seen << class_name }
      self
    end

    def persist_one(class_name, new_hash)
      snapshot = @mutex.synchronize do
        @map[class_name] = new_hash
        @map.dup
      end
      atomic_write(snapshot)
      self
    end

    def cleanup_orphans
      snapshot = @mutex.synchronize do
        (@map.keys - @seen.to_a).each { |k| @map.delete(k) }
        @map.dup
      end
      atomic_write(snapshot)
      self
    end

    private

    def load_from_disk
      return {} unless File.exist?(@path)
      YAML.load_file(@path) || {}
    end

    def atomic_write(map)
      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir)
      tmp = Tempfile.new(['source_hashes_', '.tmp'], dir)
      begin
        tmp.write(map.to_yaml)
        tmp.close
        File.rename(tmp.path, @path)
      ensure
        tmp.close unless tmp.closed?
        File.unlink(tmp.path) if File.exist?(tmp.path)
      end
    end
  end
end
