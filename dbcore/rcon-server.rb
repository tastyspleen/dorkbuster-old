
require 'thread'
require 'fastthread'
require 'dbcore/recursive-mutex'
require 'dbcore/global-signal'
require 'dbcore/dbclient'
require 'dbcore/obj-encode'
require 'dbmod/obit_parse_q2'

class RconQueue
  CMD_RCON          = :rcon
  CMD_RCON_STATUS   = :rcon_status
  CMD_PUBLIC_STATUS = :public_status

  def initialize(rcon, global_signal)
    @rcon, @global_signal = rcon, global_signal
    @rcon_queue = Queue.new
    @reply_queue = Queue.new
    @rcon_th = Thread.new { rcon_thread }
  end

  def close
    @rcon_th.kill
  end

  def rcon(cmd_str, &post_proc)
    @rcon_queue.push [CMD_RCON, post_proc, cmd_str]
  end

  def rcon_status(&post_proc)
    @rcon_queue.push [CMD_RCON_STATUS, post_proc]
  end

  def public_status(&post_proc)
    @rcon_queue.push [CMD_PUBLIC_STATUS, post_proc]
  end

  def process_results
    while not @reply_queue.empty?
      envelope = @reply_queue.pop
      cmd, post_proc, result = *envelope
      post_proc.call(result) if post_proc
    end
  end

  def rcon_thread
    loop do
      begin
        envelope = @rcon_queue.pop
        cmd, post_proc, *args = envelope
        result = nil
        case cmd
          when CMD_RCON           then result = @rcon.rcon(*args)
          when CMD_RCON_STATUS    then result = @rcon.rcon_status
          when CMD_PUBLIC_STATUS  then result = @rcon.public_status
        end
        @reply_queue.push [cmd, post_proc, result]
        @global_signal.signal
      rescue Exception => ex
        $stderr.puts "RconQueue::rcon_thread: caught exception: #{ex.inspect}"
      end
    end
  end
end


# $errlog = Object.new
# def $errlog.log(*args)
#   nick = ENV['DORKBUSTER_SERVER_NICK']
#   if nick == "vanilla"
#     t = Time.now
#     frac = ((t.to_f - t.to_i) * 1000).round
#     File.open("db-error.log", "a") {|f| f.puts "[#{t}.#{frac}][#{nick}] #{args}"}
#   end
# end


# if false
# $last_trace_time = Time.at(0)
# $trace_hist = []
# set_trace_func proc {|event, file, line, id, binding, classname|
#   trace_str = sprintf( "%8s %s:%-2d %10s %8s", event, file, line, id, classname )
#   $trace_hist.push(trace_str)
#   $trace_hist.shift while $trace_hist.length > 5
#   now = Time.now
#   delta = now - $last_trace_time
#   $last_trace_time = now
#   if delta > 0.5
#     $trace_hist.each {|l| $errlog.log(l)}
#     # $trace_hist.each {|l| puts(l)}
#     $trace_hist.clear
#   end
# }
# end

# set_trace_func nil


# $bg_print_thread.kill if $bg_print_thread
# $bg_print_thread = Thread.new { loop{ $errlog.log("bg_print_thread"); sleep(0.1) } }
# $bg_print_thread.priority = 10




class RconServer

  include ObjEncodePrintable

  StatusPollInterval = 5 # seconds interval to poll quake server for status
  StaleStatusPollInterval = (60 * 5) # seconds interval to poll when server not responding
  GamestateStaleThresh = 60 # seconds until gamestate considered stale
  WallflyUpdateInterval = 0.25 # seconds interval to poll for wallfly data
  RconWallflyVerboseDuration = 3 # seconds of "chat on" after any rcon command issued (to catch disconnects and such)
  TimeoutEpsilon = 0.05 # seconds extra since select seems to return slightly early sometimes
  LogHistSize = 1000

  attr_reader :game_state, :log_hist, :rcon, :server_nickname, :silly_q2t

  def initialize(server_nickname, rcon_password, server_addr, server_port = 27910, local_port = 27999)
    @server_nickname, @local_port, @rcon_password = server_nickname, local_port, rcon_password
    live_reinit
    IPSocket.do_not_reverse_lookup = true
    @mutex = RecursiveMutex.new
    @global_signal = GlobalSignal.new
    server_ip = get_ip_for_hostname(server_addr)
    @rcon = Q2rcon.new(rcon_password, server_ip, server_port)
    @rcon_queue = nil
    @last_rcon_cmd_time = Time.at(0)
    @wfly = Wallfly.new(server_ip, server_port, "sv/#@server_nickname/wallfly.log")
    @wfly_enable = true
    @wfly_verbose = true
    @log_filename = "sv/#@server_nickname/db.log"
    @log_hist = []
    @log_file = nil
    @tcp_server = nil
    @tcp_clients = []
    @new_tcp_clients = []
    @silly_q2t = SillyQ2TextMode.new(self, self)
    @game_state = nil
  end

  def live_reinit
  end

  def get_ip_for_hostname(hostname)
    if hostname =~ /\A\d+\.\d+\.\d+\.\d+\z/
      ip = hostname  # already an IP
    else
      info = Socket.gethostbyname(hostname)
      raise "gethostbyname(#{hostname}) failed" unless info
      raw_ip = info[3]
      ip = raw_ip.split(//).map{|c| c[0]}.join(".")
    end
  end

  def new_rcon_passwd(passwd)
    @rcon_password = passwd
    @rcon.instance_eval { @rcon_password = passwd }
    @rcon_queue = RconQueue.new(@rcon, @global_signal)
  end

  def chsv(server_addr, server_port, rcon_password)
    server_ip = get_ip_for_hostname(server_addr) rescue nil
    if server_ip
      @wfly.stop
      @rcon_password = rcon_password
      @rcon = Q2rcon.new(rcon_password, server_addr, server_port)
      @rcon_queue = RconQueue.new(@rcon, @global_signal)
      @wfly = Wallfly.new(server_addr, server_port, "#{@server_nickname}/wallfly.log")
      @wfly.start if @wfly_enable
    else
      log(ANSI.dberr("chsv: get_ip_for_hostname(#{server_addr}) failed"))
    end
  end
  
  def run
    @shutdown = false
    @log_file = File.open(@log_filename, File::WRONLY | File::CREAT | File::APPEND)
    @log_file.sync = true
    @rcon_queue = RconQueue.new(@rcon, @global_signal)
    @game_state = GameStateDB.new(self, @server_nickname)
    mark_gamestate_fresh
    mark_gamestate_dirty
    @wfly.start 
 # $stderr.puts "[[[[[[[[[[wallfly.start disabled]]]]]]]]]]"
    @tcp_server = TCPServer.new(@local_port)
    accept_th = Thread.new { background_accept_clients }
    log(SepBar, "")
    log("[#{DorkBusterName} #{DorkBusterVersion} start on #{Socket.gethostname}:#{@local_port} " + Time.now.strftime("%a %d/%m/%Y]"))
    begin
      next_update = Time.now
      until @shutdown
        next_update = process_all(next_update)
      end
    rescue Interrupt, IRB::Abort, NoMemoryError, SystemExit => ex
      puts "Caught exception: #{ex.inspect} at #{ex.backtrace[0]} - saving and shutting down..."
    rescue Exception => ex
      puts "Caught exception: #{ex} at #{ex.backtrace[0]} - ignoring and continuing..."
      puts ex.backtrace
      sleep 1
      retry
    ensure
      log(ANSI.dbwarn("[#{DorkBusterName} #{DorkBusterVersion} terminating...]"))
      @rcon_queue.close
      accept_th.kill
      disconnect_all_clients
      log(SepBar, "")
      @wfly.stop
      @tcp_server.close; @tcp_server = nil
      @log_file.close; @log_file = nil
      @game_state.close; @game_state = nil
    end
  end

  def process_all(next_update)
    begin
      do_process_all(next_update)
    rescue Exception => ex
      msg = "[Dork Buster: exception: #{ex.message} at #{ex.backtrace[0]}]"
      log(ANSI.dberr(msg))
      raise
    end
  end

  def do_process_all(next_update)
    Thread.current.priority = 100
    next_update = Time.now if  ! gamestate_stale  &&  ((next_update - Time.now) > StatusPollInterval)
    if ((next_update - Time.now) <= 0) || @gamestate_dirty
      update_server_client_state
      next_update = Time.now + (gamestate_stale ? StaleStatusPollInterval : StatusPollInterval)
      @gamestate_dirty = false
    end
    timeout = [next_update - Time.now, WallflyUpdateInterval, @silly_q2t.secs_to_next_npc_action].min
    timeout = [0, timeout].max + TimeoutEpsilon
    process_clients(timeout)
    @rcon_queue.process_results
    wallfly_update
    @silly_q2t.run_npcs
    next_update
  end

  def log(msg, stamp = Time.now.strftime("%H:%M:%S "))
    msg = stamp + msg
    msg_noansi = ANSI.strip(msg)
    @mutex.synchronize {
      puts msg_noansi
      @log_hist.unshift msg
      @log_hist.pop while @log_hist.length > LogHistSize
      @log_file.puts(Time.now.strftime("%Y-%m-%d %a ") + msg_noansi) if @log_file
      @tcp_clients.each {|cl| cl.log_puts(msg) if cl.session_user }
    }
  end

  def shutdown!
    @shutdown = true
  end

  def mark_gamestate_dirty
    @gamestate_dirty = true
  end

  def chat(msg, stamp = Time.now.strftime("%H:%M:%S "))
    msg = stamp + msg
    @mutex.synchronize {
      @tcp_clients.each do |cl|
        cl.chat_puts(msg) if cl.session_user && cl.windowed
      end
    }
  end

  def recent_log_hist(num_lines = @log_hist.length)
    @log_hist.reverse[[0,(@log_hist.length - num_lines)].max..-1]
  end

  def disconnect_client(client, farewell = true)
    @tcp_clients.delete client
    log(%Q<[Dork Buster: client "#{client.session_username}" (#{client.session_ip}:#{client.session_port}) disconnected]>)
    if farewell  &&  !client.eof
      client.set_windowed_mode(false)
      client.console.set_prompt("")
      client.log_puts("Goodbye.")
    end
    client.session_final
    client.close
  end

  def disconnect_all_clients
    while @tcp_clients.length > 0
      disconnect_client(@tcp_clients.first)
    end
  end

  def active_clients
    @tcp_clients.select {|cl| cl.session_active }
  end

  def rcon_cmd(cmd, &post_proc)
    @last_rcon_cmd_time = Time.now
    if cmd =~ /\$\s*rcon_password/i
      log(ANSI.dberr("[Dork Buster: SECURITY: rcon command '#{cmd}' suppressed - refuse to request value of rcon_password cvar]"))
      yield nil if block_given?
      return
    end
    @rcon_queue.rcon(cmd) do |resp|
      handle_rcon_response(resp, post_proc, cmd)
    end
  end

  def rcon_client(cmd, cl)
    cl_cmd = cmd.gsub(/\$num(?=\W|\z)/, cl.num.to_s).
                 gsub(/\$score(?=\W|\z)/, cl.score.to_s).
                 gsub(/\$ping(?=\W|\z)/, cl.ping.to_s).
                 gsub(/\$name(?=\W|\z)/, cl.name.to_s).
                 gsub(/\$ip(?=\W|\z)/, cl.ip.to_s).
                 gsub(/\$port(?=\W|\z)/, cl.port.to_s)
    rcon_cmd(cl_cmd)
  end

  def rcon_all_clients(cmd)
    @game_state.client_state.each do |cl|
      next unless cl
      rcon_client(cmd, cl)
    end
  end

  def update_server_client_state
    @rcon_queue.rcon_status do |status|
      if status
        map, client_list = *status
        @game_state.new_client_state(client_list)
        wallfly_restart if gamestate_stale  # KLUDGE: sometimes wallfly goes comatose if server down for awhile
        mark_gamestate_fresh
      else
        warn_gamestate_stale if gamestate_stale
      end
    end

    @rcon_queue.public_status do |server_state|
      if server_state
        @game_state.new_server_state(server_state)
      end
      update_dyn_windows
    end
  end

  def gamestate_status
    update_server_client_state if gamestate_stale   # force immediate update attempt if stale
    warn_gamestate_stale if gamestate_stale
    log(@game_state.status, "")
  end

  def gamestate_top_aliases
    @game_state.top_aliases
  end

  def get_db_clients_by_name(name)
    active_clients.select {|cl| cl.session_username == name }
  end

  def wallfly_start
    @wfly.start
    @wfly_enable = true
  end
  
  def wallfly_stop
    @wfly.stop
    @wfly_enable = false
  end
  
  def wallfly_restart(force=false)
    return unless force || @wfly_enable
    @wfly.stop
    @wfly.start
  end

  def wallfly_set_chatlevel(boolflag)
    @wfly_verbose = boolflag
  end
  
  def wallfly_logtail(num_lines=100)
    @wfly.logtail(num_lines)
  end

  def reload_dbcore(names)
    DBMod.reload_modules("dbcore", names, self)
  end

  def reload_dbmod(names)
    DBMod.reload_modules("dbmod", names, self)
  end  

  private ####################################################################

  def update_dyn_windows
    # status_enc = obj_encode_to_printable(@game_state.status)
    status_lines = @game_state.status.split(/\n/)
    status_info = status_lines.shift
    status_hdr = status_lines.shift
    status_lines.shift
  # status_time_enc = obj_encode_with_label("NEWSTAT", Time.now)

    @mutex.synchronize {
      @tcp_clients.each do |cl|
        next if cl.output_suspend?
        if cl.windowed
          client_update_dyn(cl, status_info, status_hdr, status_lines)
      # elsif cl.stream_enabled
      #   cl.con_puts(status_time_enc)
        end
      end
    }
  end

  def client_update_dyn(cl, status_info, status_hdr, status_lines)
    rgn = cl.info_rgn
    rgn.home_cursor
    rgn.print_erased_clipped(status_info)
    
    rgn = cl.dyn_rgn
    rgn.home_cursor
    rgn.set_color(ANSI::Reset, ANSI::Black, ANSI::BGYellow)
    rgn.print_erased_clipped(status_hdr)
    rgn.set_color(ANSI::Reset)
    status_lines.each do |line|
      break unless rgn.cursor_row < rgn.term_rows
      rgn.cr
      rgn.print_erased_clipped(line)
    end
    if rgn.cursor_row < rgn.term_rows
      rgn.cr
      rgn.cursor_row.upto(rgn.term_rows - 1) do |row|
        rgn.set_cursor_pos(row, 1)
        rgn.print(" ")
        rgn.erase_eol
      end
      rgn.set_color(ANSI::Reset, ANSI::Black, ANSI::BGYellow)
      rgn.set_cursor_pos(rgn.term_rows, 1)
      rgn.clear_down
    end
        
    cl.input_rgn.focus
  end

  def wallfly_update
    if @wfly_enable  &&  @wfly.eof
      log(ANSI.dbwarn("[Dork Buster: wallfly: process exited, restarting...]"))
      wallfly_restart
    end
    lines = @wfly.read
    lines.each do |line|
      if line !~ /\A\d=/  &&  (line =~ /password.+(required|incorrect|invalid)/i  ||  line =~ /Invalid\s+password/i)
        log(ANSI.dbwarn("[Dork Buster: wallfly: password rejected by server, trying to get current password and retry...]"))
        @wfly.stop
        cur_pass = @rcon.rcon("echo $password").to_s.strip
        log(ANSI.dbwarn("[Dork Buster: wallfly: got password: #{cur_pass.inspect}]"))
        ENV['DORKBUSTER_SERVER_PASSWORD'] = cur_pass
        @wfly.start
      end
      if line =~ /\A1=(.*)\z/
        ObitParseQ2.parse_obit_line($1, @game_state)
      end
      # line.gsub!(/([\000-\037])/) {|ch| "^" + (ch[0] + 64).chr }  # escape ctrl chars
      line.gsub!(/([\000-\037])/) {|ch| "*"}  # turn ctrl characters into asterisks so multiline binds may be readable
      line.gsub!(/\A3=W:/, "3=")  # remove leading W: from ra2 world messages
      line.gsub!(/\A3=<(SPEC|RED|BLUE)> /, "3=")  # remove leading annotations from LFire ctf
      line.gsub!(/2=<SPECTATOR> 3=/, "3=")  # remove weird <SPECTATOR> annotation from matchmod server chat
      line.gsub!(/\A3=\[CAMERA\]/, "3=")  # remove leading [CAMERA] from wod-x spectators
      line.gsub!(/\A3=\[DEAD\] /, "3=")  # remove leading [DEAD] (and trailing whitespace) from action q2 spectators
      line.gsub!(/\A3=(.*) \[(Observer|Red|Blue)\]:/, "3=\\1:")  # remove trailing [Observer] etc. from jailbreak
      if line =~ /\A2=(Timelimit|Fraglimit|JailPoint Limit)/
        line << (" " + @game_state.gen_active_clients_str)
      end
      sv_nick = ENV['DORKBUSTER_SERVER_NICK']
      # horrible mod-specific kludge based on sv_nick
      if sv_nick =~ /freeze/i
        line.gsub!(/\A3=(None|Red|Blue|Green|Yellow) /, "3=")  # remove leading annotations from freezetag mod
      end
      mark_gamestate_dirty if line =~ /\A(Dropping.*console kick issued)|(2=.*(connected|entered the game|wimped out and left|changed name to))/  # includes dis/connected
      @game_state.anticipate_disconnect($1||$2) if line =~ /\A(?:Dropping (.*), console kick issued)|(?:2=(.*) (?:disconnected|wimped out and left))/
      @game_state.anticipate_name_change($1,$2) if line =~ /\A2=(.*?) changed name to (.*)/
      is_chat = line[0] == ?3
      cl = is_chat && wallfly_find_client_for_chat_line(line, @game_state)
      line = wallfly_linefilter(line)
      if line && !line.empty?
        line = "* #{line.rstrip}"
        if is_chat
          annotation = cl ? "[#{cl.num}|#{cl.ip}]" : "[?]"
          line = "#{line}          #{annotation}"
        end
        log(ANSI.wallfly(line))
      end
    end
  end

  CL_NAME_MAXLEN = 15

  def wallfly_find_client_for_chat_line(line, game_state)
    best_cl = nil
    if line =~ /\A3=(.*)\z/
      line = $1
      clients = game_state.active_clients
      mm1_cl = find_best_cl_match_for_chat(line[0..(CL_NAME_MAXLEN+2)], clients)
      mm2_cl = if line[0] == ?(
        find_best_cl_match_for_chat(line[1..(CL_NAME_MAXLEN+3)], clients, true)
      end
      best_cl = [mm1_cl, mm2_cl].compact.sort_by {|cl| cl.name.length}.last
    end
    if best_cl
      # check for ambiguity due to spoofing
      duplicates = game_state.clients_for_name(best_cl.name)
      if duplicates.length > 1
        best_cl = nil
        nums = duplicates.map {|cl| cl.num}
        ips = duplicates.map {|cl| cl.ip}
        log(ANSI.dbwarn("[clients #{nums.inspect} have same name #{duplicates.first.name.inspect}, can't isolate IP from #{ips.inspect}]"))
      end
    end
    best_cl
  end

  # NOTE: if multiple clients have the exact same name, this only finds the first one
  def find_best_cl_match_for_chat(line, clients, is_mm2=false)
    best_cl = nil
    clients.each do |cl|
      name = cl.name
      trailing = is_mm2 ? ")" : ""
# log("test: #{line.inspect} index #{name.inspect} trailing #{trailing.inspect} result: #{line.index(name).inspect}")
      if (i = line.index(name))  &&  i.zero?  &&  line =~ %r{\A#{Regexp.quote(name)}\s*#{Regexp.quote(trailing)}: }
        best_cl = cl if best_cl.nil? || (name.length > best_cl.name.length)
      end
    end
# log("best: #{best_cl.inspect}")
    best_cl
  end

  def wallfly_linefilter(line)
    temp_verbose = (Time.now - @last_rcon_cmd_time) <= RconWallflyVerboseDuration
    DBMod.wallfly_linefilter(line, @wfly_verbose || temp_verbose)
  end

  def mark_gamestate_fresh
    @gamestate_freshness = Time.now
  end

  def gamestate_stale
    (Time.now - @gamestate_freshness) >= GamestateStaleThresh
  end

  def warn_gamestate_stale
    stale_secs = (Time.now - @gamestate_freshness).to_i
    log(ANSI.dberr("[Dork Buster: WARNING: Stale GameState.  No server response for #{stale_secs} seconds.]"))
  end

  def background_accept_clients
    loop do
      begin
        ios = select([@tcp_server], nil, nil, nil)
        if ios
          accept_client(@tcp_server)
        end
      rescue Exception => ex  # was: IOError, SystemCallError
        $stderr.puts "background_accept_clients caught exception: #{ex.inspect}"
        $stderr.puts ex.backtrace
      end
    end
  end

  def accept_client(sock)
    client = sock.accept
    if client
      begin
        level = defined?(Socket::SOL_TCP) ? Socket::SOL_TCP : 6
        client.setsockopt(level, Socket::TCP_NODELAY, 1)
        client = DBClient.new(self, self, client, @global_signal)
        log("[Dork Buster: incoming client connection from #{client.session_ip}:#{client.session_port}]")
      rescue IOError, SystemCallError
        client.close
      else
        @mutex.synchronize {
          @new_tcp_clients << client
          @global_signal.signal
        }
      end
    end
  end

  def induct_new_clients
    # Pull new clients accepted by background thread into
    # main client list.
    # Intended to be called from main thread only.
    @mutex.synchronize {
      @tcp_clients += @new_tcp_clients
      @new_tcp_clients = []
    }
  end

  def process_clients(timeout)
    begin
      @global_signal.timed_wait(timeout)
    rescue Timeout::Error
    end
    induct_new_clients
    @tcp_clients.each do |client|
      process_client_input(client)
    end
  end

  def process_client_input(client)
    if client.eof
      disconnect_client(client, false)
    else
      while (line = client.console.readln)
        client.session_client_input(line)
      end
    end
  end

  def handle_rcon_response(resp, post_proc, cmd)    
    if resp
      resp.sub!(/\Aprint\n/, "")
      resp.chomp!
      resp.strip!
      if resp =~ /#{@rcon_password}/
        resp.gsub!(/#{@rcon_password}/, "<!!!RCON_PASSWORD!!!>")
        log(ANSI.dberr("[Dork Buster: SECURITY: rcon command '#{cmd}' response contained rcon_password value - sanitized]"))
      end
      if !resp.empty?  &&  resp !~ /Command sent to client!/
        if resp =~ /no player name matches found/
          resp = "#{cmd}\n#{resp}"
        end
        log(resp, "")
      end
      update_server_client_state if gamestate_stale   # force immediate update attempt if stale
    else
      log(ANSI.dberr("[Dork Buster: WARNING: rcon command '#{cmd}' failed - no response from server - packet lost?]"))
    end
    post_proc.call(resp) if post_proc
  end

end







  # begin
  #   ios = select([@tcp_server, *@tcp_clients], nil, @tcp_clients, timeout)
  #   if ios
  #     # disconnect any clients with errors
  #     ios[2].each {|sock| ios[0].delete(sock); disconnect_client(sock, false) }
  #     # accept new clients or process existing client input
  #     ios[0].each do |sock|
  #       if sock == @tcp_server
  #         accept_client(sock)
  #       else
  #         process_client_input(sock)
  #       end
  #     end
  #   end
  # rescue IOError, SystemCallError
  # end

