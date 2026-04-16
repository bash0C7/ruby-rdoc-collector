#!/usr/bin/env ruby
# frozen_string_literal: true
#
# == PoC Smoke Script — ruby-rdoc-collector
#
# Usage:
#   bundle exec ruby bin/poc_smoke.rb
#
# This script validates the full translation pipeline against a small, safe
# subset of Ruby classes. Hard caps prevent runaway cost/time.
#
# Hard caps (enforced before any Claude CLI call):
#   TARGETS         = ['Ruby::Box', 'Complex', 'Rational']
#   MAX_METHODS     = 20       # per-class cap (protects against String/Integer blowup)
#   TIMEOUT_SECONDS = 600      # 10-minute ceiling wrapping all translation
#   THREADS         = 4        # thread pool size for parallel method translation
#   MODEL           = 'haiku'  # Claude model (haiku = low cost, fast)
#
# == PoC Findings (2026-04-16, haiku model) ==
#
# Wall clock:
#   1st run: 341.4s (3 class descs + 49 method descs = 52 Claude calls, 4 threads)
#   2nd run: 0.0s   (translation cache hits 100% — perfect idempotency)
#
# Throughput: ~52 calls / 341s / 4 threads ≈ ~26s avg per thread per call.
#   haiku is fast per-call but the parallel speedup is bounded by per-call latency,
#   not by call count. 4 threads is well-tuned for this workload.
#
# Cost (haiku 4.5 pricing: $1/Mtok in, $5/Mtok out):
#   ~500 in + ~300 out per call ≈ $0.0023/call → ~$0.12 for whole PoC, ~$0.04/class.
#   Production estimate: 1014 classes × ~10 methods avg ≈ 10k calls → ~$23 first fill.
#   With SHA cache, subsequent runs only translate changed entries → near-zero.
#
# Quality verdict: GOOD with one caveat.
#   + Technical accuracy preserved (有理数, 分子, 分母, リテラル, etc.).
#   + English originals correctly emitted in <details><summary>Original (en)</summary>
#     blocks after each JP translation — human verification path works.
#   ! CAVEAT: translation tone leaked dialect/persona from caller's global CLAUDE.md.
#     Sample (Rational): "有理数は整数のペア a/b で表現される……のことやな。"
#     Cause: `claude --model haiku -p -` inherits the user's Claude Code persona setup.
#     Fix needed: Translator prompt must explicitly require neutral/standard Japanese
#     and forbid persona/dialect adoption. Open as follow-up before Stage 3 production.
#
# Empty translations:
#   Ruby::Box#require / #require_relative came back empty because the source RDoc
#   has no <div class="method-description"> content (C-level method, undocumented).
#   Not a translator bug. Formatter could optionally skip empty method blocks.
#
# Status: DONE_WITH_CONCERNS — proceed to followup (Translator prompt hardening)
#         before Stage 3 integration.

require 'bundler/setup'
require 'timeout'
require 'ruby_rdoc_collector'

TARGETS          = ['Ruby::Box', 'Complex', 'Rational'].freeze
MAX_METHODS      = 20
TIMEOUT_SECONDS  = 600
THREADS          = 4
MODEL            = 'haiku'

# --- Phase 1: Fetch + Parse ---
puts "[poc_smoke] Fetching tarball..."
fetcher     = RubyRdocCollector::TarballFetcher.new
content_dir = fetcher.fetch
puts "[poc_smoke] Parsing HTML..."
entities = RubyRdocCollector::HtmlParser.new.parse(content_dir)

# --- Phase 2: Select targets ---
selected = entities.select { |e| TARGETS.include?(e.name) }
missing  = TARGETS - selected.map(&:name)
unless missing.empty?
  warn "[poc_smoke] ERROR: target class(es) not found in tarball: #{missing.join(', ')}"
  exit 1
end

# --- Phase 3: Cap methods per class (ClassEntity is Data, immutable — use #with) ---
selected = selected.map { |e| e.with(methods: e.methods.first(MAX_METHODS)) }

total_methods = selected.sum { |e| e.methods.size }
puts "[poc_smoke] PoC plan: #{selected.size} classes, #{total_methods} methods, model=#{MODEL}, threads=#{THREADS}, cap=#{TIMEOUT_SECONDS}s"

# --- Helper: parallel translate (mirrors Collector#parallel_translate) ---
def parallel_translate(items, threads:, &block)
  return [] if items.empty?
  results = Array.new(items.size)
  queue   = Queue.new
  items.each_with_index { |item, i| queue << [i, item] }
  workers = [threads, items.size].min.times.map do
    Thread.new do
      until queue.empty?
        begin
          idx, item = queue.pop(true)
        rescue ThreadError
          break
        end
        results[idx] = block.call(item)
      end
    end
  end
  workers.each(&:join)
  results
end

# --- Phase 4: Translate + Format inside timeout ---
start_time = Time.now
results = []

Timeout.timeout(TIMEOUT_SECONDS) do
  translator = RubyRdocCollector::Translator.new(model: MODEL)
  formatter  = RubyRdocCollector::MarkdownFormatter.new

  results = selected.map do |e|
    puts "[poc_smoke] Translating #{e.name} (#{e.methods.size} methods)..."
    jp_desc = translator.translate(e.description)

    jp_methods = parallel_translate(e.methods, threads: THREADS) do |m|
      begin
        [m.name, translator.translate(m.description)]
      rescue RubyRdocCollector::Translator::TranslationError => err
        warn "[poc_smoke] method #{e.name}##{m.name} failed: #{err.message}"
        [m.name, '']
      end
    end.to_h

    en_methods = e.methods.to_h { |m| [m.name, m.description || ''] }

    content = formatter.format(e,
      jp_description:         jp_desc,
      jp_method_descriptions: jp_methods,
      en_description:         e.description,
      en_method_descriptions: en_methods)

    { source: "ruby/ruby:rdoc/trunk/#{e.name}", content: content }
  end
end

wall = (Time.now - start_time).round(1)

# --- Phase 5: Print results ---
results.each do |r|
  puts "\n\n========================================\n#{r[:source]}\n========================================\n\n"
  puts r[:content]
end

# --- Summary ---
puts "\n---"
puts "classes: #{results.size}, methods: #{total_methods}, wall: #{wall}s"
