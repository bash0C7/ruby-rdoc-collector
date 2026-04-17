require_relative 'test_helper'

class TestClaudeSemaphore < Test::Unit::TestCase
  def test_acquires_and_releases_slot
    sem = RubyRdocCollector::ClaudeSemaphore.new(1)
    called = false
    sem.acquire { called = true }
    assert called
  end

  def test_returns_block_value
    sem = RubyRdocCollector::ClaudeSemaphore.new(2)
    result = sem.acquire { 42 }
    assert_equal 42, result
  end

  def test_releases_slot_on_exception
    sem = RubyRdocCollector::ClaudeSemaphore.new(1)
    begin
      sem.acquire { raise 'boom' }
    rescue
      # expected
    end
    # next acquire must not block indefinitely — slot was released on exception
    called = false
    Thread.new { sem.acquire { called = true } }.join(1)
    assert called, 'slot was not released on exception'
  end

  def test_limits_concurrent_callers_to_size
    sem = RubyRdocCollector::ClaudeSemaphore.new(3)
    in_flight = 0
    max_in_flight = 0
    mutex = Mutex.new

    threads = 12.times.map do
      Thread.new do
        sem.acquire do
          mutex.synchronize do
            in_flight += 1
            max_in_flight = [max_in_flight, in_flight].max
          end
          sleep 0.02
          mutex.synchronize { in_flight -= 1 }
        end
      end
    end
    threads.each(&:join)
    assert_equal 3, max_in_flight, "max in-flight must equal semaphore size (saw #{max_in_flight})"
  end

  def test_blocks_when_all_slots_busy
    sem = RubyRdocCollector::ClaudeSemaphore.new(1)
    holder_done = false
    waiter_done = false
    holder = Thread.new do
      sem.acquire do
        sleep 0.2
        holder_done = true
      end
    end
    sleep 0.05 # ensure holder has the slot
    waiter = Thread.new do
      sem.acquire { waiter_done = true }
    end
    # at this point, waiter must NOT be done yet
    sleep 0.05
    assert_false waiter_done, 'waiter must block while holder has the only slot'
    holder.join
    waiter.join
    assert holder_done
    assert waiter_done
  end
end
