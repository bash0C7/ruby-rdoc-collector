require_relative 'test_helper'

class TestCollectorStreaming < Test::Unit::TestCase
  include RubyRdocCollectorTestSupport

  def setup
    @dir         = Dir.mktmpdir('collector_stream')
    @baseline    = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'baseline.yml'))
    @output_dir  = File.join(@dir, 'out')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def build_entity(name, description: "desc of #{name}", methods: [])
    RubyRdocCollector::ClassEntity.new(
      name: name, description: description, methods: methods, constants: [], superclass: 'Object'
    )
  end

  # block API: streaming

  def test_collect_with_block_yields_each_record
    entities = [build_entity('A'), build_entity('B')]
    c = build_collector(entities)
    yielded = []
    c.collect { |r| yielded << r }
    assert_equal 2, yielded.size
    sources = yielded.map { |r| r[:source] }
    assert_include sources, 'ruby/ruby:rdoc/trunk/A'
    assert_include sources, 'ruby/ruby:rdoc/trunk/B'
  end

  # no-block API: lazy Enumerator

  def test_collect_without_block_returns_enumerator
    entities = [build_entity('A')]
    c = build_collector(entities)
    result = c.collect
    assert_kind_of Enumerator, result
  end

  def test_collect_enumerator_iterates_same_records
    entities = [build_entity('A'), build_entity('B')]
    c = build_collector(entities)
    records = c.collect.to_a
    assert_equal 2, records.size
  end

  # source_hash differential skip

  def test_unchanged_entity_is_not_yielded
    entity = build_entity('A')
    # pre-seed baseline with current hash — unchanged state
    @baseline.persist_one('A', @baseline.hash_for(entity))
    c = build_collector([entity])
    yielded = []
    c.collect { |r| yielded << r }
    assert_empty yielded
  end

  def test_changed_entity_is_yielded
    entity = build_entity('A', description: 'old desc')
    @baseline.persist_one('A', @baseline.hash_for(entity))
    changed = build_entity('A', description: 'new desc')
    c = build_collector([changed])
    yielded = []
    c.collect { |r| yielded << r }
    assert_equal 1, yielded.size
  end

  def test_new_entity_not_in_baseline_is_yielded
    c = build_collector([build_entity('Brand_New')])
    yielded = []
    c.collect { |r| yielded << r }
    assert_equal 1, yielded.size
  end

  # intermediate file save

  def test_intermediate_md_written_for_yielded_entity
    c = build_collector([build_entity('Array')])
    c.collect { |_| }
    path = File.join(@output_dir, 'Array.md')
    assert File.exist?(path), "expected MD at #{path}"
    assert_include File.read(path), 'Array'
  end

  def test_intermediate_filename_sanitizes_colons
    c = build_collector([build_entity('Ruby::Box')])
    c.collect { |_| }
    assert File.exist?(File.join(@output_dir, 'Ruby__Box.md'))
  end

  def test_intermediate_filename_sanitizes_special_chars
    c = build_collector([build_entity('IO#read')])
    c.collect { |_| }
    # '#' is not in [A-Za-z0-9_-], should be replaced with '_'
    assert File.exist?(File.join(@output_dir, 'IO_read.md'))
  end

  # file save failure

  def test_file_save_failure_skips_yield_and_baseline_update
    entity = build_entity('A')
    failing_writer = ->(_dir, _filename, _content) { raise 'disk full' }
    c = build_collector([entity], file_writer: failing_writer)
    yielded = []
    c.collect { |r| yielded << r }
    assert_empty yielded, 'yield must not happen when file save fails'
    # baseline should NOT record this entity
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'baseline.yml'))
    assert b2.changed?('A', @baseline.hash_for(entity)),
      'baseline must not be updated when file save fails'
  end

  # baseline persistence after successful yield

  def test_baseline_persisted_after_successful_yield
    entity = build_entity('A')
    c = build_collector([entity])
    c.collect { |_| }
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'baseline.yml'))
    assert_false b2.changed?('A', @baseline.hash_for(entity))
  end

  # yield exception semantics (DB store failure)

  def test_yield_exception_skips_baseline_update
    entity = build_entity('A')
    c = build_collector([entity])
    c.collect { |_r| raise 'db error' }
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'baseline.yml'))
    assert b2.changed?('A', @baseline.hash_for(entity)),
      'baseline must not be updated when yield raises'
  end

  def test_yield_exception_does_not_kill_batch
    entities = [build_entity('A'), build_entity('B')]
    c = build_collector(entities)
    yielded = []
    c.collect do |r|
      if r[:source].end_with?('/A')
        raise 'db error on A'
      else
        yielded << r
      end
    end
    sources = yielded.map { |r| r[:source] }
    assert_include sources, 'ruby/ruby:rdoc/trunk/B'
  end

  # orphan cleanup at end of run

  def test_cleanup_orphans_removes_entries_not_in_current_parse
    # pre-seed baseline with A and Gone; parse only sees A
    @baseline.persist_one('A',    'hash_a_old')
    @baseline.persist_one('Gone', 'hash_gone')
    entity = build_entity('A')
    c = build_collector([entity])
    c.collect { |_| }
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'baseline.yml'))
    assert b2.changed?('Gone', 'hash_gone'), 'Gone must be purged from baseline'
    assert_false b2.changed?('A', @baseline.hash_for(entity))
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def test_cleanup_orphans_skipped_when_smoke_targets_active
    # smoke filter set → baseline entries for unseen classes MUST be preserved
    @baseline.persist_one('Gone', 'hash_gone')
    entity = build_entity('A')
    c = build_collector([entity])
    with_env('RUBY_RDOC_TARGETS' => 'A') { c.collect { |_| } }
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'baseline.yml'))
    assert_false b2.changed?('Gone', 'hash_gone'),
      'Gone must NOT be purged when smoke TARGETS is active'
  end

  def test_cleanup_orphans_skipped_when_smoke_max_methods_active
    @baseline.persist_one('Gone', 'hash_gone')
    entity = build_entity('A')
    c = build_collector([entity])
    with_env('RUBY_RDOC_MAX_METHODS' => '3') { c.collect { |_| } }
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'baseline.yml'))
    assert_false b2.changed?('Gone', 'hash_gone'),
      'Gone must NOT be purged when MAX_METHODS is active'
  end

  # fast-path: tarball unchanged + baseline populated → skip parse/translate/store entirely

  class UnchangedFetcher
    attr_reader :fetch_count
    def initialize(dir); @dir = dir; @fetch_count = 0; end
    def fetch; @fetch_count += 1; @dir; end
    def unchanged?; true; end
  end

  class ChangedFetcher
    def initialize(dir); @dir = dir; end
    def fetch; @dir; end
    def unchanged?; false; end
  end

  class ExplodingParser
    def parse(_dir, **)
      raise 'parse must not be called on fast path'
    end
  end

  def test_fast_path_skips_parse_when_tarball_unchanged_and_last_run_completed
    @baseline.persist_one('ExistingClass', 'some_hash')
    @baseline.mark_started
    @baseline.mark_completed
    c = RubyRdocCollector::Collector.new({},
      fetcher:    UnchangedFetcher.new('/fake'),
      parser:     ExplodingParser.new,
      formatter:  RubyRdocCollector::MarkdownFormatter.new,
      baseline:   @baseline,
      output_dir: @output_dir)
    yielded = []
    assert_nothing_raised do
      c.collect { |r| yielded << r }
    end
    assert_empty yielded, 'no entities should be yielded on fast path'
  end

  def test_fast_path_does_not_apply_when_baseline_empty
    # tarball unchanged but baseline is empty → still parse+process (first-run recovery)
    empty_baseline = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'empty.yml'))
    entity = build_entity('A')
    c = build_collector([entity], baseline: empty_baseline)
    # replace fetcher with one that reports unchanged
    c.instance_variable_set(:@fetcher, UnchangedFetcher.new('/fake'))
    yielded = []
    c.collect { |r| yielded << r }
    assert_equal 1, yielded.size, 'must parse + yield when baseline empty even if tarball unchanged'
  end

  def test_fast_path_does_not_apply_when_smoke_active
    # smoke filter must bypass fast path so TARGETS/MAX_METHODS always runs
    @baseline.persist_one('ExistingClass', 'some_hash')
    entity = build_entity('A')
    c = build_collector([entity])
    c.instance_variable_set(:@fetcher, UnchangedFetcher.new('/fake'))
    yielded = []
    with_env('RUBY_RDOC_TARGETS' => 'A') { c.collect { |r| yielded << r } }
    assert_equal 1, yielded.size, 'smoke filter must defeat fast path'
  end

  # parser.parse receives targets when smoke TARGETS is active

  class SpyParser
    attr_reader :targets_received
    def initialize(entities); @entities = entities; @targets_received = :unset; end
    def parse(_dir, targets: nil)
      @targets_received = targets
      @entities
    end
  end

  def test_parser_receives_targets_when_smoke_active
    parser = SpyParser.new([build_entity('Keep')])
    c = RubyRdocCollector::Collector.new({},
      fetcher:    RubyRdocCollectorTestSupport::StubFetcher.new('/fake'),
      parser:     parser,
      formatter:  RubyRdocCollector::MarkdownFormatter.new,
      baseline:   @baseline,
      output_dir: @output_dir)
    with_env('RUBY_RDOC_TARGETS' => 'Keep,Other') { c.collect { |_| } }
    assert_equal %w[Keep Other], parser.targets_received
  end

  def test_parser_receives_nil_targets_when_smoke_inactive
    parser = SpyParser.new([build_entity('A')])
    c = RubyRdocCollector::Collector.new({},
      fetcher:    RubyRdocCollectorTestSupport::StubFetcher.new('/fake'),
      parser:     parser,
      formatter:  RubyRdocCollector::MarkdownFormatter.new,
      baseline:   @baseline,
      output_dir: @output_dir)
    c.collect { |_| }
    assert_nil parser.targets_received
  end

  def test_parallel_processing_persists_all_baseline_entries
    entities = (0...8).map { |i| build_entity("B#{i}") }
    c = build_collector(entities)
    c.collect { |_| }
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'baseline.yml'))
    entities.each do |e|
      hash = @baseline.hash_for(e)
      assert_false b2.changed?(e.name, hash),
        "baseline must contain persisted hash for #{e.name} after parallel run"
    end
  end

  # 2-phase bookmark: fast-path uses baseline.completed?, not populated?

  def test_fast_path_triggers_only_when_baseline_completed
    # baseline has entries + completion marker + tarball unchanged → fast path
    @baseline.persist_one('X', 'hashx')
    @baseline.mark_started
    @baseline.mark_completed
    c = RubyRdocCollector::Collector.new({},
      fetcher:    UnchangedFetcher.new('/fake'),
      parser:     ExplodingParser.new,
      formatter:  RubyRdocCollector::MarkdownFormatter.new,
      baseline:   @baseline,
      output_dir: @output_dir)
    assert_nothing_raised { c.collect { |_| } }
  end

  def test_fast_path_does_not_trigger_for_wip_baseline
    # populated baseline without mark_completed (partial run) must NOT fast-path
    @baseline.persist_one('X', 'hashx')
    @baseline.mark_started  # WIP: started, never completed
    entity = build_entity('A')
    c = build_collector([entity])
    c.instance_variable_set(:@fetcher, UnchangedFetcher.new('/fake'))
    yielded = []
    c.collect { |r| yielded << r }
    assert_equal 1, yielded.size, 'WIP baseline must NOT trigger fast path'
  end

  def test_collect_marks_started_and_completed_on_successful_full_run
    entities = [build_entity('A'), build_entity('B')]
    c = build_collector(entities)
    c.collect { |_| }
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'baseline.yml'))
    assert b2.completed?, 'baseline must be marked completed after successful collect'
  end

  def test_smoke_run_does_not_mark_started_or_completed
    # A smoke run (TARGETS active) processes a subset; it should NOT advance
    # the completion marker (next full run must still run).
    entity = build_entity('Only')
    c = build_collector([entity])
    with_env('RUBY_RDOC_TARGETS' => 'Only') { c.collect { |_| } }
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: File.join(@dir, 'baseline.yml'))
    assert_false b2.completed?, 'smoke runs must not touch the completion marker'
  end

  # output_dir exposure for Rake task

  def test_output_dir_is_accessible
    c = build_collector([])
    assert_equal @output_dir, c.output_dir
  end

  # default output_dir timestamped under /tmp when not injected

  def test_default_output_dir_under_tmp
    c = RubyRdocCollector::Collector.new({},
      fetcher:    StubFetcher.new('/fake'),
      parser:     StubParser.new([]),
      formatter:  RubyRdocCollector::MarkdownFormatter.new,
      baseline:   @baseline)
    assert_match %r{\A/tmp/ruby-rdoc-\d{14}\z}, c.output_dir
  end
end
