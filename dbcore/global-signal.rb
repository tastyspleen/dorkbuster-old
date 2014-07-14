
require 'thread'
require 'fastthread'
require 'dbcore/timed-wait'

#
# This is just an encapsulated Mutex & ConditionVariable
# intended to be passed into various IO classes which will
# all signal this thing when they have data ready.
# Could get fancy and keep track of *who* is doing the
# signalling... but ... this is supposed to be simple.
#
class GlobalSignal
  def initialize
    @mutex = Mutex.new
    @signal = ConditionVariable.new
    @signalled = false
  end
  
  def signal
    @mutex.synchronize {
      @signal.broadcast
      @signalled = true
    }
  end

  def wait
    @mutex.synchronize {
      begin
        @signal.wait(@mutex) unless @signalled
      ensure
        @signalled = false
      end
    }
  end

  def timed_wait(timeout_secs)   # raises: Timeout::Error
    begin
      @mutex.synchronize {
        begin
          @signal.timed_wait(@mutex, timeout_secs) unless @signalled
        ensure
          @signalled = false
        end
      }
    rescue ThreadError => ex
      # NOTE: %%BWK 071127 -- now that fastthread has been integrated into 1.8.6, my
      #                       timed-wait hack seems to have issues... We get a
      #                        `synchronize': not owner (ThreadError) exception
      #                       occasionally.
      warn "timed_wait: ThreadError: #{ex.message}"
      raise Timeout::Error, ex.message
    end
  end
  
  #
  # TODO: add a GlobalSignal#synchronize ?  So that
  # we'll be able to check an entire list of resources
  # we care about that might call GlobalSignal#signal,
  # so that we atomically are able to examine all
  # these resources for a ready state, before deciding
  # to #wait . . . . Or is this necessary?
  # Want to prevent any possibility of our calling #wait
  # when the resources may have just become ready.
  # Guess that's what @signalled is for.
end






# $stderr.puts "GlobalSignal#wait: signalled was #@signalled"

# $stderr.puts "GlobalSignal#wait: done"

# $stderr.puts "GlobalSignal#signal: signalled was #@signalled"

# I think there are some problems with GlobalSignal#wait
#  - if there are multiple waiters, and the broadcast happens,
#    they still need to wake up "one by one" or rather they
#    still WILL wake up "one by one", and each will then set
#    @signalled = false ... only ... seems like there's the
#    possibility some thread will wait because the unless @signalled
#    will be true because @signalled was just cleared by a
#    thread awaking from a previous broadcast


