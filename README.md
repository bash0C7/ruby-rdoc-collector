# ruby_rdoc_collector

Collector that downloads pre-built RDoc darkfish HTML from `cache.ruby-lang.org`, parses per-class data, translates English descriptions into Japanese via Claude CLI (`haiku`), and streams `{content:, source:}` records to the [ruby-knowledge-db](https://github.com/bash0C7/ruby-knowledge-db) pipeline.

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

`since:` / `before:` keyword args are accepted for signature compatibility with other collectors but ignored — the tarball is always the latest snapshot.

## Per-entity pipeline

For each parsed class, in order:

1. `baseline.mark_seen` (for end-of-run orphan cleanup)
2. Compute source-hash from description + superclass + each method's name / call_seq / description
3. Skip silently if the hash matches the baseline (no translate / no file / no DB)
4. Translate class description + method descriptions (4-thread pool for methods inside a class)
5. Format MD
6. Write intermediate MD file — failure logs a warning and skips steps 7-8
7. Yield `{content:, source:}` to the caller — caller exception logs a warning and skips step 8
8. `baseline.persist_one` atomically (Tempfile + rename)

After iteration, `baseline.cleanup_orphans` removes per-class entries absent from this run. Cleanup is **skipped when a smoke filter is active** so smoke runs can't wipe the baseline.

## Fast path

When all of the following hold, `collect` returns immediately with no parse, translate, or file I/O:

- `fetcher.unchanged?` — tarball SHA256 matches the last extracted tarball
- `baseline.populated?` — the source-hash baseline has at least one entry
- no smoke filter active

## Smoke / integration escape hatches

| env var | effect |
|---|---|
| `RUBY_RDOC_TARGETS=Array,Hash` | Parser pre-filters to listed classes; only those are parsed |
| `RUBY_RDOC_MAX_METHODS=20` | Cap methods/class to first N after parse |

When either is set, `cleanup_orphans` is skipped and the fast path is bypassed so the smoke run always exercises the pipeline.

## Caches

| Path | Purpose |
|---|---|
| `~/.cache/ruby-rdoc-collector/tarball/ruby-docs-en-master.tar.xz` | downloaded tarball |
| `~/.cache/ruby-rdoc-collector/tarball/extracted/` | extracted HTML tree |
| `~/.cache/ruby-rdoc-collector/tarball/tarball.sha256` | SHA256 of the tarball behind the current extracted tree; re-extract is skipped when it still matches |
| `~/.cache/ruby-rdoc-collector/tarball/*.etag` | `curl --etag-compare` state for HTTP 304 short-circuit |
| `~/.cache/ruby-rdoc-collector/translations/<shard>/<key>` | haiku JP output keyed by SHA256; prompt-unchanged retranslation is a cache hit |
| `~/.cache/ruby-rdoc-collector/source_hashes.yml` | per-class English-source fingerprint; identical content skips the full pipeline |

Intermediate MD files (debug artifacts, not auto-cleaned):

`/tmp/ruby-rdoc-<YYYYmmddHHMMSS>/<SanitizedClassName>.md`

`::` in class names becomes `__`; other non-word characters become `_`.

## Translation cache key

```
SHA256("v3|haiku\n" + en_text)
```

The version prefix is bumped whenever the prompt or invocation environment changes, invalidating stale entries atomically.

## Translation prompt

`PROMPT_HEADER` opens with a top-priority directive mandating Japanese 標準語 output and forbidding dialects / emoticons / colloquial sentence endings. This counters user-level Claude CLI persona config that would otherwise bleed through regardless of `chdir`.

The Translator subprocess runs with `chdir: '/tmp'` to skip project-level `CLAUDE.md` pickup.

## Test

```bash
bundle exec rake test
```
