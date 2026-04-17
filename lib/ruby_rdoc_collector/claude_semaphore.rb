module RubyRdocCollector
  # Fixed-size counting semaphore used by Translator to cap concurrent
  # claude CLI invocations across threads. Acquiring threads block until
  # a slot is free; a slot is always released, even on exception.
  class ClaudeSemaphore
    def initialize(size)
      @available = Queue.new
      size.times { @available << :slot }
    end

    def acquire
      slot = @available.pop
      begin
        yield
      ensure
        @available << slot
      end
    end
  end
end
