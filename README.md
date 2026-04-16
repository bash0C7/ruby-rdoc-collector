# ruby_rdoc_collector

Collector that downloads pre-built RDoc darkfish HTML from `cache.ruby-lang.org`, parses class/method data, translates English descriptions into Japanese via Claude CLI (sonnet), and emits `{content:, source:}` pairs for the [ruby-knowledge-db](https://github.com/bash0C7/ruby-knowledge-db) pipeline.

## Data Source

`https://cache.ruby-lang.org/pub/ruby/doc/ruby-docs-en-master.tar.xz`

Generated daily by [ruby/actions docs.yml](https://github.com/ruby/actions/blob/master/.github/workflows/docs.yml) — `make html` on ruby/ruby master.

## Source value

`ruby/ruby:rdoc/trunk/{ClassName}` — one record per class.

## Caches

| Path | Owner | Content |
|------|-------|---------|
| `~/.cache/ruby-rdoc-collector/tarball/` | this gem | downloaded tar.xz + extracted HTML |
| `~/.cache/ruby-rdoc-collector/translations/` | this gem | SHA256-keyed translation cache |

## Translation cache key

```
SHA256("claude-sonnet::" + html_text)
```

Re-running the collector with unchanged upstream descriptions is a full cache hit with zero Claude CLI calls.

## Usage

```ruby
require 'ruby_rdoc_collector'

collector = RubyRdocCollector::Collector.new(
  'url' => 'https://cache.ruby-lang.org/pub/ruby/doc/ruby-docs-en-master.tar.xz'
)
collector.collect # => [{content:, source:}, ...]
```

## Test

```bash
bundle exec rake test
```
