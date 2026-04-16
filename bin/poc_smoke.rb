#!/usr/bin/env ruby
# frozen_string_literal: true
# Usage: bundle exec ruby bin/poc_smoke.rb [Ruby::Box] [String] [Integer]
# Downloads the master tarball from cache.ruby-lang.org and runs the full pipeline.
# This invokes real Claude CLI — costs $ and takes minutes.

require 'bundler/setup'
require 'ruby_rdoc_collector'

targets = ARGV.empty? ? ['Ruby::Box', 'String', 'Integer'] : ARGV

collector = RubyRdocCollector::Collector.new({})
puts "Running collector (real Claude CLI — this will take minutes and cost $)..."
all = collector.collect
selected = all.select { |r| targets.any? { |t| r[:source].end_with?("/#{t}") } }

selected.each do |r|
  puts "\n\n==========================\n#{r[:source]}\n==========================\n\n"
  puts r[:content]
end

puts "\n---\nclasses collected: #{all.size}, printed: #{selected.size}"
