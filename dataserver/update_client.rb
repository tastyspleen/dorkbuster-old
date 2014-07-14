
require 'socket'
require 'timeout'
require 'fastthread'
require 'dataserver_config'  # just for the host/port constants

# NOTE:
# We're not using eventmachine for the client, here,
# since dorkbuster is currently not eventmachine-based.


# CoalescingBacklogQueue merges new updates with
# existing updates in the queue where possible,
# preserving the total count value associated with
# the merged updates.
#
class CoalescingBacklogQueue
  def initialize
    @cache = Hash.new(0)
    @queue = []
    @mutex = Mutex.new
    @value_available = ConditionVariable.new
    @num_waiting = 0
  end
  
  def push(data_key, count)
    @mutex.synchronize {
      if @cache.has_key? data_key
        @cache[data_key] += count
      else  
        @cache[data_key] = count
        @queue.unshift data_key
      end
      @value_available.signal
    }
  end
  
  def pop
    @mutex.synchronize {
      while @queue.empty?
        begin
          @num_waiting += 1
          @value_available.wait(@mutex)
        ensure
          @num_waiting -= 1
        end
      end
      data_key = @queue.pop
      count = @cache.delete data_key
      [data_key, count]
    }    
  end
  
  def empty?
    @mutex.synchronize { @queue.empty? }
  end
  
  def length
    @mutex.synchronize { @queue.length }
  end

  def num_waiting
    @mutex.synchronize { @num_waiting }
  end
end


class UpdateClient
  UPDATE_SERVER_CREDENTIALS_FILE = ".update-pass"

  def initialize(logger, host=Dataserver::UPDATE_SERVER_IP, port=Dataserver::UPDATE_SERVER_PORT)
    @logger = logger
    @host, @port = host, port
    @credentials = File.read(UPDATE_SERVER_CREDENTIALS_FILE).strip
    @update_th = nil
    @update_sock = nil
    @update_queue = CoalescingBacklogQueue.new
  end

  def connect
    close
    @update_th = Thread.new do
      loop do
        begin
          initiate_connection
          send_updates
        rescue Exception => ex
          @logger.log("UpdateClient: caught exception #{ex.inspect} - #{ex.backtrace.inspect}")
          sleep 5
        end
      end
    end
  end

  def close
    if th = @update_th
      th.kill
      @update_th = nil
    end
    close_update_sock
  end

  def backlog
    @update_queue.length
  end

  def idle?
    @update_queue.empty?  &&  @update_queue.num_waiting != 0
  end

  def flush
    sleep 0.1 until idle?
  end

  def playerseen(playername, ip, servername, timestamp, times_seen=1)
    data_key = ['playerseen', playername, ip, servername, timestamp.tv_sec].join("\t")
    @update_queue.push(data_key, times_seen)
  end

  def frag(inflictor, victim, method_str, servername, date, count)
    data_key = ['frag', inflictor, victim, method_str, servername, date.to_s].join("\t")
    @update_queue.push(data_key, count)
  end

  def suicide(victim, method_str, servername, date, count)
    data_key = ['suicide', victim, method_str, servername, date.to_s].join("\t")
    @update_queue.push(data_key, count)
  end

  protected

  def initiate_connection
    close_update_sock
    @update_sock = TCPSocket.new(@host, @port)
    ok = transact("auth #@credentials")
    raise "UpdateClient: auth login failed" unless ok
  end

  def close_update_sock
    if sock = @update_sock
      begin
        timeout(1.0) { sock.puts "quit" rescue nil }
      rescue Timeout::Error
      end
      sock.close rescue nil
      @update_sock = nil
    end
  end

  def transact(line)
    @update_sock.puts line
    resp = @update_sock.gets
    raise "lost connection to update server" if resp.nil? || resp.empty?
    resp_good = resp =~ /\A200 /
    @logger.log("Update failed for #{line.inspect} - #{resp.inspect}") unless resp_good
    resp_good
  end

  def send_updates
    loop do
      # fetch envelop containing data_key and count
      envelope = @update_queue.pop
      begin
        line = envelope.join("\t")
        transact(line)
      rescue Exception => ex
        @update_queue.push(*envelope)   # we'll retry this later, if possible
        raise
      end
    end
  end

end



