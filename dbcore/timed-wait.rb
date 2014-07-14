
require 'thread'
require 'fastthread'
require 'timeout'

class ConditionVariable

  def timed_wait(mutex, timeout_secs)  # raises: Timeout::Error
    if timeout_secs
      timeout(timeout_secs) { wait(mutex) }
    else
      wait(mutex)
    end
  end


#   def wait(mutex)
#     unlocked = false    
#     begin
#       mutex.exclusive_unlock do
#         unlocked = true
#         @waiters.push(Thread.current)
#         Thread.stop
#       end
#     rescue Exception
#       @waiters.delete Thread.current   # is Array#delete an atomic operation?
#       raise
#     ensure
#       mutex.lock if unlocked
#     end
#   end
# 
#   def timed_wait(mutex, timeout_secs)  # raises: Timeout::Error
#     timed_out = false
#     waiter_th = Thread.current
#     alarm_th = nil
#     unlocked = false
#     begin
#       if timeout_secs
#         alarm_th = Thread.start do
#           sleep timeout_secs
#           Thread.exclusive do
#             timed_out = true
#             @waiters.delete waiter_th
#             waiter_th.wakeup
#           end
#         end
#       end
# 
#       Thread.exclusive do
#         unless timed_out
#           mutex.exclusive_unlock do
#             unlocked = true
#             @waiters.push(Thread.current)
#             Thread.stop
#           end
#         end
#       end
#     ensure
#       mutex.lock if unlocked
#       alarm_th.kill if alarm_th and alarm_th.alive?
#     end
#     raise Timeout::Error, "execution expired" if timed_out
#   end

end


