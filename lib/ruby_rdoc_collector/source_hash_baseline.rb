require 'digest'
require 'fileutils'
require 'set'
require 'tempfile'
require 'time'
require 'yaml'

module RubyRdocCollector
  class SourceHashBaseline
    DEFAULT_PATH = File.expand_path('~/.cache/ruby-rdoc-collector/source_hashes.yml')

    def initialize(path: DEFAULT_PATH)
      @path  = path
      state = load_from_disk
      @map   = state[:entries]
      @last_started_at   = state[:last_started_at]
      @last_completed_at = state[:last_completed_at]
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

    # True iff the most recent mark_started was followed by a mark_completed
    # (i.e., the last run finished cleanly). A partial / interrupted run
    # leaves last_started_at > last_completed_at → returns false.
    def completed?
      @mutex.synchronize do
        next false if @last_completed_at.nil? || @last_started_at.nil?
        @last_completed_at >= @last_started_at
      end
    end

    def mark_seen(class_name)
      @mutex.synchronize { @seen << class_name }
      self
    end

    def mark_started
      snapshot = @mutex.synchronize do
        @last_started_at = Time.now.iso8601(6)
        build_state
      end
      atomic_write(snapshot)
      self
    end

    def mark_completed
      snapshot = @mutex.synchronize do
        @last_completed_at = Time.now.iso8601(6)
        build_state
      end
      atomic_write(snapshot)
      self
    end

    def persist_one(class_name, new_hash)
      snapshot = @mutex.synchronize do
        @map[class_name] = new_hash
        build_state
      end
      atomic_write(snapshot)
      self
    end

    def cleanup_orphans
      snapshot = @mutex.synchronize do
        (@map.keys - @seen.to_a).each { |k| @map.delete(k) }
        build_state
      end
      atomic_write(snapshot)
      self
    end

    private

    # Must be called under @mutex.
    def build_state
      {
        'entries'           => @map.dup,
        'last_started_at'   => @last_started_at,
        'last_completed_at' => @last_completed_at
      }
    end

    def load_from_disk
      return default_state unless File.exist?(@path)
      raw = YAML.load_file(@path) || {}
      if raw.is_a?(Hash) && raw.key?('entries')
        {
          entries:           raw['entries'] || {},
          last_started_at:   raw['last_started_at'],
          last_completed_at: raw['last_completed_at']
        }
      else
        # Legacy flat Hash format: treat as entries with no bookmark.
        { entries: raw, last_started_at: nil, last_completed_at: nil }
      end
    end

    def default_state
      { entries: {}, last_started_at: nil, last_completed_at: nil }
    end

    def atomic_write(state)
      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir)
      tmp = Tempfile.new(['source_hashes_', '.tmp'], dir)
      begin
        tmp.write(state.to_yaml)
        tmp.close
        File.rename(tmp.path, @path)
      ensure
        tmp.close unless tmp.closed?
        File.unlink(tmp.path) if File.exist?(tmp.path)
      end
    end
  end
end
