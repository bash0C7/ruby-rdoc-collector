require 'test/unit'
require 'fileutils'
require 'tmpdir'
require 'json'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'ruby_rdoc_collector'

FIXTURE_DIR = File.expand_path('fixtures', __dir__)

StubRunner = ->(_prompt) { 'これは翻訳されたテキスト。' }

class EchoRunner
  attr_reader :calls

  def initialize(response: 'JP')
    @response = response
    @calls    = 0
  end

  def call(_prompt)
    @calls += 1
    @response
  end
end

class FailingRunner
  attr_reader :calls

  def initialize(fail_count: 1, eventual: 'JP')
    @fail_count = fail_count
    @eventual   = eventual
    @calls      = 0
  end

  def call(_prompt)
    @calls += 1
    if @calls <= @fail_count
      raise RubyRdocCollector::Translator::TranslationError, 'transient'
    end
    @eventual
  end
end
