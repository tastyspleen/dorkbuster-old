require 'timeout'
require 'fcntl'

ClientState = Struct.new("Q2rcon_ClientState", :num, :score, :ping, :name, :lastmsg, :ip, :port, :qport)

class ServerState
  attr_reader :status
  def initialize(status = {})
    @status = status
  end
  def [](field); @status[field]; end
  def []=(field, val); @status[field] = val; end
end

class Q2rcon

  UDP_RECV_TIMEOUT = 0.5  # seconds
  RCON_MAYBE_MULTIPLE_THRESH = 1300  # if packet this big, maybe another one follows
  REGEX_RCON_STATUS_SEQ0 = /\Aprint\n(map |Current map: )/
  REGEX_RCON_STATUS_ROW = /^\s*(\d+)\s+([\d-]+)\s+(\w+)\s(.{15,}?)\s+(\d+)\s+([\d.]+):(\d+)\s+(\d+)/
  
  def initialize(rcon_password, server_addr, server_port = 27910)
    @rcon_password, @server_addr, @server_port = rcon_password, server_addr, server_port
  end

  # Look, Timmy, it's a Stateful Rcon Status Packet Resequencer and
  # Continuation Predictor !
  def q2cmd(str)
    is_rcon = str =~ /\Arcon /
    is_status = is_rcon && str =~ /\Arcon\s+\S+\s+status/
    sock = nil
    pkbuf = []
    seq = -1
    begin
      cmd = "\377\377\377\377#{str}\0"
     begin
     timeout(0.17) {
      sock = UDPSocket.open
      if defined? Fcntl::O_NONBLOCK
        if defined? Fcntl::F_GETFL
          sock.fcntl(Fcntl::F_SETFL, sock.fcntl(Fcntl::F_GETFL) | Fcntl::O_NONBLOCK)
        else
          sock.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK)
        end
      end
      n = sock.send(cmd, 0, @server_addr, @server_port)
     }
     rescue Timeout::Error
       File.open("db-error.log", "a") {|f| f.puts "[#{Time.now}] q2cmd: timeout in UDP open/send"}
     end

# File.open("db-error.log", "a") {|f| f.puts "[#{Time.now}] q2cmd: UDP send returned #{n}"}

      begin
        seq += 1
        last = q2recv(sock)
        if last
          pkbuf << last
 # $stderr.puts "seq=#{seq} length=#{last.length} buflength=#{pkbuf.join.length} : #{last[/\A[^\n]*(\n[^\n]{0,40})?/].inspect}"
        else
 # $stderr.puts "seq=#{seq} last=nil buflength=#{pkbuf.join.length}"
        end
      end while is_rcon && last && expect_another_rcon_packet(is_status, seq, last)
    rescue IOError, SystemCallError
    ensure
      sock.close if sock
    end
    pkbuf.each {|p| p.sub!(/\Aprint\n/, "")}
    pkbuf = sort_rcon_status_packets(pkbuf) if is_status
    (pkbuf.length > 0) ? pkbuf.join : nil
  end

  def rcon(cmd)
  # begin
    q2cmd("rcon #{@rcon_password} #{cmd}")
  # rescue Exception => ex
  # $stderr.puts "rcon: caught exception: #{ex.inspect}\n#{ex.backtrace}"
  # end
  end

  def rcon_status
    status_str = rcon("status")
    if status_str
      parse_rcon_status(status_str)
    end
  end

  def parse_rcon_status(status_str)
    map = status_str.scan(/map\s*:\s+(\w+)/).flatten[0] || ""
    return nil if map.empty?  # actually if we can't parse it, just fail
    # num score ping name            lastmsg address               qport
    # --- ----- ---- --------------- ------- --------------------- ------
    #   0     8   72 _R41L_V4POR           6 123.45.67.8:27901     33596
    #   1     0   86 Bean Doggie           2 123.45.67.8:27901     37804
    #   2     0   95 outlaw               19 123.45.67.8:27901     2704
    #   3    22   71 Pretzel               0 123.45.67.8:27901     64956
    #   7     5  135 Lucky # 7             6 123.45.67.8:61223     62544
    #
    # q2pro:
    # num score ping name            lastmsg address               rate   pr fps
    # --- ----- ---- --------------- ------- --------------------- ------ -- ---
    client_data = status_str.scan(REGEX_RCON_STATUS_ROW)
    client_data.each do |info|
      info[0] = info[0].to_i
      info[1] = info[1].to_i
      info[2] = info[2].to_i if info[2] =~ /\A\d+\z/
      info[3].gsub!(/\s+$/, "")  # remove name's trailing blanks
      info[4] = info[4].to_i
      info[6] = info[6].to_i
      info[7] = info[7].to_i
    end
    client_list = client_data.collect {|info| ClientState.new(*info) }
    [map, client_list]
  end

  def public_status
    status_str = q2cmd("status")
    if status_str
      parse_public_status(status_str)
    end
  end

  def parse_public_status(status_str)
    lines = status_str.split(/\n/)
    # lines.shift # drop "print" line
    status_line = lines.shift
    status_fields = status_line.scan(/([^\\]+)\\([^\\]*)/)
    status = {}
    status_fields.each {|key, val| status[key] = val }
    # remaining lines are player status, but don't care about that at present
    ServerState.new(status)
  end

  protected

  def expect_another_rcon_packet(is_status, recv_seq, packet_data)
    need_another_status = is_status && recv_seq == 0 && packet_data !~ REGEX_RCON_STATUS_SEQ0
    need_another_status || packet_data.length >= RCON_MAYBE_MULTIPLE_THRESH
  end
  
  def sort_rcon_status_packets(pkbuf)
    pkbuf = pkbuf.sort_by {|p| (p =~ REGEX_RCON_STATUS_ROW) ? $1.to_i : 999 }

 # $stderr.puts "=========== #{pkbuf.length} SORTED STATUS PACKETS:\n#{pkbuf.join}" if pkbuf.length > 1
 
    pkbuf
  end
  
  def q2recv(sock)
    resp = nil
    begin
      if select([sock], nil, nil, UDP_RECV_TIMEOUT)
        begin
          # note, some linux kernel versions will select() positive for a UDP
          # packet, but the packet has a bad checksum, and when we do recvfrom()
          # the packet is thrown out, and we are blocked.  (I think, due to ruby's
          # internals, even though we're setting NONBLOCK here, doesn't help,
          # for some reason... i think this was explained on ruby-talk.)
          # Thus the 'timeout'.
          timeout(0.17) {
            resp = sock.recvfrom(65536)
          }
        rescue Timeout::Error
          $stdout.puts "Q2rcon#q2cmd: Timeout::Error in sock.recvfrom !"
        end
      end
      if resp
        resp = resp[0][4..-1]  # trim leading 0xffffffff
      end
    rescue IOError, SystemCallError
    end
    resp
  end
  
end

