# ruby_rdoc_collector

Collector that downloads pre-built RDoc darkfish HTML from `cache.ruby-lang.org`, parses per-class data, and streams `{content:, source:}` records to the [ruby-knowledge-db](https://github.com/bash0C7/ruby-knowledge-db) pipeline. Content is stored in English as-is; on-demand Japanese translation for queries and display is handled by the host LLM agent downstream (see chiebukuro-mcp meta hints).

## Data source

`https://cache.ruby-lang.org/pub/ruby/doc/ruby-docs-en-master.tar.xz`

Generated daily by [ruby/actions docs.yml](https://github.com/ruby/actions/blob/master/.github/workflows/docs.yml) — `make html` on ruby/ruby master.

## DB source value

`ruby/ruby:rdoc/trunk/{ClassName}` — one record per class.

## Streaming API

```ruby
require 'ruby_rdoc_collector'

collector = RubyRdocCollector::Collector.new({})

# Block form: one record streamed per yield
collector.collect do |record|
  store.store(record[:content], source: record[:source])
end

# No-block form: lazy Enumerator
collector.collect.each { |record| ... }

# Discover the run's intermediate MD directory (for debugging)
collector.output_dir
```

## Intermediate MD files

Each yielded record's content is also written to `/tmp/ruby-rdoc-<YYYYmmddHHMMSS>/<SanitizedClassName>.md` as a debug artifact. Filenames sanitize `::` → `__` and non-`[A-Za-z0-9_-]` → `_`.

## source_hash baseline

Per-class SHA256 (description + superclass + each method's name/call_seq/description) is persisted to `~/.cache/ruby-rdoc-collector/source_hashes.yml`. Unchanged classes are skipped silently; yield-failure leaves the baseline untouched so the next run retries.

The baseline file is a two-phase bookmark: `mark_started` is written at the top of a non-smoke collect, `mark_completed` only after `cleanup_orphans` finishes. A run that is started but not completed is treated as WIP and re-processed on the next call.

## Fast path

If `fetcher.unchanged?` (tarball SHA matches the last run) AND `baseline.completed?` AND smoke filters are inactive, `collect` returns immediately without parsing. Any change to either the tarball or baseline WIP state re-engages the full pipeline.

## Smoke / escape hatches

- `RUBY_RDOC_TARGETS=ClassA,ClassB` — only parse listed classes
- `RUBY_RDOC_MAX_METHODS=N` — cap methods per class to first N

Smoke runs never advance the completion marker and never orphan-cleanup.

## Cache

`~/.cache/ruby-rdoc-collector/tarball/` holds the downloaded `ruby-docs-en-master.tar.xz` and its extracted content. Subsequent runs reuse it unless the upstream SHA changes.
