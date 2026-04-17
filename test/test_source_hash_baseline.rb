require_relative 'test_helper'

class TestSourceHashBaseline < Test::Unit::TestCase
  def setup
    @dir  = Dir.mktmpdir('baseline')
    @path = File.join(@dir, 'source_hashes.yml')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def build_entity(name, description: 'desc', superclass: 'Object', methods: [])
    RubyRdocCollector::ClassEntity.new(
      name: name, description: description, methods: methods, constants: [], superclass: superclass
    )
  end

  def build_method(name, call_seq: nil, description: 'm')
    RubyRdocCollector::MethodEntry.new(name: name, call_seq: call_seq, description: description)
  end

  # hash_for: deterministic + includes description + superclass + method fields

  def test_hash_for_is_deterministic
    e = build_entity('A')
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    assert_equal b.hash_for(e), b.hash_for(e)
  end

  def test_hash_for_changes_when_description_changes
    b  = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    e1 = build_entity('A', description: 'one')
    e2 = build_entity('A', description: 'two')
    assert_not_equal b.hash_for(e1), b.hash_for(e2)
  end

  def test_hash_for_changes_when_superclass_changes
    b  = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    e1 = build_entity('A', superclass: 'Object')
    e2 = build_entity('A', superclass: 'String')
    assert_not_equal b.hash_for(e1), b.hash_for(e2)
  end

  def test_hash_for_changes_when_method_added
    b  = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    e1 = build_entity('A', methods: [])
    e2 = build_entity('A', methods: [build_method('m1')])
    assert_not_equal b.hash_for(e1), b.hash_for(e2)
  end

  def test_hash_for_changes_when_method_call_seq_changes
    b  = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    e1 = build_entity('A', methods: [build_method('m1', call_seq: 'x → y')])
    e2 = build_entity('A', methods: [build_method('m1', call_seq: 'x → z')])
    assert_not_equal b.hash_for(e1), b.hash_for(e2)
  end

  # changed? / matches logic

  def test_changed_is_true_when_baseline_empty
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    assert b.changed?('A', 'hash1')
  end

  def test_changed_is_false_when_hash_matches_persisted
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.persist_one('A', 'hash1')
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    assert_false b2.changed?('A', 'hash1')
  end

  def test_changed_is_true_when_hash_differs
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.persist_one('A', 'hash1')
    assert b.changed?('A', 'hash2')
  end

  # persist_one atomicity

  def test_persist_one_writes_atomically_no_tmp_leftover
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.persist_one('A', 'hash1')
    # only source_hashes.yml should be present (no lingering .tmp)
    children = Dir.children(@dir).reject { |c| c.start_with?('.') }
    assert_equal ['source_hashes.yml'], children.sort
  end

  def test_persist_one_is_readable_after_reload
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.persist_one('A', 'hash1')
    b.persist_one('B', 'hash2')
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    assert_false b2.changed?('A', 'hash1')
    assert_false b2.changed?('B', 'hash2')
  end

  # mark_seen + cleanup_orphans

  def test_cleanup_orphans_removes_unseen
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.persist_one('A', 'hash1')
    b.persist_one('B', 'hash2')
    b.persist_one('C', 'hash3')
    b.mark_seen('A')
    b.mark_seen('C')
    # B was not marked seen → should be removed
    b.cleanup_orphans
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    assert_false b2.changed?('A', 'hash1')
    assert b2.changed?('B', 'hash2')
    assert_false b2.changed?('C', 'hash3')
  end

  def test_cleanup_orphans_persists_to_disk
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.persist_one('A', 'hash1')
    b.mark_seen('A')
    b.cleanup_orphans
    # YAML schema wraps entries under 'entries' key alongside bookmark fields
    data = YAML.load_file(@path)
    assert_equal({ 'A' => 'hash1' }, data['entries'])
  end

  def test_nonexistent_file_treated_as_empty
    # before any persist_one / cleanup
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    assert b.changed?('X', 'anything')
  end

  def test_populated_is_false_on_fresh_baseline
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    assert_false b.populated?
  end

  def test_populated_is_true_after_persist_one
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.persist_one('A', 'hash1')
    assert b.populated?
  end

  def test_populated_survives_reload
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.persist_one('A', 'hash1')
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    assert b2.populated?
  end

  # thread safety: concurrent mark_seen + persist_one from multiple threads
  def test_concurrent_mutations_produce_consistent_final_state
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    names = (0...100).map { |i| "Class#{i}" }
    threads = names.each_slice(10).map do |batch|
      Thread.new do
        batch.each do |name|
          b.mark_seen(name)
          b.persist_one(name, "hash_#{name}")
        end
      end
    end
    threads.each(&:join)
    reloaded = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    names.each do |name|
      assert_false reloaded.changed?(name, "hash_#{name}"),
        "expected baseline to have #{name} persisted"
    end
  end

  # 2-phase bookmark: last_started_at / last_completed_at for WIP detection

  def test_completed_is_false_on_fresh_baseline
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    assert_false b.completed?
  end

  def test_completed_is_false_after_only_mark_started
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.mark_started
    assert_false b.completed?, 'partial run (started, not completed) must report not completed'
  end

  def test_completed_is_true_after_mark_started_then_mark_completed
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.mark_started
    b.mark_completed
    assert b.completed?
  end

  def test_new_mark_started_invalidates_previous_completion
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.mark_started
    b.mark_completed
    sleep 0.01 # ensure distinct timestamps
    b.mark_started
    assert_false b.completed?, 'a new run-start must invalidate previous completion'
  end

  def test_mark_completed_after_new_start_reports_completed
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.mark_started
    b.mark_completed
    sleep 0.01
    b.mark_started
    b.mark_completed
    assert b.completed?
  end

  def test_completion_marker_survives_reload
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.mark_started
    b.mark_completed
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    assert b2.completed?
  end

  def test_wip_marker_survives_reload
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.mark_started
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    assert_false b2.completed?
  end

  def test_entries_persist_alongside_bookmark
    # entries + bookmark must roundtrip together
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    b.mark_started
    b.persist_one('A', 'hash1')
    b.mark_completed
    b2 = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    assert b2.completed?
    assert_false b2.changed?('A', 'hash1')
  end

  def test_legacy_flat_yaml_is_read_as_entries_without_bookmark
    # Baseline files from earlier versions are a flat { name => sha } Hash.
    # Loading must accept that format and report completed? == false (no marker).
    require 'yaml'
    File.write(@path, { 'LegacyA' => 'legacyhash' }.to_yaml)
    b = RubyRdocCollector::SourceHashBaseline.new(path: @path)
    assert_false b.changed?('LegacyA', 'legacyhash')
    assert_false b.completed?
  end
end
