#!/usr/bin/env ruby
#
# DorkBuster Server Multiplexer
#
# Synopsis: Clients connect to dbmux, and receive a feed from
# all dorkbusters to which their credentials apply.
#
# Copyright (c) 2006 Bill Kelly. All Rights Reserved.
# This code may be modified and distributed under either Ruby's
# license or the Library GNU Public License (LGPL).
#
# The copyright holder makes no representations about the
# suitability of this software for any purpose. It is provided
# "as is" without express or implied warranty.
#
# THE COPYRIGHT HOLDERS DISCLAIM ALL WARRANTIES WITH REGARD TO
# THIS SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS, IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR
# ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
# AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
# OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

require 'thread'
require 'fastthread'
require 'timeout'
require 'dbcore/recursive-mutex'
require 'dbcore/global-signal'
require 'dbcore/term-keys'
require 'dbcore/windowed-term'
require 'dbcore/line-edit'
require 'dbcore/dbclient'
require 'dbcore/q2rcon'  # for ClientState and ServerState structs
require 'dbmod/colors'
require 'wallfly/dorkbuster-client'  # TODO: dorkbuster-client should really be in dbcore/ :(

DBMUX_VERSION = "0.0.2"

usage = "Usage: #{File.basename($0)} port"
abort(usage) unless ARGV.length == 1
listen_port = ARGV.shift

sv_cfg_filename = "server-info.cfg"
abort("Server config file #{sv_cfg_filename} not found. Please see server-example.cfg") unless test ?f, sv_cfg_filename
load sv_cfg_filename

ENV['DORKBUSTER_SERVER']      = ''
ENV['DORKBUSTER_PORT']        = listen_port
ENV['DORKBUSTER_SERVER_NICK'] = "dbmux"

require 'dbmod/users'  # NOTE: depends on $server_info, and ENV['DORKBUSTER_SERVER_NICK']

LogcacheNode = Struct.new(:timestamp, :line)

class DBState
  attr_reader :last_stat_time

  CHATLOG_CACHE_MAXLINES = 100

  def initialize
    @last_stat_time = {}
    @status = {}
    @num_clients_cache = Hash.new(0)
    @status_lines_cache = {}
    @status_info_cache = {}
    @status_hdr_cache = {}
    @chatlog_cache = Hash.new {|h,k| h[k] = Array.new}
  end

  def cache_new_status(dbname, status_obj)
    @status[dbname] = status_obj
    @num_clients_cache[dbname] = calc_num_clients(dbname)
    status_lines, status_info, status_hdr = parse_status_info(dbname)
    @status_lines_cache[dbname] = status_lines
    @status_info_cache[dbname] = status_info
    @status_hdr_cache[dbname] = status_hdr
  end

  def cache_chatlog(dbname, str)
    logcache = @chatlog_cache[dbname]
    if lastnode = logcache.last
      return if str == lastnode.line  # don't cache duplicates
    end
    newnode = LogcacheNode.new(Time.now, str)
    logcache.unshift newnode
    logcache.pop if logcache.length > CHATLOG_CACHE_MAXLINES
  end

  def get_chatlog(dbname)
    @chatlog_cache[dbname]
  end

  def num_clients(dbname)
    @num_clients_cache[dbname]
  end

  def cur_map(dbname)
    mapname = "???"
    if status_obj = @status[dbname]
      if server_state = status_obj['server_state']
        mapname = server_state['mapname']
      end
    end
    mapname
  end

  def status_text(dbname)
    txt = ""
    if status_obj = @status[dbname]
      txt = status_obj['status'].to_s
    end
    txt
  end

  def get_status_info(dbname)
    lines = @status_lines_cache[dbname]  ||  []
    info =  @status_info_cache[dbname].to_s
    hdr =   @status_hdr_cache[dbname].to_s
    [lines, info, hdr]
  end

  protected

  def calc_num_clients(dbname)
    numcl = 0
    if status_obj = @status[dbname]
      if client_state = status_obj['client_state']
        numcl = client_state.compact.length
      end
    end
    numcl
  end

  def parse_status_info(dbname)
    status_lines = status_text(dbname).split(/\n/)
    status_info = status_lines.shift.to_s
    status_hdr = status_lines.shift.to_s
    status_lines.shift
    [status_lines, status_info, status_hdr]
  end
end

class DbClientHandler

  attr_reader :dbname, :username

  @@dbstate = DBState.new

  def initialize(sock, global_signal, db_nick, db_username, db_password)
    @dbname = db_nick
    @username = db_username
    @db = DorkBusterClient.new(sock, db_username, db_password, global_signal)
  end

  def preserve_color_codes=(flag)
    @db.preserve_color_codes = flag
  end

  def close
    @db.close
  end

  def login
    @db.login
  end

  def puts(str)
    @db.speak(str)
  end

  def each_line
    @db.get_parse_new_data
    while dbline = @db.next_parsed_line
      yield dbline
    end
  end


  def last_stat_time
    @@dbstate.last_stat_time[@dbname]
  end

  def last_stat_time=(timestamp)
    @@dbstate.last_stat_time[@dbname] = timestamp
  end

  def cache_new_status(status_obj)
    @@dbstate.cache_new_status(@dbname, status_obj)
  end

  def num_clients
    @@dbstate.num_clients(@dbname)
  end

  def cur_map
    @@dbstate.cur_map(@dbname)
  end

  def status_text
    @@dbstate.status_text(@dbname)
  end

  def get_status_info
    @@dbstate.get_status_info(@dbname)
  end

  def cache_chatlog(str)
    @@dbstate.cache_chatlog(@dbname, str)
  end

  def get_chatlog
    @@dbstate.get_chatlog(@dbname)
  end
end



class DBScreenCommon

  # input, log, and chat are common to all screens
  def initialize(term, log_rgn, input_rgn, chat_rgn, console, logscroller, chatscroller)
    @term, @log_rgn, @input_rgn, @chat_rgn, @console, @logscroller, @chatscroller = term, log_rgn, input_rgn, chat_rgn, console, logscroller, chatscroller

    @dbs = nil
    @cur_db_idx = 0
  end

  def log_puts(str)
    # @log_rgn.cr
    # @log_rgn.print(str)
    @logscroller.puts(str)
    @input_rgn.focus
  end

  def chat_puts(str)
    @chatscroller.puts(str)
    @input_rgn.focus
  end

  # main screen turn on.
  def activate
    @console.key_hook(TermKeys::KEY_PGUP) { @chatscroller.pgup; @input_rgn.focus }
    @console.key_hook(TermKeys::KEY_PGDN) { @chatscroller.pgdn; @input_rgn.focus }
    @console.key_hook(?\C-y) { @chatscroller.pgup; @input_rgn.focus }
    @console.key_hook(?\C-v) { @chatscroller.pgdn; @input_rgn.focus }
    redraw(true)
  end

  def redraw(force=false)
    init_window_regions
    @logscroller.redraw
    redraw_dynamic(force)
    @chatscroller.redraw
    @console.redraw
    @input_rgn.focus
  end

  def update_dynamic(dbs, cur_db_idx)
    @dbs, @cur_db_idx = dbs, cur_db_idx
    regions_changed = recalc_window_regions
    if regions_changed
      redraw(true)
    else
      redraw_dynamic(false)
    end
  end

  def cur_db
    return nil unless @dbs
    @dbs[@cur_db_idx]
  end

  protected

  def gen_info_str(dbs, cur_db_idx, basecolor)
    cur_dbname = dbs[cur_db_idx].dbname
    dbs = dbs.sort_by {|db| [ -db.num_clients, db.dbname] }
    dbs_info = dbs.collect do |db| 
      dbname = db.dbname
      dbname = ANSI.colorize(dbname, [ANSI::Bright, ANSI::Yellow, ANSI::BGCyan], basecolor) if dbname == cur_dbname
      "#{dbname}(#{db.num_clients})"
    end
    info_str = dbs_info.join(" ")
  end
end

class DBMainScreen < DBScreenCommon

  def initialize(*args)
    super(*args)
    @info_rgn = OutputRegion.new(@term)
    @last_info_str = ""
  end

  protected

  def recalc_window_regions
    old_positions = [@log_rgn, @info_rgn, @chat_rgn, @input_rgn].collect {|rgn| [rgn.row_start, rgn.row_end]}

    info_height = 1
    input_height = 1
    avail_rows = @term.term_rows - (info_height + input_height)
    log_height = (avail_rows * (3.0 / 4)).round
    chat_height = avail_rows - log_height

    at_row = 1
    @log_rgn.set_scroll_region(at_row, at_row + (log_height - 1))
    at_row += log_height
    @info_rgn.set_scroll_region(at_row, at_row + (info_height - 1))
    at_row += info_height
    @chat_rgn.set_scroll_region(at_row, at_row + (chat_height - 1))
    at_row += chat_height
    @input_rgn.set_scroll_region(at_row, at_row + (input_height - 1))

    new_positions = [@log_rgn, @info_rgn, @chat_rgn, @input_rgn].collect {|rgn| [rgn.row_start, rgn.row_end]}
    old_positions != new_positions
  end

  def init_window_regions
    recalc_window_regions

    @log_rgn.set_color(ANSI::Reset)
  # @log_rgn.clear
    @info_rgn_defattr = [ANSI::Bright, ANSI::White, ANSI::BGCyan]
    @info_rgn.set_color(*@info_rgn_defattr)
  # @info_rgn.clear
    @chat_rgn.set_color(ANSI::Reset)
  # @chat_rgn.clear
    @input_rgn.set_color(ANSI::Bright, ANSI::Yellow, ANSI::BGBlue)
  # @input_rgn.clear
    
    @log_rgn.home_cursor
    @info_rgn.home_cursor
    @chat_rgn.home_cursor
    @input_rgn.home_cursor
  end

  def redraw_dynamic(force)
    return if @dbs.nil? || @dbs.empty?
    update_info_rgn(@dbs, @cur_db_idx, force)
  end

  def update_info_rgn(dbs, cur_db_idx, force)
    info_str = gen_info_str(dbs, cur_db_idx, @info_rgn_defattr)
    if force  ||  info_str != @last_info_str
      rgn = @info_rgn
      rgn.home_cursor
      rgn.set_color(*@info_rgn_defattr)
      rgn.print_erased_clipped(info_str)
      @last_info_str = info_str
      @input_rgn.focus
    end
  end
end


class DBStatusScreen < DBScreenCommon

  INFO_BASECOLOR = [ANSI::Bright, ANSI::White, ANSI::BGCyan]

  def initialize(*args)
    super(*args)
    @dyn_rgn = OutputRegion.new(@term)
    @last_status_str = ""
  end

  protected

  def status_lines_wanted
    db = cur_db
    return 1 unless db
    status_lines, status_info, status_hdr = db.get_status_info
    status_lines.length + 3
  end

  def recalc_window_regions
    old_positions = [@log_rgn, @dyn_rgn, @chat_rgn, @input_rgn].collect {|rgn| [rgn.row_start, rgn.row_end]}

    input_height = 1

    log_height_min = 2
    chat_height_min = 2
    dyn_height_wanted = status_lines_wanted
    dyn_height = [@term.term_rows - (input_height + log_height_min + chat_height_min), dyn_height_wanted].min

    avail_rows = @term.term_rows - (input_height + dyn_height)
    log_height = (avail_rows * (2.0 / 3)).round
    chat_height = avail_rows - log_height

    at_row = 1
    @log_rgn.set_scroll_region(at_row, at_row + (log_height - 1))
    at_row += log_height
    @dyn_rgn.set_scroll_region(at_row, at_row + (dyn_height - 1))
    at_row += dyn_height
    @chat_rgn.set_scroll_region(at_row, at_row + (chat_height - 1))
    at_row += chat_height
    @input_rgn.set_scroll_region(at_row, at_row + (input_height - 1))

    new_positions = [@log_rgn, @dyn_rgn, @chat_rgn, @input_rgn].collect {|rgn| [rgn.row_start, rgn.row_end]}
    old_positions != new_positions
  end

  def init_window_regions
    recalc_window_regions

    @log_rgn.set_color(ANSI::Reset)
  # @log_rgn.clear
    @dyn_rgn.set_color(ANSI::Reset)
  # @dyn_rgn.clear
    @chat_rgn.set_color(ANSI::Reset)
  # @chat_rgn.clear
    @input_rgn.set_color(ANSI::Bright, ANSI::Yellow, ANSI::BGBlue)
  # @input_rgn.clear
    
    @log_rgn.home_cursor
    @dyn_rgn.home_cursor
    @chat_rgn.home_cursor
    @input_rgn.home_cursor
  end

  def redraw_dynamic(force)
    db = cur_db
    if db
      status_lines, status_info, status_hdr = db.get_status_info
      info_str = gen_info_str(@dbs, @cur_db_idx, INFO_BASECOLOR)
    else
      status_lines, status_info, status_hdr = [], "No status available...", ""
      info_str = ""
    end

    status_str = (status_lines + [status_info, status_hdr, info_str]).join("\n")
    if force  ||  status_str != @last_status_str
      render_status_display(status_lines, status_info, status_hdr, info_str)
      @last_status_str = status_str
    end
  end

  def render_status_display(status_lines, status_info, status_hdr, info_str)
    rgn = @dyn_rgn
    rgn.home_cursor
    rgn.set_color(ANSI::Bright, ANSI::White, ANSI::BGCyan)
    rgn.print_erased_clipped(status_info)
    rgn.set_color(ANSI::Reset, ANSI::Black, ANSI::BGYellow)
    rgn.cr
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
      rgn.set_color(*INFO_BASECOLOR)
      rgn.set_cursor_pos(rgn.term_rows, 1)
      rgn.print_erased_clipped(info_str)
    end

    @input_rgn.focus
  end

end


class WindowedClientHandler

  MIN_ROWS = 12

  attr_reader :console

  def initialize(client_sock, global_signal)
    @windowed = false
    @bufio = BufferedIO.new(client_sock, global_signal)
    @termio = ANSITermIO.new(@bufio)
    @term = WindowedTerminal.new(@termio)
    @log_rgn = OutputRegion.new(@term)
    @chat_rgn = OutputRegion.new(@term)
    @input_rgn = OutputRegion.new(@term)
    @logscroller = Backscroller.new(@log_rgn)
    @chatscroller = Backscroller.new(@chat_rgn)
    @console = DBWindowedConsole.new(@term, @input_rgn)
    @scr_main = DBMainScreen.new(@term, @log_rgn, @input_rgn, @chat_rgn, @console, @logscroller, @chatscroller)
    @scr_status = DBStatusScreen.new(@term, @log_rgn, @input_rgn, @chat_rgn, @console, @logscroller, @chatscroller)
    @screens = [@scr_main, @scr_status]
    @scr_cur_idx = 0
    @prompt = ""
    term_reset
  end

  def close
    @console.close
    @term.close
    @termio.close
    @bufio.close
  end

  def term_init_ok?
    @term_init_ok
  end

  def term_reset
    @term_init_ok = init_terminal(MIN_ROWS)
    scr_current.activate if @term_init_ok
  end

  def eof
    @term.eof
  end

  def set_prompt(str_or_proc)
    @console.set_prompt(@prompt = str_or_proc)
  end
  
  def set_echo(flag)
    @console.set_echo(flag)
  end  

  def con_puts(str)
    scr_current.log_puts(str)
  end

  def log_puts(str)
    scr_current.log_puts(str)
  end

  def chat_puts(str)
    scr_current.chat_puts(str)
  end

  def init_terminal(min_rows=MIN_ROWS)
    @termio.erase_screen

    # attempt to force telnet client into unbuffered character mode
    will_echo = "\xff\xfb\x01"
    do_sga = "\xff\xfd\x02"
    do_linemode = "\xff\xfd\x22"
    @bufio.send_nonblock(will_echo + do_sga + do_linemode)
    # ULTRA-KLUDGE!  Since we don't have a parser to handle telnet
    # response codes from the client's terminal... We'll cheesily
    # wait 1/2 sec and gobble them... :(
    sleep(0.5)
    @bufio.recv_nonblock
    @termio.erase_screen
    
    begin
      @term.ask_term_size
    rescue Timeout::Error
      @termio.erase_screen
      @term.puts(ANSI.red(
        "Your terminal wouldn't tell me its size. "+
        "You may need to put your terminal into "+
        "character mode (mode ch) manually, and "+
        "try again."))
      return false
    end

    if @term.term_rows < min_rows
      @termio.erase_screen
      @term.puts(ANSI.red(
        "Your terminal reported its size as #{@term.term_rows} rows, "+
        "but a minimum of #{MIN_ROWS} are required. "+
        "You might try resizing your window and reconnecting."))
      return false
    end

    true
  end

  def scr_current
    @screens[@scr_cur_idx]
  end

  def scr_next_idx
    nidx = @scr_cur_idx + 1
    nidx = 0 if nidx > (@screens.length - 1)
    nidx
  end
end

class DBMultiplexerClient < WindowedClientHandler

  attr_reader :session_port, :session_hostname, :session_ip

  def initialize(cl_sock, global_signal, dbmux_api, logger)
    @global_signal = global_signal
    @dbmux = dbmux_api
    @logger = logger
    super(cl_sock, global_signal)
    @console.key_hook(?\t) { tab_next_screen }
    sock_domain, @session_port, @session_hostname, @session_ip = cl_sock.peeraddr rescue ['unknown'] * 4
    @dbs = []
    session_reset_to_login
  end

  def close
    close_all_dbs
    unless eof
      @termio.set_scroll_fullscreen
      @termio.set_cursor_pos(255, 1)
      @termio.set_color(ANSI::Reset)
      @termio.puts "\n"
      @termio.flush(0.5)
    end
    super
  end

  def cur_db
    @dbs[@cur_db_idx]
  end

  def set_cur_db(idx)
    @cur_db_idx = idx
  end

  def connect_all_dbs(server_list)
    server_list.each do |sv|
      con_puts "Connecting to #{sv.nick} at #{sv.dbip}:#{sv.dbport} ..."
      db = connect_db(sv.nick, sv.dbip, sv.dbport, @login_user.username, @login_pass_plaintext)
      @dbs << db if db
    end
    con_puts "Ready ..."
  end

  def close_all_dbs
    @dbs.each do |db| 
      begin
        con_puts("Disconnecting from #{db.dbname} ...")
        db.puts "logout"
        db.close rescue nil 
      rescue Interrupt, NoMemoryError, SystemExit
        raise
      rescue Exception => ex
        $stderr.puts "close_all_dbs: Unexpected exception #{ex.inspect} - continuing..."
      end
    end
    @dbs.clear
    @cur_db_idx = 0
    @max_dbname_len = 0
  end

  def process_data_from_dbs
    @dbs.each {|db| handle_db(db)}
    update_dynamic
  end

  def logged_in?
    @login_state == :shell
  end

  def accept_client_input(line)
    case @login_state
      when :noterm then session_handle_noterm(line)
      when :login  then session_handle_login(line)
      when :passwd then session_handle_passwd(line)
      when :shell  then session_handle_shell(line)
    end
  rescue Exception => ex
    $stderr.puts "**** Caught exception in accept_client_input: #{ex.inspect}"
    $stderr.puts ex.backtrace
  end

  def session_username
    @login_user ? @login_user.username : "never-logged-in"
  end

  protected

  def tab_next_screen
    if logged_in?
      @scr_cur_idx = scr_next_idx
      scr_current.activate
    end
  end

  def update_dynamic
    scr_current.update_dynamic(@dbs, @cur_db_idx)
  end

  def session_reset_to_login
    close_all_dbs
    @login_user = nil
    @login_username_attempt = nil
    @login_pass_plaintext = nil
    if term_init_ok?
      @login_state = :login
      log_puts("DorkBuster Aggregator/Multiplexer (dbmux) v#{DBMUX_VERSION}")
      set_prompt("login:")
      set_echo(true)
    else
      @login_state = :noterm
      set_prompt("Terminal init failed. Press enter to retry...")
      set_echo(false)
      @console.redraw
    end
  end

  def session_handle_noterm(line)
    term_reset
    session_reset_to_login
  end

  def session_handle_login(line)
    unless line =~ /\A\s*\z/
      @login_username_attempt = line
      @logger.log(%Q<[Dork Buster: user "#{@login_username_attempt}" (#{@session_ip}:#{@session_port}) attempting login]>)
      set_prompt("passwd:")
      set_echo(false)
      @login_state = :passwd
    end
  end

  def session_handle_passwd(line)
    @login_pass_plaintext = line
    user = DorkBusterUserDatabase.match_user(@login_username_attempt, @login_pass_plaintext)
    if user
      @logger.log(%Q<[Dork Buster: user "#{user.username}" (#{@session_ip}:#{@session_port}) logged in successfully]>)
      @login_user = user
      @login_username_attempt = nil
      session_enter_shell_state
    else
      @logger.log(%Q<[Dork Buster: user "#{@login_username_attempt}" (#{@session_ip}:#{@session_port}) bad username or password]>)
      con_puts(ANSI.colorize("\n\nbad username or password\n\n", [ANSI::Bright, ANSI::Red, ANSI::BGBlack]))
      session_reset_to_login
    end
  end

  def session_enter_shell_state
    @login_state = :shell
    @allowed_servers_list = DorkBusterUserDatabase.filter_servers_authorized_for_user($server_list, @login_user.username)
    @max_dbname_len = @allowed_servers_list.map {|sv| sv.nick.length}.max
    set_echo(true)
    session_set_shell_prompt
    con_puts("\n\nWelcome, #{session_username}.\n")
    connect_all_dbs(@allowed_servers_list)
    backfill_chatscroller
  end

  def session_set_shell_prompt
    prompter = Proc.new do
      db = cur_db
      if db
        "#{session_username}@#{db.dbname}/#{db.cur_map}/#{db.num_clients}>"
      else
        "#{session_username}@???>"
      end
    end
    set_prompt(prompter)
  end

  def session_handle_shell(line)
    handled = false
    if line =~ /\A\s*(\S+)\s*(.*)\z/
      cmd, args = $1, $2
      begin
        handled, line = session_handle_shell_cmd(cmd, args, line)
      rescue Interrupt, NoMemoryError, SystemExit
        raise
      rescue Exception => ex
        con_puts "Exception #{ex.inspect} handling line: #{line}"
        handled = true
      end
    end
    cur_db.puts(line) unless handled
  end

  def session_handle_shell_cmd(cmd, args, line)
    handled = true
    case cmd
      when "logout"        then @dbmux.disconnect_client(self)
    # when "status"        then todo = 12345
    # when "status!"       then handled, line = false, "status"
      when "/sv"           then session_cmd_sv(args)
      when "!sv"           then session_cmd_send_sv(args)
      when "@win"          then term_reset
      else handled = false
    end
    [handled, line]
  end

  def get_db_idx_for_dbname(dbname)
    db_idx = nil
    @dbs.each_with_index {|db,i| db_idx = i if db.dbname == dbname}
    db_idx
  end

  def session_cmd_sv(args)
    args.strip!
    if new_db_idx = get_db_idx_for_dbname(args)
      set_cur_db(new_db_idx)
    else
      server_names = @dbs.collect {|db| db.dbname}.sort.join(" ")
      con_puts "Please specify server name: #{server_names}"
    end
  end

  def session_cmd_send_sv(args)
    args.lstrip!
    svname, cmd = args.split(/\s+/, 2)
    if db_idx = get_db_idx_for_dbname(svname.to_s)
      @dbs[db_idx].puts cmd.to_s
    else
      server_names = @dbs.collect {|db| db.dbname}.sort.join(" ")
      con_puts "Please specify server name: #{server_names}"
    end
  end

  def handle_db(db)
    dbnick_plain = dbnick_color = sprintf("%#{@max_dbname_len}s", db.dbname)
    dbnick_color = ANSI.colorize(dbnick_plain, [ANSI::Bright, ANSI::Yellow, ANSI::BGBlack]) if db.dbname == cur_db.dbname
    db.each_line do |dbline|
      if dbline.is_obj?
        # if dbline.obj_label == "NEWSTAT"
         # handle_newstat(db, dbline.obj)
        if dbline.obj_label == "STATUS"
          handle_status(db, dbline.obj)
        else
          log_puts "[#{dbnick_color}] [#{dbline.kind}] Unexpected object received, type: #{dbline.obj_label} obj: #{dbline.obj.inspect}"
        end
      else
        collate_print_dbline(db, dbline, dbnick_plain, dbnick_color)
      end
    end
    request_status_if_old(db)
  end

  def collate_print_dbline(db, dbline, dbnick_plain, dbnick_color)
    is_chat = false
    if dbline.is_db_user?
      if user = DorkBusterUserDatabase.find_user(dbline.speaker)
        is_chat = ! user.is_ai
      end
      if dbline.cmd =~ /\Alogout(\s.*)?\z/
        is_chat = false  # don't want whole stream of logouts from dbmux exit ending up in chat
      end
    elsif dbline.is_db_user_pm?
      is_chat = true
    end
    elide = !is_chat  &&  elide_dbline?(db, dbline)
    unless elide
      if is_chat
        outstr = "[#{dbnick_plain}] #{dbline.raw_line}"
        db.cache_chatlog(outstr) unless dbline.is_db_user_pm?
        chat_puts(outstr)
      end
      outstr = "[#{dbnick_color}] #{dbline.raw_line}"   
      log_puts(outstr)
    end
  end

  def elide_dbline?(db, dbline)
    is_cur_db = db.object_id == cur_db.object_id
    if !is_cur_db
      if dbline.is_player_chat?
        return true if dbline.raw_line =~ /entered the game\s*(\(clients = \d+\))?(?:\s|\e\[[0-9;]*[A-Za-z])*\z/
        return true if dbline.raw_line =~ /seconds \(\d+ completions\)(?:\s|\e\[[0-9;]*[A-Za-z])*\z/
      else
        return false if dbline.raw_line =~ /wallfly:.*(BAN|MUTE)/
        return true  # squelch all non-player-chat in non-current dbs
      end
    end
    return true if dbline.is_map_over?  ||  dbline.is_enter_game?
    return true if dbline.raw_line =~ /\(private message to: .*?\) GOTO/
    return true if dbline.raw_line =~ /HAL: rcon sv !say_person RE .*? "GOTO/
    return true if dbline.raw_line =~ /wallfly: rcon sv !say_person/
    false
  end

  def backfill_chatscroller
    chatlog = @dbs.collect {|db| db.get_chatlog}.flatten.sort_by {|node| node.timestamp}.collect {|node| node.line}
    @chatscroller.set_buffer(chatlog)
  end

  def connect_db(dbnick, dbhost, dbport, login_name, passwd)
    dbsock = dbc = nil
    begin
      dbsock = TCPSocket.new(dbhost, dbport.to_s)
      dbc = DbClientHandler.new(dbsock, @global_signal, dbnick, login_name, passwd)
      dbc.login
      dbc.preserve_color_codes = true
      dbc.puts "@win stream"
    rescue Interrupt, NoMemoryError, SystemExit
      raise
    rescue Exception => ex
      msg = "exception connecting to #{dbnick}: #{ex.inspect} ... continuing..."
      con_puts msg
      $stderr.puts msg, ex.backtrace
      if dbc
        dbc.close rescue nil
      elsif dbsock
        dbsock.close rescue nil
      end
      dbsock = dbc = nil
    end
    dbc
  end

  # NOTE: this architecture is kind of weird.
  # Each user connected to dbmux, has his/her own individual login, in turn
  # to each dorkbuster to which they have access.  
  # From the point of view of dbmux, this means, if we have 6 users logged
  # into dbmux, we'll have 6 redundant connections per dorkbuster, streaming
  # back data.  This is certainly not too efficient, but it seemed the
  # easiest implementation.  This mean, in this example, we have 6 connections
  # to a given dorkbuster, all receiving NEWSTAT notifications.  When we
  # receive a NEWSTAT, we want to turn around and query for the full status
  # object.  But we don't want to query 6 times, as it would be totally
  # redundant.  The NEWSTAT notification comes with a timestamp, so we
  # compare that timestamp to that of our previous status request, and
  # only query once for the full status object.  I.e., we query for full
  # status only when we get a NEWSTAT where the timestamp is newer than our
  # last full query.  This means the actual dbmux user on whose behalf the
  # full query actually takes place, is essentially arbitrary.  But since
  # the status object will be the same no matter which user requests it,
  # it doesn't matter which user we happen to be processing here when/if
  # we decide to perform the full query.
  # def handle_newstat(db, timestamp)
  #   laststat_time = db.newstat_seen
  #   want_newstat = laststat_time.nil? || (timestamp > laststat_time)
  #   if want_newstat
  #     db.puts "/send_status_obj"
  #     db.newstat_seen = timestamp
  #   end
  # end

  STATUS_REQUEST_INTERVAL_SECS_CUR = 3
  STATUS_REQUEST_INTERVAL_SECS_AWAY = 15

  def request_status_if_old(db)
    now = Time.now
    laststat_time = db.last_stat_time
    is_cur_db = db.object_id == cur_db.object_id
    if is_cur_db
      interval_secs = STATUS_REQUEST_INTERVAL_SECS_CUR + (rand * 1.0)
    else
      # randomize a little to spread out requests between all dbs
      interval_secs = STATUS_REQUEST_INTERVAL_SECS_AWAY + (rand * 10.0)
    end
    want_newstat = laststat_time.nil? || ((now - laststat_time) >= interval_secs)
    if want_newstat
 $stderr.puts "requesting stat on #{db.dbname} (cur=#{is_cur_db}), last was #{laststat_time.nil? ? 'nil' : now - laststat_time} ago, interval #{interval_secs}"
      db.puts "/send_status_obj"
      db.last_stat_time = now
    end
  end

  def handle_status(db, status_obj)
    db.cache_new_status(status_obj)
  end
end


class DBMultiplexerServer

  def initialize(listen_port)
    @listen_port = listen_port
    IPSocket.do_not_reverse_lookup = true
    @global_signal = GlobalSignal.new
    @clients = []
    @moribund_clients = []
    @incoming_tcp_clients = Queue.new
    @last_client_update = Time.at(0)
  end

  def run
    @tcp_server = TCPServer.new(@listen_port)
    @background_accept_th = Thread.new { background_accept_clients }
    loop do
      begin
        @global_signal.timed_wait(0.5)
      rescue Timeout::Error
      end
      induct_new_clients
      process_client_input
      delete_moribund_clients
      update_clients
    end
  end

  def log(msg)
    $stdout.puts(Time.now.strftime("%Y-%m-%d %a ") + msg)
    @clients.each {|cl| cl.log_puts(msg) if cl.logged_in? }
  end

  def disconnect_client(cl)
    @moribund_clients << cl
  end

  protected

  def induct_new_clients
    until @incoming_tcp_clients.empty?
      cl_sock = @incoming_tcp_clients.pop
      cl = DBMultiplexerClient.new(cl_sock, @global_signal, self, self)
      @clients << cl
    end
  end

  def delete_moribund_clients
    @moribund_clients.each do |cl|
      @clients.delete cl
      log(%Q<[Dork Buster: client "#{cl.session_username}" (#{cl.session_ip}:#{cl.session_port}) disconnected]>)
      cl.close
    end
    @moribund_clients.clear
  end
  
  def process_client_input
    @clients.each do |cl|
      if cl.eof
        @moribund_clients << cl
      else
        while (line = cl.console.readln)
          cl.accept_client_input(line)
        end
      end
    end
  end

  CLIENT_UPDATE_FREQ = 0.45

  def update_clients
    now = Time.now
    time_since_last_update = now - @last_client_update
    return unless time_since_last_update >= CLIENT_UPDATE_FREQ
    @last_client_update = now

    @clients.each do |cl|
      cl.process_data_from_dbs
    end
  end

  def background_accept_clients
    loop do
      begin
        accept_client
      rescue Exception => ex
        log("accept_client exception #{ex.inspect}")
      end
    end
  end
  
  def accept_client
    cl_sock = @tcp_server.accept
    if cl_sock
      begin
        cl_sock.setsockopt(Socket::SOL_TCP, Socket::TCP_NODELAY, 1) if defined? Socket::SOL_TCP
      rescue IOError, SystemCallError, SocketError
        cl_sock.close
      else
        @incoming_tcp_clients.push cl_sock
        @global_signal.signal
      end
    end
  end

end


puts "Listening on port #{listen_port}..."
sv = DBMultiplexerServer.new(listen_port)
sv.run

# TODO: 
#   - mrgreen and anon should display in admin chat region
#   - show MAP_CHANGE from all servers
#   - add reload_dbmux ability



