class GameState

  AutoSaveFreq = 60 # seconds

  STATUS_ALIASES_LIMIT = 10

  attr_reader :client_state, :server_state, :names_by_ip

  def initialize(logger, server_nickname)
    @logger = logger
    @state_filename = "#{server_nickname}/gamestate.dat"
    @state_bak_filename = "#{server_nickname}/gamestate.bak"
    @client_state = []
    @server_state = ServerState.new
    @names_by_ip = {}
    @last_saved = nil
  end

  def live_reinit
    # de-pwsnskle the data
    @names_by_ip.each_value {|names| names.delete(""); names.delete("pwsnskle")}
    
    data_loss__prune_old_ip_name_data
  end

  def data_loss__prune_old_ip_name_data
    prune_threshold = Time.now - (60 * 60 * 24 * (365/2))  # six months ago
    names_deleted = 0
    ips_deleted = 0
    ips = @names_by_ip.keys
    ips.each do |ip|
      kept_any_names_on_this_ip = false
      names = (@names_by_ip[ip] || {}).keys
      names.each do |name|
        last_seen = @names_by_ip[ip][name][:last_seen]
        if last_seen <= prune_threshold
          @names_by_ip[ip].delete name
          names_deleted += 1
        else
          kept_any_names_on_this_ip = true
        end
      end
      unless kept_any_names_on_this_ip
        @names_by_ip.delete ip
        ips_deleted += 1
      end
    end
    log("Deleted #{names_deleted} names and #{ips_deleted} ips.")
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

  def save
    unless @last_saved
      File.syscopy(@state_filename, @state_bak_filename) if FileTest.exists? @state_filename
    end
    data = {
      :client_state => @client_state,
      :server_state => @server_state,
      :names_by_ip => @names_by_ip
    }
    File.open(@state_filename, "w") {|io| Marshal.dump(data, io) }
    @last_saved = Time.now
  end

  def load
    if FileTest.exists? @state_filename
      data = nil
      File.open(@state_filename, "r") {|io| data = Marshal.load(io) }
      if data
        @client_state = data[:client_state] || []
        @server_state = data[:server_state] || ServerState.new
        @names_by_ip = data[:names_by_ip] || {}
        true
      end
    end
  end

  def autosave
    save unless @last_saved  &&  (Time.now - @last_saved) < AutoSaveFreq
  end

  def get_akas_for_ip(ip, current_name = nil)
    names = @names_by_ip[ip] || {}
    name_keys = names.keys.delete_if {|n| n == current_name}
    name_keys.sort! do |a,b|
      recent = (names[b][:last_seen]  - names[a][:last_seen]) / (60.0 * 60 * 24)
      times  = (names[b][:times_seen] - names[a][:times_seen]).to_f
      recent + times
    end
    # name_keys = name_keys.map {|n| "#{n}(#{names[n][:last_seen]})(#{names[n][:times_seen]})" }
    name_keys
  end

  def get_top_akas_for_ip(ip, current_name = nil, limit = STATUS_ALIASES_LIMIT)
    akas = get_akas_for_ip(ip, current_name)
    num_akas = akas.length
    if num_akas > (limit + 1)
      akas = akas[0..(limit - 1)]
      akas << "(#{num_akas - limit} more)"
    end
    akas
  end

  def status
    status_str = ""
    hostname = @server_state['hostname'] || "?"
    map =      @server_state['mapname'] || "?"
    dmflags =  @server_state['dmflags'] || "?"
    fl =       @server_state['fraglimit'] || "?"
    tl =       @server_state['timelimit'] || "?"
    cheats =   @server_state['cheats'] || "?"
    status_str << sprintf("%s: map:%s / dmflags:%s / fraglimit:%s / timelimit:%s / cheats:%s\n",
                          hostname, map, dmflags, fl, tl, cheats)
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

  def known_ips_with_names
    resp = ""
    ips_by_last_seen = get_ips_by_last_seen
    ips = names_by_ip.keys.sort_by {|ip| ips_by_last_seen[ip].to_f}
    ips.each do |ip|
      akas = get_akas_for_ip(ip).join(", ")
      seen = ips_by_last_seen[ip]
      since = (Time.now - seen).to_i
      resp << sprintf("%-15s %15s %s\n", ip, fmt_time_ago(since), akas)
    end
    resp
  end

  def known_names_with_ips
    resp = ""
    ips_by_name = get_ips_by_name
    ips_by_last_seen = get_ips_by_last_seen
    names = ips_by_name.keys.sort {|a,b| a.downcase <=> b.downcase}
    names.each do |name|
      ips = ips_by_name[name][:ips].keys.sort{|a,b| ips_by_last_seen[b] <=> ips_by_last_seen[a]}.join(", ")
      seen = ips_by_name[name][:last_seen]
      since = (Time.now - seen).to_i
      resp << sprintf("%-15s %15s %s\n", name, fmt_time_ago(since), ips)
    end
    resp
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

  def get_ips_by_name
    ips_by_name = {}
    names_by_ip.each do |ip, ipnames|
      ipnames.keys.each do |name|
        ips_by_name[name] ||= {}
        ips_by_name[name][:ips] ||= {}
        ips_by_name[name][:ips][ip] = true
        last_seen = ips_by_name[name][:last_seen] || Time.at(0)
        new_last_seen = names_by_ip[ip][name][:last_seen]
        ips_by_name[name][:last_seen] = (new_last_seen > last_seen)? new_last_seen : last_seen
      end
    end
    ips_by_name
  end

  def get_ips_by_last_seen
    ips_by_last_seen = {}
    names_by_ip.each do |ip, ipnames|
      ips_by_last_seen[ip] = Time.at(0)
      ipnames.keys.each do |name|
        name_last_seen = names_by_ip[ip][name][:last_seen]
        ips_by_last_seen[ip] = name_last_seen if (name_last_seen > ips_by_last_seen[ip])
      end
    end
    ips_by_last_seen
  end

  private

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
    names = @names_by_ip[ip] || {}
    stats = names[name] || {}
    stats[:last_seen] = Time.now
    times_inc = update_times_seen ? 1 : 0
    stats[:times_seen] = ((stats[:times_seen] || 0) + times_inc)
    names[name] = stats
    @names_by_ip[ip] = names
  end
 
end
