
require 'socket'
require 'thread'
require 'fastthread'
require 'timeout'
require 'fcntl'
require 'dbcore/global-signal'

class BufferedIO

  def initialize(sock, data_ready_signal)
    @sock_rd = sock
    @sock_wr = sock.dup
    @data_ready_signal = data_ready_signal
    @recv_buf = ""
    @send_buf = ""
    @eof = false
    @suspend_output = false
    @mutex = Mutex.new
    @wr_waiting = false
    @wr_signal = ConditionVariable.new
    @rd_thread = Thread.new { background_read }
    @wr_thread = Thread.new { background_write }
  end

  def eof
    @mutex.synchronize { @eof }
  end

  def peeraddr
    @mutex.synchronize { @sock_rd.peeraddr }
  end

  def close
    flush
    @mutex.synchronize {
      @wr_thread.kill
      @rd_thread.kill
      begin
        @sock_rd.close
        @sock_wr.close
      rescue IOError, SystemCallError
      end
      @eof = true
    }
  end

  def flush(timeout_secs=5.0)
    suspend_output(false)
    start_t = Time.now
    flushed = true
    begin
      @mutex.synchronize {
        flushed = @eof || (@send_buf.empty?  &&  @wr_waiting)
        if flushed
          begin
	    timeout( [0.01, timeout_secs - (Time.now - start_t)].max ) {
              @sock_wr.flush 
	    }
	  rescue Timeout::Error
	    $stderr.puts "BufferedIO#flush: timeout in @sock_wr.flush"
	    break
          rescue IOError, SystemCallError
            @eof = true
          end
        end
      }
      sleep(0.01) if not flushed  # cheezy, but .... ;(
      break if (Time.now - start_t) >= timeout_secs
    end while not flushed
    flushed
  end

  def send_nonblock(str)
    @mutex.synchronize {
# $stderr.puts "\nsend_nonblock(w=#{@wr_waiting})(waiters=#{@wr_signal.instance_eval{@waiters}.inspect})[#{str.inspect}]"  # %%DBG
# sleep(0.2)
      @send_buf << str
      @wr_signal.signal
    }
  end

  def recv_nonblock
    @mutex.synchronize {
      dat = @recv_buf
      @recv_buf = ""
      dat
    }
  end

  def recv_ready?
    @mutex.synchronize {
      @eof  ||  ! @recv_buf.empty?
    }
  end

  def wait_recv_ready(timeout_secs=nil)  # raises: Timeout::Error
    @data_ready_signal.timed_wait(timeout_secs) unless recv_ready?
  end

  def write_pending?
    @mutex.synchronize {
      ! @eof   &&   !(@send_buf.empty?  &&  @wr_waiting)
    }
  end

  def suspend_output(flag)
    @mutex.synchronize {
      @suspend_output = flag
      @wr_signal.signal unless flag
    }
  end
  
  def output_suspend?
    @mutex.synchronize { @suspend_output }
  end
  
  protected

  def eof=(flag)
    @mutex.synchronize {
      @eof = flag
    }
    @data_ready_signal.signal
    flag
  end

  def background_read
    while not eof
      begin
        if select([@sock_rd], nil, nil, nil)
          @sock_rd.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK) if defined? Fcntl::O_NONBLOCK
          dat = @sock_rd.recv(65536)
          if !dat || dat.empty?
            self.eof = true
          else
            @mutex.synchronize { 
              @recv_buf << dat
            }
            @data_ready_signal.signal
          end
        end
      rescue Exception   # was: IOError, SystemCallError
        self.eof = true
      end
    end
  end  

  def background_write
    while not eof
      begin
        to_write = nil
        @mutex.synchronize {
          while @suspend_output || @send_buf.empty?
            @wr_waiting = true
            @wr_signal.wait(@mutex)
            @wr_waiting = false
          end
          to_write = @send_buf
          @send_buf = ""
        }
        send_string(@sock_wr, to_write) if to_write
      rescue Exception
        self.eof = true
      end
    end
  end

  def send_string(sock, str)
    begin
      while str.length > 0
        sock.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK) if defined? Fcntl::O_NONBLOCK
        sent = sock.send(str, 0)
        str = str[sent..-1]
      end
    rescue IOError, SystemCallError
      self.eof = true
    end
  end

end



  


if $0 == __FILE__

  require 'test/unit'

  TEST_HOST = 'localhost'
  TEST_PORT = 12345

  class TestBufferedIO < Test::Unit::TestCase

    def test_bio
      server = TCPServer.new(TEST_PORT)
      client = TCPSocket.new(TEST_HOST, TEST_PORT)
      sv_client = server.accept
      global_signal = GlobalSignal.new

      bio = BufferedIO.new(client, global_signal)
      
      assert( ! bio.eof )
      assert( ! bio.recv_ready? )
      assert_equal( "", bio.recv_nonblock )

      # verify timeout occurs
      assert_raises(Timeout::Error) { bio.wait_recv_ready(0.1) }

      # send some data... wait for signal...
      sv_client.print("spang!\n")
      bio.wait_recv_ready(3.0)
      assert( bio.recv_ready? )
      # we already have data, no wait should occur
      bio.wait_recv_ready(3.0)
      assert_equal( "spang!\n", bio.recv_nonblock )
      assert( ! bio.recv_ready? )

      # send some data... wait for signal...
      sv_client.print("kazango!\n")
      global_signal.wait
      assert( bio.recv_ready? )
      assert_equal( "kazango!\n", bio.recv_nonblock )
      assert( ! bio.recv_ready? )

      # the following test is very slow:
#     stress_beyond_kernel_buflen(bio, sv_client, global_signal)

      # test eof:
      sv_client.close
      # - there's currently no way to wait for the eof condition to
      #   propagate from the background read thread :(
      #   ...so here's a cheezy sleep :(
      sleep(1)
      assert_equal( "", bio.recv_nonblock )
      assert( bio.eof )

      bio.close
      server.close
    end

    def test_flush
      server = TCPServer.new(TEST_PORT)
      client = TCPSocket.new(TEST_HOST, TEST_PORT)
      sv_client = server.accept
      global_signal = GlobalSignal.new
      bio = BufferedIO.new(client, global_signal)
 
      # test flush on close (hopefully... kinda hard to test)
      10.times { bio.send_nonblock("kazango!!!\n") }
      bio.close
      10.times { assert_equal( "kazango!!!\n", sv_client.gets ) }
    
      sv_client.close
      server.close
    end
    
    def stress_beyond_kernel_buflen(bio, sv_client, global_signal)
      num_iter = 8192
      bio_sent = ""
      0.upto(num_iter) do |i|
        $stderr.print "." if i%100 == 0
        bio.send_nonblock "#{i}\n"
        bio_sent << "#{i}\n"
        sv_client.puts "#{i}"
      end
      bio_rcvd = ""
      0.upto(num_iter) do |i|
        $stderr.print "." if i%100 == 0
        assert_equal( "#{i}\n", sv_client.gets )
        bio_rcvd << bio.recv_nonblock
      end
      while bio_rcvd.length < bio_sent.length
        global_signal.wait
        bio_rcvd << bio.recv_nonblock
      end
      assert_equal( bio_sent, bio_rcvd )
    end

  end

end


