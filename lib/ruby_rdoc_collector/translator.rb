require 'digest'
require 'open3'

module RubyRdocCollector
  class Translator
    class TranslationError < StandardError; end

    MODEL_TAG = 'claude-sonnet'
    DEFAULT_MAX_RETRIES = 3
    RETRY_WAIT_SECONDS = 10

    PROMPT_HEADER = <<~HEADER
      あなたは Ruby の公式ドキュメント翻訳者です。

      ## コンテキスト
      - 入力は Ruby (CRuby) の RDoc ドキュメントから抽出された英語テキスト（HTML形式の場合あり）です
      - Ruby のソースコードは Prism（Ruby 標準ライブラリ）で解析可能な構文です
      - C 言語で記述されたメソッドの RDoc コメントは rdoc/parser（Ruby 標準ライブラリ）形式に従っています
      - call-seq: 記法、+code+ 記法、<code>code</code> タグなど RDoc 特有のマークアップが含まれることがあります

      ## 翻訳ルール
      - コードブロック、メソッドシグネチャ、識別子（クラス名・メソッド名・定数名・引数名）は**原文のまま**保持
      - 散文（説明文）のみを自然な日本語に翻訳
      - 出力はプレーンテキスト（HTMLタグは除去して出力）
      - 出力は翻訳された本文のみ。前置き・後書き・「翻訳結果:」などの注釈は不要

      --- 入力ここから ---
    HEADER

    def initialize(runner: nil, cache: TranslationCache.new, max_retries: DEFAULT_MAX_RETRIES, sleeper: ->(sec) { sleep(sec) })
      @runner      = runner || default_runner
      @cache       = cache
      @max_retries = max_retries
      @sleeper     = sleeper
    end

    def translate(en_text)
      return '' if en_text.nil? || en_text.strip.empty?

      key = cache_key(en_text)
      cached = @cache.read(key)
      return cached if cached

      result = run_with_retry(en_text)
      @cache.write(key, result)
      result
    end

    private

    def cache_key(en_text)
      Digest::SHA256.hexdigest("#{MODEL_TAG}::#{en_text}")
    end

    def run_with_retry(en_text)
      prompt = "#{PROMPT_HEADER}#{en_text}\n--- 入力ここまで ---"
      attempts = 0
      last_error = nil
      while attempts < @max_retries
        attempts += 1
        begin
          result = @runner.call(prompt)
          raise TranslationError, 'empty response' if result.nil? || result.strip.empty?
          return result
        rescue TranslationError => e
          last_error = e
          @sleeper.call(RETRY_WAIT_SECONDS) if attempts < @max_retries
        end
      end
      raise TranslationError, "failed after #{attempts} attempts: #{last_error&.message}"
    end

    def default_runner
      lambda do |prompt|
        out, status = Open3.capture2e('claude', '--model', 'sonnet', '-p', '-', stdin_data: prompt)
        raise TranslationError, "claude exit #{status.exitstatus}: #{out[0, 500]}" unless status.success?
        out
      end
    end
  end
end
