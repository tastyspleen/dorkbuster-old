
require 'thread'
require 'fastthread'
require 'fcntl'

# xquake: 204.178.73.203:27910


class Wallfly

  def initialize(ip, port, logfilename)
    @ip = ip
    @port = port
    @logfilename = logfilename
    @mutex = Mutex.new
    @eof = false
    @wpid = @read_th = nil
    @linebuf = []
  end

  def eof
    @mutex.synchronize { @eof }
  end

  def start
    unless @wpid  &&  @read_th
      @eof = false
      begin
        sv_pass = ENV['DORKBUSTER_SERVER_PASSWORD'].to_s
        set_sv_pass = (sv_pass.empty? || sv_pass=="none") ? "" : "+set password #{sv_pass}"
        sv_cfg_name = ENV['DORKBUSTER_SERVER_NICK'].tr('-','_')  # q2 won't exec a filename with a dash :-o
        wfly = IO.popen(%{./q2wallfly #{set_sv_pass} +set cl_maxfps 5 +set rate 100 +exec wallfly.cfg +exec #{sv_cfg_name}.cfg +name "WallFly[BZZZ]" +set nostdout 1 +connect #{@ip}:#{@port}})
      rescue StandardError => ex
        log(ex.inspect)
        return
      end
      @wpid = wfly.pid
      Process.detach(@wpid)
      @linebuf = []
      @readbuf = ""
      @read_th = Thread.new(wfly) {|wfio| nonblock_readline_task(wfio) }
    end
  end

  def stop
    if @wpid  &&  @read_th
      Process.kill("INT", @wpid) rescue nil
      done = @read_th.join(1.0)
      if !done
        Process.kill("TERM", @wpid) rescue nil
        done = @read_th.join(1.0)
        if !done
          Process.kill("KILL", @wpid) rescue nil
          done = @read_th.join(1.0)
          if !done
            Thread.kill(@read_th) rescue nil
            done = true
          end
        end
      end
    end
    @wpid = @read_th = nil
  end

  def read
    lines = []
    @mutex.synchronize {
      lines = @linebuf
      @linebuf = []
    }
    log(lines)
    lines
  end

  def logtail(num_lines=100)
    Wallfly.logtail(@logfilename, num_lines)
  end

  def self.logtail(logfilename, num_lines=100)
    lines = []
    IO.popen("tail -n #{num_lines} #{logfilename}") do |lf|
      lf.each_line {|line| lines << line.chomp }
    end
    lines
  end

  private

  def log(lines)
    unless lines.empty?
      File.open(@logfilename, "a") do |f|
        lines.each do |line|
          f.puts(Time.now.strftime("[%Y-%m-%d %a %H:%M:%S] ") + line)
        end
      end
    end
  end
              
# def bkgnd_read_task(wfly)
#   begin 
#     while ln = wfly.readline
#       @mutex.synchronize { @linebuf << ln.chop }
#     end
#   rescue IOError, SystemCallError
#   end
#   @mutex.synchronize { @eof = true }
# end  

  def nonblock_readline_task(io)
    until @eof
      begin
        if select([io], nil, nil, nil)
          io.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK) if defined? Fcntl::O_NONBLOCK
          dat = io.sysread(65536)
          if !dat
            @eof = true
          elsif !dat.empty?
	    dat.length.times {|i| dat[i] &= 0x7f }  # strip high bits
            @readbuf << dat
            lines = @readbuf.split(/\n/, -1)
            if lines.length > 1
              @mutex.synchronize {
                @readbuf = lines.pop
                @linebuf.push( *lines )
              }
            end
          end
        end
      rescue Exception   # was: IOError, SystemCallError, EOFError
        @eof = true
      end
    end
  end  

  
end

  
