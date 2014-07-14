
require 'thread'
require 'fastthread'


# ["lock", "locked?", "synchronize", "try_lock", "unlock"]


class RecursiveMutex
  def initialize
    @mutex = Mutex.new
    @owner_th = nil
    @count = 0
  end

  def lock
    begin
      Thread.critical = true
      if @mutex.locked?  &&  @owner_th == Thread.current
        @count += 1
      else
        @mutex.lock  # RESETS Thread.critical
        # NOTE: *not* a race condition here before we set crit = true
        Thread.critical = true
        @owner_th = Thread.current
        @count = 1
      end
    ensure
      Thread.critical = false
    end
  end

  def locked?
    @mutex.locked?
  end

  def unlock
    begin
      Thread.critical = true
      if (@count -= 1) == 0
        @owner_th = nil
        @mutex.unlock  # RESETS Thread.critical
      end
    ensure
      Thread.critical = false
    end
  end
  
  def synchronize
    result = nil
    begin
      lock
      result = yield
    ensure
      unlock
    end
    result
  end

end


if $0 == __FILE__
  require 'test/unit'

  class TestRecursiveMutex < Test::Unit::TestCase

    def test_recursive_mutex
      mutex = RecursiveMutex.new
      assert( !mutex.locked? )
    
      val = 0      

      th1 = Thread.new {
        1000.times do
          x = mutex.synchronize { 
            assert( mutex.locked? )
            mutex.synchronize {
              v = val
              val = 0
              assert( mutex.locked? )
              mutex.synchronize {
                assert( mutex.locked? )
                assert_equal( 3, mutex.instance_eval {@count} )
              }
              v += 1
              val += v
            }
            :spleen
          }  
          assert_equal( :spleen, x )
        end
      }

      th2 = Thread.new {
        1000.times do
          x = mutex.synchronize { 
            assert( mutex.locked? )
            mutex.synchronize {
              v = val
              val = 0
              assert( mutex.locked? )
              mutex.synchronize {
                assert( mutex.locked? )
                assert_equal( 3, mutex.instance_eval {@count} )
              }
              v += 1
              val += v
            }
            :spleen
          }  
          assert_equal( :spleen, x )
        end
      }
    
      th1.join
      th2.join
      assert_equal( 2000, val )
    end
    
  end
end

