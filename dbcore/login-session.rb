
require 'uri'
require 'dbcore/obj-encode'

module RconLoginSession

  include ObjEncodePrintable

  def session_init(client, rcon_server, logger)
    @rls_client, @rls_rcon_server, @rls_logger = client, rcon_server, logger
    @rls_idle_since = Time.now
    @rls_q2t = nil
    sock_domain, @rls_port, @rls_ipname, @rls_ip = peeraddr
    @rls_client.set_prompt("")
    @rls_client.con_puts("#{DorkBusterName} #{DorkBusterVersion}")
    session_reset_to_login
  end

  def session_final
  end

  def session_client_input(line)
    @rls_idle_since = Time.now
    case @rls_state
      when :login  then session_handle_login(line)
      when :passwd then session_handle_passwd(line)
      when :shell  then session_handle_shell(line)
    end
  rescue Exception => ex
    $stderr.puts "**** Caught exception in session_client_input: #{ex.inspect}"
  end

  def session_user; @rls_user; end
  def session_ip; @rls_ip; end
  def session_port; @rls_port; end
  def session_idle_since; @rls_idle_since; end
  def q2t; @rls_q2t; end

  def session_username
    @rls_user ? @rls_user.username : "never-logged-in"
  end

  def session_active
    @rls_user && (@rls_state == :shell)
  end

  def session_reset_to_login
    @rls_client.set_windowed_mode(false)
    @rls_state = :login
    @rls_user = nil
    @rls_username_attempt = nil
    @rls_q2t = nil
    @rls_client.set_prompt("login:")
  end

  def session_show_recent_log_hist(num = 0)
    num = (num < 1)? 25 : num
    @rls_client.con_puts(SepBar)
    lines = @rls_logger.recent_log_hist(num)
    lines.each {|line| @rls_client.con_puts(line) }
    # @rls_client.con_puts(SepBar)
  end

  private
  
  def session_handle_login(line)
    unless line =~ /\A\s*\z/
      @rls_username_attempt = line
      @rls_logger.log(%Q<[Dork Buster: user "#{@rls_username_attempt}" (#{@rls_ip}:#{@rls_port}) attempting login]>)
      @rls_client.set_prompt("passwd:")
      @rls_client.set_echo(false)
      @rls_state = :passwd
    end
  end

  def session_handle_passwd(line)
    pass_plain = line
    user = DorkBusterUserDatabase.match_user(@rls_username_attempt, pass_plain)
    if user
      @rls_logger.log(%Q<[Dork Buster: user "#{user.username}" (#{@rls_ip}:#{@rls_port}) logged in successfully]>)
      @rls_user = user
      session_login_init_q2t
      session_set_shell_prompt
      @rls_client.con_puts("\n\nWelcome, #{session_username}.\n")
      if false  # not @rls_user.is_ai
        @rls_client.con_puts("Recent log history:")
        session_show_recent_log_hist
        msg = `fortune -s`.gsub(/\n/, " ") rescue "Fortune cookie say: `fortune` program not found."
        $stdout.puts "greeting #{session_username} with fortune: #{msg}"
        @rls_client.con_puts(ANSI.dbwarn("System Message: #{msg}"))
        @rls_client.con_puts(ANSI.colorize("To try the windowed mode, type: @win on", [ANSI::Bright, ANSI::Yellow, ANSI::BGBlack].join(";")));
        @rls_client.con_puts(ANSI.colorize("ATTENTION TERA-TERM USERS... PLEASE DOWNLOAD THE NEW TERA-TERM ON quake2@tastyspleen.net:/ttermpro-colorfix... It is a patch to fix TeraTerm's broken handling of background color attributes, and is needed for the windowed mode to work properly.", [ANSI::Bright, ANSI::Red, ANSI::BGBlack].join(";")));
      end
      @rls_state = :shell
    else
      @rls_logger.log(ANSI.dbwarn(%Q<[Dork Buster: user "#{@rls_username_attempt}" (#{@rls_ip}:#{@rls_port}) bad username or password]>))
      @rls_client.con_puts("\nbad username or password")
      @rls_client.set_prompt("login:")
      @rls_state = :login
    end
    @rls_client.set_echo(true)
    @rls_username_attempt = nil
  end

  def session_login_init_q2t
    @rls_q2t = SillyQ2TextModeClient.new(session_username, session_user.gender)
  end

  def session_handle_shell(line)
    # Bots are allowed to send uri-encoded lines prefixed with /x
    # This is the only way to send Q2 conchar special characters,
    # as the terminal input handler normally strips control chars
    # and high-bit chars.
    if (@rls_user.is_ai || @rls_user.is_db_devel) && (line =~ %r{\A/x\s+(.*)\z})
      line = URI.unescape($1)
    end
    if (line =~ /\A\s*(\S+)\s*(.*)\z/)
      cmd, args = $1, $2
      begin
        session_handle_shell_cmd(cmd, args, line)
      rescue Interrupt, NoMemoryError, SystemExit
        raise
      rescue Exception => ex
        @rls_client.con_puts "Exception #{ex.inspect} handling line: #{line}\n#{ex.backtrace}"
      end
    end
  end

  def session_set_shell_prompt
    prompter = Proc.new do
      server = @rls_rcon_server.server_nickname
      map = @rls_rcon_server.game_state.server_state['mapname']
      nclients = @rls_rcon_server.game_state.active_clients.length
      "#{session_username}@#{server}/#{map}/#{nclients}>"
    end
    @rls_client.set_prompt(prompter)
  end

  def session_who
    clients = @rls_rcon_server.active_clients
    @rls_client.con_puts("name---------------- ip------------- idle----------------")
    clients.each do |cl|
      name = cl.session_username
      idle_sec = (Time.now - cl.session_idle_since).to_i
      idle = "#{idle_sec / 60} min, #{idle_sec % 60} sec"
      @rls_client.con_puts(sprintf("%-20s %-15s %s ", name, cl.session_ip.to_s, idle))
    end
  end

  def session_rcon_client(cmd)
    if (cmd =~ /\A\s*(\d+)\s*(.*)\z/)
      cl_num, rcmd = $1.to_i, $2
      cl = @rls_rcon_server.game_state.client_state[cl_num]
      if cl
        @rls_rcon_server.rcon_client(rcmd, cl)
      else
        @rls_logger.log(ANSI.dbwarn("[Dork Buster: client #{cl_num} not active in database - rcon cmd not sent]"))
      end
    else
      @rls_logger.log(ANSI.dbwarn("[Dork Buster: couldn't parse client num from '#{cmd}' - rcon cmd not sent]"))
    end
  end

  def session_show_known_names(args)
    @rls_client.con_puts(ANSI.dbwarn("[Dork Buster: the 'names' search isn't ported to the new database yet, please try 'ips' instead]"))
    
    # if args.strip.empty?
    #   @rls_client.con_puts(ANSI.dbwarn("[Dork Buster: please specify a search string]"))
    # else
    #   names_list = @rls_rcon_server.game_state.known_names_with_ips
    #   @rls_client.con_puts(session_filter_str_for_args(names_list, args).chomp)
    # end
  end

  def session_show_known_ips(args)
    if args.strip.empty?
      @rls_client.con_puts(ANSI.dbwarn("[Dork Buster: please specify a search string]"))
    else
      result = @rls_rcon_server.game_state.playerseen_grep(args)
      @rls_client.con_puts(result)
      
      # ips_list = @rls_rcon_server.game_state.known_ips_with_names
      # @rls_client.con_puts(session_filter_str_for_args(ips_list, args).chomp)
    end
  end

  def session_show_known_ports(args)
    txt = ""
    $server_list.each do |sv|
      txt << sprintf("%15s %30s %30s\n", sv.nick, "#{sv.dbip}:#{sv.dbport}", "#{sv.gameip}:#{sv.gameport}")
    end
    @rls_client.con_puts(session_filter_str_for_args(txt, args).chomp)
  end

  def session_top_frags(args)
    args = args.split(/\s+/)
    dbname = args.delete("daily") || args.delete("monthly") || args.delete("alltime") || "daily"
    args.map! {|x| (x == "*") ? nil : x}
    inflictor, victim, method_str, servername = *args
    result = @rls_rcon_server.game_state.top_frags(dbname, inflictor.to_s, victim.to_s, method_str.to_s, servername.to_s)
    @rls_client.con_puts(result)
  end

  def session_top_suicides(args)
    args = args.split(/\s+/)
    dbname = args.delete("daily") || args.delete("monthly") || args.delete("alltime") || "daily"
    args.map! {|x| (x == "*") ? nil : x}
    victim, method_str, servername = *args
    result = @rls_rcon_server.game_state.top_suicides(dbname, victim.to_s, method_str.to_s, servername.to_s)
    @rls_client.con_puts(result)
  end

  def session_filter_str_for_args(str, args)
    if (args !~ /\A\s*\z/)
      rx = session_args_to_alternating_regexp(args)
      str = str.grep(rx).join
    end
    str
  end

  def session_args_to_alternating_regexp(args)
    Regexp.new(args.split(/\s+/).collect {|s| Regexp.escape(s) }.join("|"), Regexp::IGNORECASE)
  end

  def session_host_lookup(args)
    args.strip!
    if args !~ /\A\d+\.\d+\.\d+\.\d+\z/
      @rls_client.con_puts(ANSI.dbwarn("[Dork Buster: please specify an IP address to lookup]"))
    else
      begin
        # result = Socket.gethostbyname(args)
	result = Socket.getnameinfo( Socket.pack_sockaddr_in(0, args) )
        raise "DNS lookup failed for IP address '#{args}'" unless result && !result.first.to_s.empty?
        hostname = result.first
        @rls_logger.log(hostname)
      rescue StandardError => ex
        @rls_logger.log(ANSI.dbwarn("ERROR: #{ex.message}"))
      end
    end
  end

  def session_kick(args)
    args = session_username_for_me(args)
    clients = @rls_rcon_server.get_db_clients_by_name(args)
    clients.each do |cl|
      if cl.stream_enabled
        @rls_logger.log(ANSI.dbwarn("[Dork Buster: won't kick streaming client]"))
      else
        @rls_logger.log(ANSI.dbwarn("[Dork Buster: #{cl.session_username} was kicked]"))
        cl.session_reset_to_login
      end
    end
    @rls_rcon_server.silly_q2t.kick_imaginary_player(args)
  end

  def session_respawn
    if q2t.dead?
      q2t.spawn
      @rls_logger.log(ANSI.sillyq2("#{session_username} joined the game."))
    end
  end

  def session_shoot(args)
    args = session_username_for_me(args)
    q2t.dead? ? session_respawn : @rls_rcon_server.silly_q2t.shoot(q2t, args)
  end

  def session_use(args)
    session_respawn
    @rls_rcon_server.silly_q2t.use(q2t, args)
  end

  def session_username_for_me(str)
    str.gsub(/\A\s*(me|myself)\s*\z/i, session_username)
  end

  def session_dmflags(args)
    orig_dmflags = (@rls_rcon_server.game_state.server_state['dmflags'] || 0).to_i
    dmflags = DmFlags.alter(orig_dmflags, args, @rls_logger)
    DmFlags.show(dmflags, @rls_logger) unless @rls_user.is_ai
    if dmflags != orig_dmflags
      @rls_rcon_server.rcon_cmd("dmflags #{dmflags}") do |resp|
        @rls_rcon_server.game_state.server_state['dmflags'] = dmflags.to_s if resp
      end
    end
  end

  def session_wallfly(args)
    case args.strip
      when "start"            then @rls_rcon_server.wallfly_start
      when "stop"             then @rls_rcon_server.wallfly_stop
      else
        @rls_logger.log(ANSI.dbwarn("[Dork Buster: wallfly: please specify start or stop]"))
    end
  end

  def session_wallfly_chatlevel(args)
    case args.strip
      when "on"               then @rls_rcon_server.wallfly_set_chatlevel(true)
      when "off"              then @rls_rcon_server.wallfly_set_chatlevel(false)
      else
        @rls_logger.log(ANSI.dbwarn("[Dork Buster: chat: please specify on or off]"))
    end
  end

# search params need to and, not 'or' in chatlog
  
  def session_wallfly_chatlog(args)
    default_num_lines = "25"
    args = args.split
    use_regex = args.delete "-x"
    num_lines, *keywords = *args
    num_lines ||= default_num_lines
    if num_lines !~ /\A\d+\z/
      keywords.unshift num_lines  # non-number, assume keyword
      num_lines = default_num_lines
    end
    keywords.map! {|kw| Regexp.quote(kw)} unless use_regex
    begin
      keyword_regexen = keywords.map {|kw| Regexp.new(kw, Regexp::IGNORECASE) }
    rescue StandardError => ex
      @rls_client.con_puts(ANSI.dberr("Error compiling regexp: #{ex}"))
      return
    end
    keyword_search = keyword_regexen.length > 0
    num_lines = num_lines.to_i
    num_lines = 9999 if num_lines > 9999  # sanity check
    lines = @rls_rcon_server.wallfly_logtail(num_lines)
    if keyword_search
      lines = lines.select do |line|
        matches = keyword_regexen.select {|rx| line =~ rx }
        matches.length == keyword_regexen.length
      end    
    end
    @rls_client.con_puts(lines.join("\n"))
  end

  def session_dump_client(cl_num)
    @rls_rcon_server.rcon_cmd("dumpuser #{cl_num}")
  end

  def session_windowed_mode(args)
    case args.strip
      when "on"               then @rls_client.set_windowed_mode(true)
      when "off"              then @rls_client.set_windowed_mode(false)
      when "stream"           then @rls_client.set_windowed_mode(:stream)
      else
        @rls_client.con_puts(ANSI.dbwarn("[Dork Buster: please specify on, off, or stream]"))
    end
  end

  def session_chat_colorize(str, base_color=ANSI::Chat)
    str = ANSI.colorize(str, base_color) if base_color
    str.gsub!(/\^([0-9A-Fa-f^])/) do
      ch = $1
      if ch == "^"
        ch
      else
        cnum = ch.to_i(16)
        cnum -= 8 if (bright = cnum > 7)
        colors = bright ? [ANSI::BGBlack, ANSI::Bright] : [ANSI::Reset]
        colors += [ (ANSI::Black.to_i + cnum).to_s ]
        # $stderr.puts "chat_colorize: ch(#{ch}) cnum(#{cnum}) bright(#{bright}) "+colors.inspect
        ANSI.color(*colors)
      end
    end
    str
  end

  def session_privmsg(argstr)
    target, msg = argstr.split(/\s+/, 2)
    if !target || target.empty?
      @rls_client.chat_puts(ANSI.dbwarn("[Dork Buster: please give client name and private message]"))
      return
    end
    clients = @rls_rcon_server.get_db_clients_by_name(target)
    if clients.empty?
      @rls_client.chat_puts(ANSI.dbwarn(%{[Dork Buster: client named "#{target}" not found]}))
    else
      msg = "(#{session_username} to #{target}): #{msg}"
      msg = session_chat_colorize(msg, ANSI::Privmsg)
      
      @rls_client.chat_puts(msg)
      clients.each do |cl|
        next if cl == @rls_client
        cl.chat_puts(msg)
      end
    end
  end

  def session_chsv(argstr)
    server, port, rcon_pw = argstr.split(/\s+/, 3)
    unless server && port && rcon_pw
       @rls_client.chat_puts(ANSI.dbwarn("[Dork Buster: please specify: server port rcon_password]"))
      return
    end
    @rls_rcon_server.chsv(server, port.to_i, rcon_pw)
  end
  
  def session_send_status_obj
    status_obj = {
      "server_state" => @rls_rcon_server.game_state.server_state,
      "client_state" => @rls_rcon_server.game_state.client_state,
      "status"       => @rls_rcon_server.game_state.status
    }
    statenc = obj_encode_with_label("STATUS", status_obj)
    @rls_client.con_puts(statenc)
  end

  def sanitize_for_rcon(str)
    str.tr("$\"\\", ".")
  end

  ### BEGIN: q2admin-specific commands #######################################

  def session_wallfly_say(argstr)
    msg = argstr
    @rls_rcon_server.rcon_cmd("sv !stuff LIKE WallFly[BZZZ] say #{msg}")
  end

  def session_client_sayver(args)
    sayver_str = %{sv !stuff cl $num alias sayver \\"say_person like WallFly $version - $g_select_empty - $sw_stipplealpha\\" ; sayver}
    if args =~ /\A\s*all\s*\z/
      @rls_rcon_server.rcon_all_clients(sayver_str)
    elsif args =~ /\A\s*(\d+)\s*\z/
      session_rcon_client("#$1 #{sayver_str}")
    else
      @rls_logger.log(ANSI.dbwarn("[Dork Buster: please give client number (or 'all')  for sayver]"))
    end
  end

  def session_stuff_client(cl_num, cmd)
    session_rcon_client("#{cl_num} sv !stuff cl $num #{cmd}")
  end

  def session_stuff_all(cmd)
    @rls_rcon_server.rcon_all_clients("sv !stuff cl $num #{cmd}")
  end

  def session_mute_player(argstr)
    if argstr =~ /\A\s*(\d+)(?:\s+(\d+))?\s*\z/
      cl_num = $1
      secs = $2 || "PERM"
      @rls_rcon_server.rcon_cmd("sv !mute CL #{cl_num} #{secs}")
    else
      @rls_logger.log(ANSI.dbwarn("[Dork Buster: please give client number and number of seconds (0 to unmute)]"))
    end
  end

  def session_privmsg_player(admin_name, argstr)
    if argstr =~ /\A\s*(\d+)\s+(\S.*)\z/
      cl_num, msg = $1, $2
      @rls_rcon_server.rcon_cmd("sv !say_person CL #{cl_num} from #{admin_name}: #{msg}")
    else
      @rls_logger.log(ANSI.dbwarn("[Dork Buster: please specify client number and message]"))
    end
  end

  def session_show_aliases(argstr)
    args = argstr.split(/\s+/)
    aliases_list = @rls_rcon_server.gamestate_top_aliases
    aliases_list << "No players found." if aliases_list.empty?
    usage_str = "[Dork Buster: specify 'console' or client number for public display, or no arguments for local-only display]"
    if args.length > 1
      @rls_logger.log(ANSI.dbwarn(usage_str))
    elsif args.empty?
      aliases_list.each {|line| @rls_logger.log(line)}
    elsif args.first == "console"
      # aliases_list = ["a:b", "c:d"]
      aliases_list.each {|line| @rls_rcon_server.rcon_cmd("say #{sanitize_for_rcon(line)}")}
    elsif args.first =~ /\A[0-9]+\z/
      cl_num = args.first.to_i
      aliases_list.each {|line| @rls_rcon_server.rcon_cmd("sv !say_person CL #{cl_num} from console: #{sanitize_for_rcon(line)}")}
    else
      @rls_logger.log(ANSI.dbwarn(usage_str))
    end
  end

  ### END: q2admin-specific commands #########################################

  def session_require_devel(cmdname)
    if session_user.is_db_devel
      yield if block_given?
    else
      @rls_logger.log(ANSI.dberr("[Dork Buster: developer permission required for #{cmdname}]"))
    end
  end

  def session_auth_rcon(cmd)
    if false  # @rls_user.is_ai  &&  (cmd =~ /quit|map/i)  &&  (session_ip.to_s =~ /123\.456/)
      @rls_logger.log(ANSI.dberr("[Dork Buster: rcon permission denied for '#{cmd}']"))
    else
      yield if block_given?
    end
  end

  def massage_guest_input(cmd, line)
    unless cmd.strip =~ /\A(chatlog|ips|logout|\/msg|status|w|@win)\z/
      cmd = "...#{cmd}"
      line = "...#{line}"
    end
    [cmd, line]
  end
  
  def session_handle_shell_cmd(cmd, args, line)
    # no_log = (cmd =~ /\A(@.*|chatlog|help|ips|log|names|timerefresh|top_frags|top_suicides|w)\z/)

    if session_user.is_guest
      cmd, line = massage_guest_input(cmd, line)
    end

    user_cmd_str = "#{session_username}: #{line}"
    out = Proc.new {|color| @rls_logger.log(ANSI.colorize(user_cmd_str, color)) }
    dbcmd = Proc.new {out.call(ANSI::DBCmd)}
    sillyq2 = Proc.new {out.call(ANSI::SillyQ2)}
    chat = Proc.new {@rls_logger.log(session_chat_colorize(user_cmd_str))}
    rccmd = Proc.new {
      # if (! @rls_user.is_ai)  ||  cmd == "!all"  ||  cmd == "rcon_all_clients"  ||  args =~ /\b(exec|map|gamemap|kick|addip|addhole)\b/
        out.call(ANSI::DBCmd)
      # end
    }

    case cmd
      when "chat"             then dbcmd.call;   session_wallfly_chatlevel(args)
      when "chatlog"          then               session_wallfly_chatlog(args)
      when "@chsv"            then               session_require_devel(cmd) { session_chsv(args) }
      when "dmflags"          then rccmd.call;   session_dmflags(args)
      when "help"             then               session_show_help
      when "/host"            then dbcmd.call;   session_host_lookup(args)
      when "ips"              then               session_show_known_ips(args)
      when "kick"             then dbcmd.call;   session_kick(args)
      when "kill"             then sillyq2.call; @rls_rcon_server.silly_q2t.kill(q2t)
      when ">log"             then               @rls_logger.log(session_chat_colorize("#{session_username}: #{args}"))
      when "log"              then               session_show_recent_log_hist(args.to_i)
      when "logout"           then dbcmd.call;   @rls_rcon_server.disconnect_client(self)
      when "/msg"             then               session_privmsg(args)
      when "/mute"            then rccmd.call;   session_mute_player(args)
      when "names"            then               session_show_known_names(args)
      when "/ports"           then               session_show_known_ports(args)
      when "reload_dbcore"    then dbcmd.call;   session_require_devel(cmd) { @rls_rcon_server.reload_dbcore(args.split) }
      when "reload_dbmod"     then dbcmd.call;   session_require_devel(cmd) { @rls_rcon_server.reload_dbmod(args.split) }
      when "rcon"             then rccmd.call;   session_auth_rcon(args) { @rls_rcon_server.rcon_cmd(args) }
      when "rcon_client"      then rccmd.call;   session_auth_rcon(args) { session_rcon_client(args) }
      when "rcon_all_clients" then rccmd.call;   session_auth_rcon(args) { @rls_rcon_server.rcon_all_clients(args) }
      when "respawn"          then sillyq2.call; session_respawn
      when "/say"             then rccmd.call;   session_privmsg_player(session_username, args)
      when "say_anon"         then msg = session_chat_colorize("anon: #{args}"); @rls_logger.log(msg); @rls_logger.chat(msg)
      when "say_green"        then msg = session_chat_colorize("mrgreen: #{args}"); @rls_logger.log(msg); @rls_logger.chat(msg)
      when "score"            then sillyq2.call; @rls_rcon_server.silly_q2t.display_scores
      when "/send_status_obj" then               session_send_status_obj
      when "shoot"            then sillyq2.call; session_shoot(args)
      when "show_aliases"     then rccmd.call;   session_show_aliases(args)
      when "shutdown_db!"     then dbcmd.call;   session_require_devel(cmd) { @rls_rcon_server.shutdown! }
      when "status"           then dbcmd.call;   @rls_rcon_server.gamestate_status
      when "/tell"            then rccmd.call;   session_privmsg_player("console", args)
      when "timerefresh"      then               session_timerefresh
      when "top_frags"        then               session_top_frags(args)
      when "top_suicides"     then               session_top_suicides(args)
      when "use"              then sillyq2.call; session_use(args)
      when "w"                then               session_who
      when "wallfly"          then dbcmd.call;   session_wallfly(args)
      when "/wf"              then rccmd.call;   session_wallfly_say(args)
      when "@win"             then               session_windowed_mode(args)
      when /\A\?(\d+)\z/      then dbcmd.call;   session_dump_client($1.to_i)
      # q2admin-speficic commands:               
      when "sayver"           then rccmd.call;   session_client_sayver(args)
      when "!all"             then rccmd.call;   session_stuff_all(args)
      when /\A!(\d+)\z/       then rccmd.call;   session_stuff_client($1.to_i, args)
      else                         chat.call;    @rls_logger.chat(session_chat_colorize(user_cmd_str))
    end
  end

  def session_show_help
    text = <<"EOT"
-- #{DorkBusterName} #{DorkBusterVersion} Commands ---------------------------------------
 [RCON COMMANDS]
  dmflags                 Alter/show dmflags by name
  /mute 12 120            Mute client 12 for 120 seconds. ("PERM" if seconds not given.)
                          Use 0 seconds to unmute.
  rcon some-command       Execute "some-command" as rcon on target server
  rcon_client cl cmd      Execute "cmd" as rcon with variable-substitution
                          on client number "cl"'s info, such as
                          $num, $name, $ping, $score, $ip, $port...
  rcon_all_clients cmd    Execute "cmd" as rcon with variable-substitution
                          for EACH client!
  sayver 12               Echo client 12 version to WallFly [Q2Admin-specific]
  status                  Like "rcon status" but with player aka's
  ?12                     Short for rcon dumpuser 12
  !all cmd                Stuff cmd to all clients [Q2Admin-specific]
  !12 cmd                 Stuff cmd to client 12 (for example) [Q2Admin-specific]

 [IN-GAME CHAT CONTROL]
  chat on/off             Turn on/off full in-game chat text from wallfly
  chatlog nnn keywords    Display last nnn lines from chat log, filtered by keywords
  wallfly start/stop      Connect/disconnect wallfly client from server

 [PLAYER DATABASE QUERIES]
  ips search_string       Show known player ips and corresponding names
  names search_string     Show known player names and corresponding ips
  top_frags    [daily|monthly|alltime] inflictor victim weapon servername
  top_suicides [daily|monthly|alltime] victim weapon servername
                          (Any column can be __total__ or *)

 [DORKBUSTER USER COMMANDS]
  help                    This help text
  /host 12.34.56.78       Lookup DNS hostname for IP address
  kick name               Kick *dorkbuster* user (not quake client)
  log nnn                 Print recent nnn lines of history (default = 25)
  logout                  Disconnect from dorkbuster
  /msg name msg           Send private message to dorkbuster user [not logged by db]
  /ports                  List known dorkbuster and quake server ports
  reload_dbcore           dorkbuster developer command [DANGER]
  reload_dbmod            dorkbuster admin maintenance command
  /say 13 hello           Tells client 13 hello FROM YOUR ADMIN NAME
  say_anon msg            Says, in dorkbuster only: anon: msg
  say_green msg           Says, in dorkbuster only: mrgreen: msg
  shutdown_db!            Cause dorkbuster to quit
  /tell 13 hello          Tells client 13 hello from "conosole"
  w                       Display active dorkbuster logins
  /wf message             Say message through WallFly[BZZZ]
  @win on/off             Enable/disable windowed mode

 [DORKBUSTER SILLY TEXT-MODE GAME COMMANDS]
  kill                    Kill self in text-mode quake
  respawn                 Respawn self in text-mode quake
  score                   Score display in text-mode quake
  shoot name              Shoot someone in text-mode quake
  timerefresh             Silly text-mode timerefresh
  use weapname            Use weapon in text-mode quake
-------------------------------------------------------------------------------
EOT
    @rls_client.con_puts(text.chomp)
  end

end


