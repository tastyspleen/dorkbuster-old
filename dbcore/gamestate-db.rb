
require 'time'
require 'date'
require 'dbcore/mru-cache'
require 'update_client'
require 'query_client'

class GameStateDB

  STATUS_ALIASES_LIMIT = 10
  TOP_ALIASES_LIMIT = 5

  attr_reader :client_state, :server_state

  def initialize(logger, server_nickname)
    @logger = logger
    @sv_nick = server_nickname
    @client_state = []
    @server_state = ServerState.new
    @akas_for_ip_cache = MRUCache.new(100)
    @up = UpdateClient.new(@logger)
    @qy = QueryClient.new(@logger)
    @up.connect
  end

  def close
    @up.close if @up rescue nil
    @qy.close if @qy rescue nil
    @up = nil
    @qy = nil
  end

  def new_client_state(new_client_list)
    new_state = client_list_to_state(new_client_list)
    old_state = @client_state
    @client_state = new_state  # update prior to printouts for possible prompt changes
    for i in 0..([old_state.length, new_state.length].max)
      record_client_change(new_state[i], old_state[i])
    end
  end

  def new_server_state(new_state)
    old_state = @server_state
    @server_state = new_state  # update prior to printouts for possible prompt changes
    newmap, oldmap = new_state['mapname'], old_state['mapname']
    if oldmap && newmap && oldmap != newmap
      log(sprintf("%-12s %s", "MAP_CHANGE:", "#{newmap} (was:#{oldmap})"))
    end
  end

  def db_update_backlog
    @up.backlog
  end

  def active_clients
    @client_state.compact
  end

  def clients_for_name(name)
    name = name.rstrip
    active_clients.select {|cl| cl.name == name }
  end

  def anticipate_disconnect(name)
    clients_for_name(name).each do |cl|
      new_cl = cl.dup
      new_cl.ping = "ZMBI"
      record_client_change(new_cl, cl)
      cl.ping = "ZMBI"
    end
  end

  def anticipate_name_change(oldname, newname)
    # Hmm, may not be necessary...
    # log(%{NAME_CHANGING: "#{oldname}" to "#{newname}"})
  end

  def get_akas_for_ip(ip, exclude_names = nil)
    unless (akas = @akas_for_ip_cache[ip])
      akas = @qy.aliases_for_ip(ip, 1000)
      akas ||= []
      @akas_for_ip_cache[ip] = akas
    end
    if exclude_names
      exclude_names = [exclude_names] unless exclude_names.respond_to?(:push)
      # using reject instead of delete, because don't want to modify cached object
      akas = akas.reject {|n| exclude_names.include?(n)}
    end
    akas
  end

  def get_top_akas_for_ip(ip, exclude_names = nil, limit = STATUS_ALIASES_LIMIT)
    akas = get_akas_for_ip(ip, exclude_names)
    num_akas = akas.length
    if num_akas > (limit + 1)
      akas = akas[0..(limit - 1)]
      akas << "(#{num_akas - limit} more)"
    end
    akas
  end

  def top_aliases(limit=TOP_ALIASES_LIMIT)
    aliases_list = []
    excl = DorkBusterUserDatabase::ALIASES_EXCLUDE
    active_clients.each do |cl|
      next if cl.ip == $q2wallfly_ip
      aliases = get_top_akas_for_ip(cl.ip, excl + [cl.name], limit).join(", ")
      aliases = "(no aliases found on this IP)" if aliases.empty?
      aliases_list << "#{cl.name} = #{aliases}"
    end
    aliases_list
  end

  def status
    status_str = ""
    hostname = @server_state['hostname'] || "?"
    map =      @server_state['mapname'] || "?"
    dmflags =  @server_state['dmflags'] || "?"
    fl =       @server_state['fraglimit'] || "?"
    tl =       @server_state['timelimit'] || "?"
    cheats =   @server_state['cheats'] || "?"
    status_str << sprintf("%s: map:%s / dmflags:%s / fraglimit:%s / timelimit:%s / cheats:%s / db_backlog:%d\n",
                          hostname, map, dmflags, fl, tl, cheats, db_update_backlog)
    status_str << "num score ping name            lastmsg ip               port akas\n"
    status_str << "--- ----- ---- --------------- ------- --------------------- -----\n"
    yel, rst = "#{ANSI.color(ANSI::DBStatus)}", "#{ANSI.color(ANSI::Reset)}"
    active_clients.each do |cl|
      akas = get_top_akas_for_ip(cl.ip, cl.name).join(", ")
      port = (cl.port == 27901)? "std" : cl.port
      status_str << sprintf("#{yel}%3s#{rst} %5s %4s #{yel}%-15s#{rst} %7s %-15s #{yel}%5s#{rst} %s\n",
                            cl.num, cl.score, cl.ping, cl.name, cl.lastmsg,
                            cl.ip, port, akas)
    end
    status_str
  end

  PLAYERSEEN_GREP_LIMIT = 1000
  def playerseen_grep(search_str)
    rows = @qy.playerseen_grep(search_str, PLAYERSEEN_GREP_LIMIT)
    playerseen_times_to_relative(rows)
    return "no match for #{search_str.inspect}\n" if rows.empty?
    header_row = %w(playername server ip hostname first_seen last_seen times_seen)
    rows.unshift header_row
    format_rows(rows)
  end

  TOP_FRAGS_LIMIT = 20
  def top_frags(dbname, inflictor, victim, method_str, servername)
    rows = @qy.frag_list(dbname, inflictor, victim, method_str, servername, Date.today, TOP_FRAGS_LIMIT)
    return "no match\n" if rows.empty?
    header_row = %w(inflictor victim MOD server count)
    rows.unshift header_row
    format_rows(rows)
  end

  def top_suicides(dbname, victim, method_str, servername)
    rows = @qy.suicide_list(dbname, victim, method_str, servername, Date.today, TOP_FRAGS_LIMIT)
    return "no match\n" if rows.empty?
    header_row = %w(victim MOD server count)
    rows.unshift header_row
    format_rows(rows)
  end

  def log_frag(inflictor, victim, method_str)
    unless playername_is_bot?(inflictor)
      @up.frag(inflictor, victim, method_str, @sv_nick, Date.today, 1)
    end
  end

  def log_suicide(victim, method_str)
    unless playername_is_bot?(victim)
      @up.suicide(victim, method_str, @sv_nick, Date.today, 1)
    end
  end

  def fmt_time_ago(since_sec)
    days = since_sec / (60 * 60 * 24)
    return "#{days} days ago" if days > 1
    hours = since_sec / (60 * 60)
    return "#{hours} hours ago" if hours > 1
    minutes = since_sec / 60
    return "#{minutes} minutes ago" if minutes > 1
    "just-now"
  end

  private

  def playername_is_bot?(name)
    name[0..4] == "[BOT]"
  end

  def playerseen_times_to_relative(rows)
    # playername servername ip hostname first_seen last_seen times_seen
    rows.each do |row|
      # row[4] = time_to_relative(row[4])
      row[5] = time_to_relative(row[5])
    end
  end

  def time_to_relative(utc_time_str)
    t = Time.parse("#{utc_time_str} UTC") rescue nil
    if t
      t = t.localtime
      t = fmt_time_ago((Time.now - t).round)
    end
    t || utc_time_str
  end

  def calc_col_widths(rows)
    col_widths = []
    rows.each do |row|
      row.each_with_index do |field, i|
        curw = (col_widths[i] ||= 0)
        col_widths[i] = field.length if curw < field.length
      end
    end
    col_widths
  end

  def format_rows(rows)
    col_widths = calc_col_widths(rows)
    fmtstr = col_widths.map {|w| "%#{w}s"}.join("|")
    result = ""
    rows.each do |row|
      if row.length < col_widths.length
        row = row.dup
        row << "" while row.length < col_widths.length
      end
      result << sprintf(fmtstr, *row)
      result << "\n"
    end
    result
  end

  def log(msg)
    @logger.log(msg)
  end

  def in_game_ping?(cl)
    cl.ping.to_s =~ /^\d+$/
  end

  def record_client_change(new_cl, old_cl)
    if new_cl && !old_cl
      log_client_connect(new_cl)
      log_client_enter(new_cl) if in_game_ping?(new_cl)
      log_client_disconnect(new_cl) if new_cl.ping == "ZMBI"
    elsif old_cl && !new_cl
      already_logged = old_cl.ping == "ZMBI"
      log_client_disconnect(old_cl) unless already_logged
    elsif new_cl && old_cl
      if new_cl.ping == "ZMBI"
        new_cl.name = old_cl.name
        new_cl.score = old_cl.score
        log_client_disconnect(old_cl) unless old_cl.ping == "ZMBI"
      elsif old_cl.ping == "ZMBI"
        log_client_connect(new_cl)  # old was ZMBI and new is not ZMBI
        log_client_enter(new_cl) if in_game_ping?(new_cl)
      else
        if new_cl.ip != old_cl.ip  ||  new_cl.qport != old_cl.qport
          log_client_disconnect(old_cl)
          log_client_connect(new_cl)
          log_client_enter(new_cl) if in_game_ping?(new_cl)
        else
          if in_game_ping?(new_cl) && !in_game_ping?(old_cl)
            log_client_enter(new_cl) 
          else
            if new_cl.name != old_cl.name
              log_client_name_change(new_cl, old_cl.name)
            end
          end
        end
      end
    end
  end

  def log_client_connect(cl)
    akas = get_top_akas_for_ip(cl.ip, cl.name).join(", ")
    akas = "(aka: #{akas})" unless akas.empty?
    log(fmt_client_status(cl, "CONNECT", akas))
  end

  def log_client_disconnect(cl)
    log(fmt_client_status(cl, "DISCONNECT", "score:#{cl.score} ping:#{cl.ping}"))
  end

  def log_client_enter(cl)
    register_name_for_ip(cl.name, cl.ip, true)
    log(fmt_client_status(cl, "ENTER_GAME"))
  end

  def log_client_name_change(cl, oldname)
    register_name_for_ip(cl.name, cl.ip, true)
    log(fmt_client_status(cl, "NAME_CHANGE", "was: #{oldname}"))
  end

  def fmt_client_status(cl, heading, extra = "")
    ip_port = sprintf("%15s:%-5s", cl.ip, cl.port.to_s)
    sprintf("%-12s %-4s %-17s %s %s", "#{heading}:", "[#{cl.num}]", "\"#{cl.name}\"", ip_port, extra)
  end

  def client_list_to_state(client_list)
    client_state = []
    client_list.each {|cl| client_state[cl.num] = cl }
    client_state
  end

  def register_name_for_ip(name, ip, update_times_seen = false)
    return if name.strip.empty?  ||  name == "pwsnskle"
    times_inc = update_times_seen ? 1 : 0
    @up.playerseen(name, ip, @sv_nick, Time.now, times_inc)
    @akas_for_ip_cache.delete ip
  end

end

