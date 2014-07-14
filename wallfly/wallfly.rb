
require 'thread'
require 'fastthread'
require 'timeout'
require 'yaml/store'
require 'dorkbuster-client'

INVITE_CMD_NAME = "./invite.sh"
HAVE_INVITE_CMD = File.exist? INVITE_CMD_NAME
PROXYBAN_CMD_NAME = "./proxyban.sh"
HAVE_PROXYBAN_CMD = false  # File.exist? PROXYBAN_CMD_NAME

class MapSpec
  attr_reader :shortname, :dmflags, :key
  attr_accessor :oneshot, :forceplay

  def initialize(mapspec_str, key="")
    @key = key
    if mapspec_str =~ /\A([^\(\s]+)\(([^\)]*)\)\z/
      @shortname = $1
      @dmflags = $2
    else
      @shortname = mapspec_str
      @dmflags = nil
    end
    @oneshot = false
    @forceplay = false
  end
  
  def strip_dmflag(flag)
    return unless @dmflags
    @dmflags.gsub!(flag, "")
    @dmflags.squeeze! " "
    @dmflags.strip!
    @dmflags = nil if @dmflags.empty?
  end

  def to_s
    @shortname + (@dmflags ? "(#@dmflags)" : "")
  end
end


# thinking of adding a "prelist" onto MapRot
# where maps can be pushed, appended, removed-by-key
# and which depletes as maps are advanced (pop_front'd)
# er.. shift'd...
#  - was going to delete-by-key, then append..
#    this means person can't change their selection tho
#    w/out losing their place.. good? bad?  possibly good
#    if it keeps weenie-types from mcFucking around
#    and making annoying changes at last second, or 
#    spamming changes etc... losing place is disincentive

class MapRot

  REPEAT_FLAG = "-repeat"

  def initialize(maplist_str="")
    reset(maplist_str)
  end

  def reset(maplist_str)
    @repeat = false
    @consecutive_rotation_maps_played = 0
    @onlist_oneshot_defer_proc = lambda{0}
    @offlist_oneshot_defer_proc = lambda{0}
    maplist_str.gsub!(/#{REPEAT_FLAG}/o) { @repeat = true; "" }
    @maplist = maplist_str.scan(/[^\(\s]+(?:\([^\)]*\))?/).map {|m| MapSpec.new(m)}
    build_rotmaps_hash
  end

  def clear
    reset("")
  end

  def set_onlist_oneshot_defer_proc(proc_=nil, &block)
    @onlist_oneshot_defer_proc = proc_ || block
  end

  def set_offlist_oneshot_defer_proc(proc_=nil, &block)
    @offlist_oneshot_defer_proc = proc_ || block
  end

  def push_at_head(mapspec)
    @maplist.unshift mapspec
    @rotmaps[mapspec.shortname] = true unless mapspec.oneshot
  end

  def push_oneshot(mapspec)
    push_oneshot_without_respace(mapspec)
    respace_oneshot_maps # if priority_onlist_scheduling && is_rotmap
  end

  def remove_by_key(key)
    orig_len = @maplist.length
    @maplist.delete_if {|map| map.key == key }
    if @maplist.length != orig_len
      build_rotmaps_hash
      respace_oneshot_maps 
    end
  end

  def length
    @maplist.length
  end

  def peek_next
    @maplist[0]
  end

  def advance(map_was_played=true)
    map = @maplist.shift
    @maplist.push map if @repeat && map && ! map.oneshot
    if map_was_played
      update_consecutive_play_count(map)
    end
  end  

  def next_n_maps(num=@maplist.length)
    @maplist[0..(num - 1)]
  end
  
  def tidy_after_skipped_maps
    respace_oneshot_maps
  end

  def to_s
    if @maplist.empty?
      "-none"
    else
      str = @maplist.join(" ")
      str << (" " + REPEAT_FLAG) if @repeat
      str
    end
  end

  protected

  def using_onlist_offlist_deferral?
    @onlist_oneshot_defer_proc.call.nonzero? or @offlist_oneshot_defer_proc.call.nonzero?
  end

  def using_onlist_deferral?
    @onlist_oneshot_defer_proc.call.nonzero?
  end

  def build_rotmaps_hash
    @rotmaps = {}
    @maplist.each {|m| @rotmaps[m.shortname] = true unless m.oneshot}
  end

  def push_oneshot_without_respace(mapspec)
    mapspec.oneshot = true
    is_rotmap = is_rotation_map? mapspec
    priority_onlist_scheduling = ! using_onlist_deferral?
    idx = mapspec.forceplay ? 0 : find_oneshot_push_idx(is_rotmap, priority_onlist_scheduling)
    @maplist.insert(idx, mapspec)
  end

  def respace_oneshot_maps
    return unless using_onlist_offlist_deferral?
    begin
      prev_listorder = @maplist.collect {|m| m.shortname}
      oneshots, rotmaps = @maplist.partition {|m| m.oneshot}
# warn "respace: oneshots=[#{oneshots.join(' ')}] rotmaps=[#{rotmaps.join(' ')}]"
      @maplist = rotmaps
      oneshots.each {|m| push_oneshot_without_respace(m)}
      new_listorder = @maplist.collect {|m| m.shortname}
    end while new_listorder != prev_listorder
  end

  def find_oneshot_push_idx(is_rotmap, priority_onlist_scheduling)
    if using_onlist_offlist_deferral?
      find_oneshot_push_idx_with_deferral(is_rotmap, priority_onlist_scheduling)
    else
      idx = 0
      idx += 1 while (map = @maplist[idx]) && map.oneshot
      idx
    end
  end

  def find_oneshot_push_idx_with_deferral(is_rotmap, priority_onlist_scheduling)
    if is_rotmap && priority_onlist_scheduling
      idx = find_priority_rotmap_insert_point
    else
      idx = find_unified_oneshot_insert_point
      break_on_any_oneshot = is_rotmap
      prior = count_prior_rotmaps_from(idx, break_on_any_oneshot)
      prior += @consecutive_rotation_maps_played if prior == idx
      defer = is_rotmap ? @onlist_oneshot_defer_proc.call : @offlist_oneshot_defer_proc.call
      defer = [defer - prior, 0].max
      idx += defer
    end
    [idx, @maplist.length].min
  end

  def count_prior_rotmaps_from(idx, break_on_any_oneshot=false)
    prior = 0
    (idx - 1).downto(0) do |i|
      map = @maplist[i]
      break if (break_on_any_oneshot && map.oneshot) || (! is_rotation_map?(map))
      prior += 1
    end
    prior
  end

  def find_unified_oneshot_insert_point
    idx = last_oneshot_idx
    idx ? idx + 1 : 0
  end

  def find_priority_rotmap_insert_point
    idx = last_oneshot_idx
    if idx
      oridx = last_oneshot_idx(true)
      oridx ||= -1
      ridx = first_non_oneshot_between(oridx, idx)
      if ridx
        idx = ridx
      else
        idx += 1
      end
    else
      idx = 0
    end
    idx
  end

  def last_oneshot_idx(rotmaps_only=false)
    idx = nil
    0.upto(@maplist.length - 1) do |i|
      idx = i if (map = @maplist[i]) && map.oneshot && (!rotmaps_only || is_rotation_map?(map))
    end
    idx
  end

  def first_non_oneshot_between(idx, idx2)
# warn("anob: #{idx}, #{idx2}")
    idx += 1
    idx2 -= 1
    return nil unless idx <= idx2
    idx.upto(idx2) do |i|
      return i if (map = @maplist[i]) && (! map.oneshot)
    end
    nil
  end

  def update_consecutive_play_count(map)
    is_rotmap = is_rotation_map? map
    if map.oneshot && (!is_rotmap || using_onlist_deferral?)
      @consecutive_rotation_maps_played = 0
    else
      @consecutive_rotation_maps_played += 1 if is_rotmap
    end 
  end

  def is_rotation_map?(map)
    # @maplist.any? {|m| (! m.oneshot) && (m.shortname == map.shortname)}
    @rotmaps[map.shortname]
  end
end


# class WallflyMemory
#   def initialize(filename = "wf-memory.ystore")
#     @memfilename = filename
#   end
#   
#   def mapdef()
#   end
# 
# end
# 

class BindSpamTracker
  CLEAN_INTERVAL_SECS = 15 * 60

  def initialize(time_proc)
    @time_proc = time_proc
    @bs = {}
    @bs_memory = {}
    @next_clean_time = @time_proc.call + CLEAN_INTERVAL_SECS
  end

  def track(chat, trigger_at_num, trigger_window_seconds, trigger_memory_seconds, use_memory=true)
    key = self.class.gen_bindspam_key(chat)
    node = (@bs[key] ||= [])
    cur_time = @time_proc.call
    expire_time = cur_time - trigger_window_seconds
    node << cur_time
    expire_old_node_times(node, expire_time)
    triggered = (node.length >= trigger_at_num)
    if triggered
      @bs_memory[key] = cur_time
    end
    should_filter = triggered || (use_memory && @bs_memory[key] && (cur_time - @bs_memory[key]) <= trigger_memory_seconds)
    if cur_time >= @next_clean_time
      clean_bs(expire_time)
      clean_bs_memory(cur_time - trigger_memory_seconds)
      @next_clean_time = cur_time + CLEAN_INTERVAL_SECS
    end
    should_filter
  end

  def self.gen_bindspam_key(text)
    text.downcase.gsub(/\s+/, "")
  end

  protected

  def clean_bs(expire_time)
    moribund_keys = []
    @bs.each_pair do |key, node|
      expire_old_node_times(node, expire_time)
      moribund_keys << key if node.empty?
    end
    moribund_keys.each {|key| @bs.delete key}
  end

  def expire_old_node_times(node, expire_time)
    node.shift while node.first && node.first < expire_time
  end

  def clean_bs_memory(expire_time)
    moribund_keys = []
    @bs_memory.each_pair do |key, time|
      moribund_keys << key if time < expire_time
    end
    moribund_keys.each {|key| @bs_memory.delete key}
  end
end


class CompiledBan
  attr_reader :raw_expr
  
  def initialize(ban_expr)
    @raw_expr = ban_expr
    @matcher_procs = []
    compile(raw_expr)
  end
  
  class MatchState
    TYPE_IPHOST = :iphost
    TYPE_NAMEEQ = :nameeq
    TYPE_NAMENE = :namene
    TYPES = [TYPE_IPHOST, TYPE_NAMEEQ, TYPE_NAMENE]
    def initialize
      @st = {}
    end
    def input(type, matched)
      dat = (@st[type] ||= [])
      dat[0] ||= 0
      dat[0] += 1
      case type
      when TYPE_IPHOST, TYPE_NAMEEQ
        dat[1] ||= matched
      when TYPE_NAMENE
        dat[1] = true if dat[1].nil?
	dat[1] &&= matched
      end
    end
    def trigger?
      return false unless TYPES.any? {|t| @st.has_key? t}
      trigger = true
      TYPES.each do |t|
        dat = @st[t]
        trigger &&= dat[1] if dat
      end
      trigger
    end
    def partial?
      @st.has_key?(TYPE_IPHOST) && @st[TYPE_IPHOST][1]
    end
  end

  def match(playername, ip, rdns_host)
    mst = MatchState.new
    nprocs = @matcher_procs.length
    return mst unless nprocs > 0
    @matcher_procs.each do |mp|
      type, matched = mp[playername, ip, rdns_host]
      mst.input(type, matched)
    end
    mst
  end
  
  private
  
  # cpe-.*hawaii.res.rr.com,name!=dr\.death\(dxm\)
  def compile(compound_expr)
    exprs = compound_expr.split(/,/)
    exprs.each do |ex|
      case ex
      when /^name([!=]=)(\S+)$/ then compile_name_match($1, $2)
      else compile_ip_dns_match(ex)
      end
    end
  end
  
  def compile_name_match(op, regex_str)
    regex = Regexp.new(regex_str, Regexp::IGNORECASE)
    negate = (op == "!=")
    type = negate ? MatchState::TYPE_NAMENE : MatchState::TYPE_NAMEEQ
    @matcher_procs << Proc.new do |playername, ip, rdns_host|
      matched = regex.match(playername)
      matched = negate ? !matched : matched
      [type, matched]
    end
  end

  def compile_ip_dns_match(regex_str)
    regex = Regexp.new(regex_str, Regexp::IGNORECASE)
    type = MatchState::TYPE_IPHOST
    @matcher_procs << Proc.new do |playername, ip, rdns_host|
      matched = !!(regex.match(rdns_host) || regex.match(ip))
      [type, matched]
    end
  end
end


class Wallfly
  attr_reader :db, :bans
  attr_accessor :debounce_nextmap_trigger

  SHOW_NUM_NEXTMAPS = 10
  NEXTMAP_TRIGGER_DEBOUNCE_THRESHOLD_SECS = 10
  DMFLAGS_CMD_STR = %{dmflags }
  FASTMAP_CMD_STR = %{rcon gamemap }

  NameChangeTrack = Struct.new(:name, :time)

  def initialize(sock, db_username, db_password, state_fname, bans_fname, sv_nick, q2wfip)
    @db = DorkBusterClient.new(sock, db_username, db_password)
    @state_fname = state_fname
    @bans_fname = bans_fname
    @sv_nick = sv_nick
    @q2wallfly_ip = q2wfip
    @debounce_nextmap_trigger = true
    self.class.load_servers_config
    reset
    restore_state
    reload_bans_if_changed
  end

  def close
    @db.close
  end

  def reset
    @maprot = MapRot.new
    hook_maprot_defer_procs
    @votemaps = {}
    @bans = {}
    @compiled_bans = {}
    @stifle_clnum = {}
    @bs_tracker = BindSpamTracker.new( self.method(:cur_time).to_proc )
    @issued_chatban_enable = false
    @last_bans_fsize = 0
    @last_bans_mtime = Time.at(0)
    @vars = Hash.new("".freeze)
    @vars['defflags'] = ""
    @vars['default/stifle'] = "60"
    @vars['delay/same_map'] = "0"
    @vars['delay/ia'] = "0"
    @vars['delay/ws'] = "0"
    @vars['delay/h'] = "0"
    @vars['delay/invite'] = "300"
    @vars['delay/goto_name_change'] = "6"
    @vars['mymap/defer_onlist'] = "0"
    @vars['mymap/defer_offlist'] = "0"
    @vars['pu_off/quad']  = ""
    @vars['pu_off/invul'] = ""
    @vars['pu_on/quad']   = ""   # "item_quad"
    @vars['pu_on/invul']  = ""   # "item_invulnerability"
    @vars['bindspam_chatban/enable'] = "no"
    @vars['bindspam_chatban/min_text_length'] = "10"
    @vars['bindspam_chatban/short_text_mute_enable'] = "yes"
    @vars['bindspam_chatban/short_text_mute_secs'] = "45"
    @vars['bindspam_chatban/trigger_at_num'] = "5"
    @vars['bindspam_chatban/trigger_memory_seconds'] = "600"
    @vars['bindspam_chatban/trigger_window_seconds'] = "180"
    @vars['bindspam_chatban/trigger_window_seconds_short'] = "45" # should be <= short_text_mute_secs
    @last_nextmap_trigger_time = Time.at(0)
    @last_ia_time = Time.at(0)
    @last_ws_time = Time.at(0)
    @last_h_time = Time.at(0)
    @last_invite_time = Hash.new(Time.at(0))
    @map_last_played = Hash.new(Time.at(0))
    @name_change_track = []
    @proxy_check_track = {}
    @proxy_check_last_prune_time = Time.at(0)
    @done = false
  end

  def self.load_servers_config
    # FOR NOW, just always reload the all-servers.cfg file.
    # (It would be nice to someday check the file size & mod date,
    # and only reload it if it's changed.)
    begin
      old_verbose = $VERBOSE
      $VERBOSE = nil
      load 'all-servers.cfg'
    ensure
      $VERBOSE = old_verbose
    end
  end

  def restore_state
    if test ?f, @state_fname
      ystore = YAML::Store.new(@state_fname)
      read_only = true
      ystore.transaction(read_only) do
        @maprot   = ystore["maprot"]   || @maprot
        hook_maprot_defer_procs
        @votemaps = ystore["votemaps"] || @votemaps
        vars_ = ystore["vars"] || {}
        # old scheme resulted in a proliferation of keys with empty values
        # ...let's clean them up.  This code can be deleted as this cleanup
        # is a one-shot deal.
        empties = []
        vars_.each_pair {|k,v| empties << k if v.to_s.strip.empty?}
        empties.each {|k| vars_.delete k}
        # end cleanup code
        @vars.merge!(vars_)
        @last_ia_time = ystore["last_ia_time"] || @last_ia_time
        @last_ws_time = ystore["last_ws_time"] || @last_ws_time
        @last_h_time = ystore["last_h_time"] || @last_h_time
        @map_last_played.merge!( ystore["map_last_played"] || {} )
      end
    end
  end
  
  def save_state
    begin
      do_save_state
    rescue SignalException, SystemExit => ex
      # If someone sent us a TERM or INT signal, for example, let's try
      # saving the data again... we may have gotten interrupted right
      # in the middle.
      do_save_state
      raise
    end
  end

  def do_save_state
    begin
      unhook_maprot_defer_procs
      ystore = YAML::Store.new(@state_fname)
      ystore.transaction do
        ystore["maprot"]          = @maprot
        ystore["votemaps"]        = @votemaps
        ystore["vars"]            = @vars
        ystore["last_ia_time"]    = @last_ia_time
        ystore["last_ws_time"]    = @last_ws_time
        ystore["last_h_time"]     = @last_h_time
        ystore["map_last_played"] = @map_last_played
      end
    ensure
      hook_maprot_defer_procs
    end
  end

  def hook_maprot_defer_procs
    @maprot.set_onlist_oneshot_defer_proc {@vars['mymap/defer_onlist'].to_i}
    @maprot.set_offlist_oneshot_defer_proc {@vars['mymap/defer_offlist'].to_i}
    # KLUDGE: the saved state for maprot objects may not yet have this
    # newly added instance var... so set the f'n thing if it doesn't exist:
    @maprot.instance_eval { @consecutive_rotation_maps_played ||= 0 }
    @maprot.instance_eval { build_rotmaps_hash }
  end

  def unhook_maprot_defer_procs
    # NOTE: this unhook sets nil values for the procs so that
    # the maprot object can be marshalled.
    # The maplist object should not be left in this unhooked state
    # as nil is not a valid state for these procs.
    # (Their correct default is lambda{0} ... but we can't marshal that.)
    @maprot.set_onlist_oneshot_defer_proc(nil)
    @maprot.set_offlist_oneshot_defer_proc(nil)
  end

  def reload_bans_if_changed
    bans_stat = File.stat(@bans_fname) rescue nil
    if bans_stat
      changed = (@last_bans_fsize != bans_stat.size) || (@last_bans_mtime != bans_stat.mtime)
      if changed
	replylog("reloading banfile: #@bans_fname")
        ystore = YAML::Store.new(@bans_fname)
        read_only = true
        ystore.transaction(read_only) do
          @bans = ystore["bans"] || @bans
        end
        @last_bans_fsize = bans_stat.size
        @last_bans_mtime = bans_stat.mtime
      end
    end
  end

  def transact_bans
    ystore = YAML::Store.new(@bans_fname)
    ystore.transaction do
      ystore["bans"] = {} unless ystore.root?("bans")
      yield ystore["bans"]
      @bans = ystore["bans"]
    end
    # RACE CONDITION: We mean to snapshot the file size/mtime immediately
    # following our transaction.  But another process could slip in between
    # before our stat().  This won't cause us to lose data but it could
    # cause us not to refresh bans added by another process in a timely
    # fashion (because reload_bans_if_changed would not take any action.)
    bans_stat = File.stat(@bans_fname) rescue nil
    if bans_stat
      @last_bans_fsize = bans_stat.size
      @last_bans_mtime = bans_stat.mtime
    end
  end

  def login
    @db.login
  end

  def reply(str)
    $stderr.puts "[reply(#{str.inspect})]"
    @db.speak(str)
  end
  
  def replylog(str)
    reply(">log #{str}")
  end

  def run
    @done = false
    while not @done
      reload_bans_if_changed
      @db.get_parse_new_data
      while dbline = @db.next_parsed_line
        puts dbline.raw_line
        cmd = dbline.cmd.strip
        if dbline.is_db_user?
          if cmd =~ /\Awf,?\s+nextmap(?:\s+(\S.*))?\z/i
            cmd_nextmap($1.to_s.strip)
          elsif cmd =~ /\Awf,?\s+votemaps-set(?:\s+(\S.*))?\z/i
            cmd_votemaps($1.to_s.strip)
          elsif cmd =~ /\Awf,?\s+votemaps-add(?:\s+(\S.*))?\z/i
            cmd_votemaps_add($1.to_s.strip)
          elsif cmd =~ /\Awf,?\s+votemaps-remove(?:\s+(\S.*))?\z/i
            cmd_votemaps_remove($1.to_s.strip)
          elsif cmd =~ /\Awf,?\s+insmap(?:\s+(\S.*))?\z/i
            cmd_insmap($1.to_s.strip)
          elsif cmd =~ /\Awf,?\s+delmap(?:\s+(\S.*))?\z/i
            cmd_delmap
          elsif cmd =~ /\Awf,?\s+defflags(?:\s+(\S.*))?\z/i
            cmd_defflags($1.to_s.strip)
          elsif cmd =~ /\Awf,?\s+ban(?:\s+(\S+)(?:\s+(\S.*))?)?\z/i
            cmd_ban($1, $2, :ban, dbline.speaker)
          elsif cmd =~ /\Awf,?\s+unban(?:\s+(\S.*))?\z/i
            cmd_unban($1, :ban)
          elsif cmd =~ /\Awf,?\s+mute(?:\s+(\S+)(?:\s+(\S.*))?)?\z/i
            cmd_ban($1, $2, :mute, dbline.speaker)
          elsif cmd =~ /\Awf,?\s+stifle(?:\s+(\S+)(?:\s+(\S.*))?)?\z/i
            cmd_stifle($1, $2, dbline.speaker)
          elsif cmd =~ /\Awf,?\s+unmute(?:\s+(\S.*))?\z/i
            cmd_unban($1, :mute)
          elsif cmd =~ /\Awf,?\s+set(?:\s+(\S+)(?:\s+(\S.*))?)?\z/i
            cmd_set($1, $2)
          elsif cmd =~ /\Awf,?\s+unset(?:\s+(\S+)(?:\s+(\S.*))?)?\z/i
            cmd_unset($1)
          elsif cmd =~ /\Awf,?\s+logout\z/i
            cmd_logout(dbline)
          # leading-slash commands, for compatibility with old HAL commands:
          elsif cmd =~ /\A\/probe(?:\s+(\S.*))?\z/i
            cmd_probe($1)
          end
        elsif dbline.is_player_chat?
          handled = false
          if cmd =~ /\A(.*?):\s+([\w!]+)(?:\s+(\S.*))?\z/
            playername, wfcmd, args = $1, $2, $3.to_s.strip
            playername.gsub!(/\A\((.*)\)\z/, "\\1")  # assume (playername) is mm2 and strip parens
            if wfcmd =~ /\A(!aliases|invite!|goto|mymap|nextmap)\z/
              handled = true
              wfarg, clnum, ip = parse_clnum_ip(args)
              unless clnum.nil?
                case wfcmd
                # remember: we won't get here unless regex above matches
                when "!aliases" then cmd_player_aliases(playername, wfarg, clnum, ip)
                when "invite!"  then cmd_player_invite(playername, wfarg, clnum, ip)
                when "goto"     then cmd_player_goto(playername, wfarg, clnum, ip)
                when "mymap"    then cmd_player_mymap(playername, wfarg, clnum, ip)
                when "nextmap"  then cmd_player_nextmap(playername, wfarg, clnum, ip)
                end
              else
                safe_playername = make_rcon_quotesafe(playername)
                reply(%{rcon say Sorry "#{safe_playername}", couldn't uniquely identify you. Is someone else using your name?})
              end
            end
          elsif cmd =~ /\A(.*) changed name to (.*)\z/
            update_name_change_tracking($1, $2)
          end
          if cmd =~ /\A(.*?):\s+(.+?)\s*\z/
            # NOTE: playername may be wrong if name has colons and spaces in it :(
            playername, chat = $1, $2
            chat, clnum, ip = parse_clnum_ip(chat)
            unless chat =~ /\Agoto\z/i
              enforce_stifle(playername, clnum, ip)
            end
            unless handled
              cmd_player_chatban_bindspam(playername, clnum, ip, chat)
            end
          end
        elsif dbline.is_connect?
          if cmd =~ /\[(\d+)\]\s+"([^"]*)"\s+(\d+\.\d+\.\d+\.\d+):\d+/
            clnum, playername, ip = $1, $2, $3
            handle_player_connect(playername, clnum, ip)
          end
        elsif dbline.is_enter_game?
          if cmd =~ /\[(\d+)\]\s+"([^"]*)"\s+(\d+\.\d+\.\d+\.\d+):\d+/
            clnum, playername, ip = $1, $2, $3
            handle_player_enter_game(playername, clnum, ip)
          end
        elsif dbline.is_disconnect?
          if cmd =~ /\[(\d+)\]\s+"([^"]*)"\s+(\d+\.\d+\.\d+\.\d+):\d+\s+score/
            clnum, playername, ip = $1, $2, $3
            handle_player_disconnect(playername, clnum, ip)
          end
        elsif dbline.is_map_over?
          trigger_map_over
        elsif dbline.is_name_change?
          # 12:34:56 NAME_CHANGE: [11] "rat"     123.45.67.89:27901 was: MaryBottins
          if cmd =~ /\[(\d+)\]\s+"([^"]*)"\s+(\d+\.\d+\.\d+\.\d+):\d+/
            clnum, playername, ip = $1, $2, $3
            handle_name_change(playername, clnum, ip)
          end
        end
      end
      @done = true if @db.eof
      @db.wait_new_data unless @done
    end
  end

  def cur_time; Time.now end

  def cur_maprot; @maprot end
  def votemaps;   @votemaps end
  def vars;       @vars end
  def defflags;   vars["defflags"] end

  def parse_clnum_ip(playerchat)
    if playerchat =~ /\A(.*)(?:\[(\d+)\|(\d+\.\d+\.\d+\.\d+)\]|\[\?\])/
      [$1.strip, $2, $3]
    else
      [playerchat, nil, nil]
    end
  end

  def legal_varname?(varname)
    varname =~ /\A[\w\/!_-]+\z/
  end

  def bt(term, ban_type)
    if ban_type == :mute
      term = case term
      when "BAN" then "MUTE"
      when "Ban" then "Mute"
      when "ban" then "mute"
      when "bans" then "mutes"
      else term
      end
    end
    term
  end

  def ban_info_from_reason(reason)
    type = nil
    flags = {}
    if reason =~ / -mute(?:\s+(\d+))?$/
      type = :mute
      flags[:stifle_interval] = $1 ? $1.to_i : nil
    else
      type = :ban
    end
    [type, flags]
  end

  def ban_type_from_reason(reason)
    # (reason =~ / -mute(\s+\d+)?$/) ? :mute : :ban
    type, flags = ban_info_from_reason(reason)
    type
  end

  def gen_ban_timestamp
    cur_time.strftime("%Y-%m-%d")
  end

  def gen_ban_reason(reason, ban_type, admin_name, flags)
    reason = reason.to_s.dup.strip.gsub(/\s+/, "_")
    tstamp = gen_ban_timestamp
    reason << "__#{admin_name}__#{tstamp}"
    if ban_type == :mute
      stifle_interval = flags[:stifle_interval] || 0
      reason = "#{reason} -mute #{stifle_interval}" 
    end
    reason
  end

  def cmd_ban(ban_expr, reason, ban_type, admin_name, flags={})
    if ban_expr
      if reason && !reason.to_s.strip.empty?
	reason = gen_ban_reason(reason, ban_type, admin_name, flags)
        ban, err = memo_compile_ban(ban_expr)
        if err
          reply(%{^aFailed to compile #{bt('ban',ban_type)} expression: #{err}})
        else
          transact_bans do |bans_hash|
            bans_hash[ban_expr] = reason
          end
          reply("#{bt('Ban',ban_type)} added.")
        end
      else
        reply(%{^aPlease specify additional info, such as who this #{bt('ban',ban_type)} applies to, and why.})
      end
    else
      matching_bans = @bans.keys.select {|ban_expr| ban_type_from_reason(@bans[ban_expr]) == ban_type}
      if matching_bans.empty?
        reply("No #{bt('bans',ban_type)} in database.")
      else
        matching_bans.sort.each do |ban_expr|
          reason = @bans[ban_expr]
          this_ban_type = ban_type_from_reason(reason)
          replylog(%{#{bt('BAN',this_ban_type)} RULE: #{ban_expr} REASON: "#{reason}"})
        end
      end
    end
  end
  
  def cmd_unban(ban_expr, ban_type)
    if ban_expr
      if @bans.has_key? ban_expr
        ban_reason = @bans[ban_expr]
        this_ban_type = ban_type_from_reason(ban_reason)
        if ban_type == this_ban_type
          @compiled_bans.delete(ban_expr)
          transact_bans do |bans_hash|
            bans_hash.delete(ban_expr)
          end
          reply(%{#{bt('BAN',this_ban_type)} RULE: #{ban_expr} ("#{ban_reason}") removed.})
        else
          reply(%{Oops, #{ban_expr} looks like a #{this_ban_type} rather than a #{ban_type}. No action taken.})
        end
      else
        reply(%{Can't #{bt('unban',this_ban_type)}, RULE "#{ban_expr}" not found.})
      end
    else
      reply(%{Please specify which #{bt('ban',this_ban_type)} rule to remove.})
    end
  end

  def cmd_stifle(ban_expr, reason, admin_name)
    stint = @vars['default/stifle'].to_i
    if ban_expr
      if stint < 1
        reply(%{Error: The "default/stifle" variable must be set to the number of seconds the player is to be muted after they speak.})
      else
        flags = {:stifle_interval => stint}
        cmd_ban(ban_expr, reason, :mute, admin_name, flags)
      end
    else
      reply(%{Stifle: The player will be muted for "default/stifle" = #{stint} seconds after they speak.})
    end
  end

  def cmd_set(varname, value)
    if varname
      if not legal_varname?(varname)
        reply("illegal characters in varname")
      else
        if value
          vars[varname] = value
          reply(%{"#{varname}" => #{value}})
          save_state
        else
          if vars.has_key? varname
            value = vars[varname]
            reply(%{"#{varname}" => #{value}})
          else
            reply(%{"#{varname}" is not set})
          end
        end
      end
    else
      vars.keys.sort.each do |varname|
        value = vars[varname]
        replylog(%{"#{varname}" => #{value}})
      end
    end
  end

  def cmd_unset(varname)
    if varname
      if not legal_varname?(varname)
        reply("illegal characters in varname")
      else
        vars.delete varname
        save_state
      end      
    end
  end

  def cmd_nextmap(mapnames)
    if ! mapnames.empty?
      if mapnames =~ /\A-none\z/
        cur_maprot.clear
      else
        cur_maprot.reset(mapnames)
      end
      save_state
    end
    replylog("nextmap => #{cur_maprot}")
  end

  def cmd_votemaps(mapnames)
    if not mapnames.empty?
      votemaps.clear
      if mapnames !~ /\A-none\z/
        mapnames.split.each {|name| votemaps[name] = true}
      end
      save_state
    end
    replylog("votemaps => #{votemaps.keys.sort.join(' ')}")
  end
  
  def cmd_votemaps_add(mapnames)
    if mapnames.empty?
      reply("Please specify one or more maps to add to the existing votemap list")
    else
      mapnames.split.each {|name| votemaps[name] = true}
      save_state
      replylog("votemaps => #{votemaps.keys.sort.join(' ')}")
    end
  end

  def cmd_votemaps_remove(mapnames)
    if mapnames.empty?
      reply("Please specify one or more maps to remove from the existing votemap list")
    else
      mapnames.split.each {|name| votemaps.delete name}
      save_state
      replylog("votemaps => #{votemaps.keys.sort.join(' ')}")
    end
  end

  def cmd_insmap(mapname_with_optional_dmflags)
    if mapname_with_optional_dmflags.strip.empty?
      reply("Push a one-shot map onto the playlist.")
      reply("Example: wf insmap q2dm1(+pu -ws)")
    else
      ip = "127.0.0.1"
      mspec = MapSpec.new(mapname_with_optional_dmflags, ip)
      mspec.oneshot = true
      mspec.forceplay = true
      cur_maprot.push_at_head mspec
      save_state
      cmd_nextmap("")
    end
  end

  def cmd_delmap
    mspec = cur_maprot.peek_next
    if mspec && mspec.oneshot
      cur_maprot.advance
      save_state
      cmd_nextmap("")
    else
      reply("No one-shot map found at head of playlist.")
    end
  end

  def cmd_defflags(flags)
    if not flags.empty?
      if flags =~ /\A-none\z/
        defflags.replace ""
      else
        defflags.replace flags
      end
      save_state
    end
    reply("defflags => #{defflags}")
  end

  # 12:34:01 * l33t_]<w4k3r_d00d: mymap fubar +pu +a -h +ia            [12|67.19.248.74]\r\n} +

  SANITIZE_NON_ASCII_REGEX = /[\000-\037\200-\377]/

  def make_rcon_quotesafe(playername)
    playername.gsub(SANITIZE_NON_ASCII_REGEX, "*").tr('$"',"+'")
  end

  def make_shell_quotesafe(str)
    str.gsub(SANITIZE_NON_ASCII_REGEX, "*").tr("\"'\\$","~~/+")
  end

  # Returns a positive integer indicating the number of seconds
  # until another invite command will next be allowed,
  # or -1 if invite is disabled.
  def calc_invite_next_allowed_secs(client_ip)
    return -1 unless HAVE_INVITE_CMD &&  ! $TESTING
    invite_delay = vars['delay/invite'].to_s.strip.to_i
    return -1 if invite_delay <= 0
    time_now = cur_time
    [@sv_nick.intern, client_ip].map do |key|
      next_allowed = ((@last_invite_time[key] + invite_delay) - time_now).to_i
      next_allowed = 0 if next_allowed < 0
      next_allowed
    end.max
  end

  def exec_invite_cmd(playername, on_server, message)
    playername = make_shell_quotesafe(playername)
    message = make_shell_quotesafe(message)
    on_server = make_shell_quotesafe(on_server)
    Thread.new do
      invcmd = IO.popen(%{#{INVITE_CMD_NAME} '#{playername}' '#{on_server}' '#{message}'})
      sleep(5)
      Process.kill("KILL", invcmd.pid) rescue nil
      Process.wait(invcmd.pid, Process::WNOHANG) rescue nil
    end
  end

  def cmd_player_invite(playername, message, clnum, ip)
    if (secs = calc_invite_next_allowed_secs(ip)) < 0
      reply(%{rcon sv !say_person cl #{clnum} Sorry, 'invite' is not available on this server at this time.})
    elsif secs > 10
      reply(%{rcon sv !say_person cl #{clnum} Sorry, 'invite' has been used too recently. Try again in #{secs} seconds.})
    elsif "#{playername} #{message}" =~ /!(aliases|version|r1q2_version|nocheatsay|q2advancesay)/i
      reply(%{rcon sv !mute cl #{clnum} PERM})
      reply(%{rcon sv !say_person cl #{clnum} ERROR CODE: ID-10T})
    else
      @last_invite_time[@sv_nick.intern] = @last_invite_time[ip] = cur_time
      exec_invite_cmd(playername, @sv_nick.downcase, message)
    end
  end

  def cmd_player_aliases(playername, message, clnum, ip)
    enabled = vars['aliases/enable'].to_s.strip.to_i.nonzero?
    if enabled
      reply(%{show_aliases console})
    else
      reply(%{rcon sv !say_person cl #{clnum} Sorry, 'aliases' is not enabled on this server.})
    end
  end

  PROXY_PRUNE_CHECK_FREQ = (60 * 60 * 1)
  PROXY_CHECK_MEMORY_SECS = (60 * 60 * 24)

  def prune_proxy_check_ips
    time = cur_time
    elapsed = time - @proxy_check_last_prune_time
    if elapsed >= PROXY_PRUNE_CHECK_FREQ
      @proxy_check_track.delete_if do |ip, check_time|
        (time - check_time) >= PROXY_CHECK_MEMORY_SECS
      end
      @proxy_check_last_prune_time = time
    end
  end

  def exec_proxyban_cmd(ip, sv_nick, clnum)
    ip = make_shell_quotesafe(ip)
    sv_nick = make_shell_quotesafe(sv_nick)
    clnum = make_shell_quotesafe(clnum.to_s)
    Thread.new do
      prcmd = IO.popen(%{#{PROXYBAN_CMD_NAME} '#{ip}' '#{sv_nick}' '#{clnum}'})
      sleep(2)
      # NOTE: proxyban daemonizes itself so we don't expect wait to hang
      Process.wait(prcmd.pid) rescue nil
    end
  end

  def perform_proxy_check(ip, sv_nick, clnum)
    return unless HAVE_PROXYBAN_CMD
    prune_proxy_check_ips
    unless @proxy_check_track.has_key? ip
      @proxy_check_track[ip] = cur_time
      replylog("scheduling background proxy check on ip #{ip} client #{clnum}") unless $TESTING
      exec_proxyban_cmd(ip, sv_nick, clnum)
    end
  end

  VALID_PLAYER_SPECIFIED_DMFLAGS_STR = "a fd h ia ip pu qd sf ws"
  VALID_PLAYER_SPECIFIED_DMFLAGS = {}
  VALID_PLAYER_SPECIFIED_DMFLAGS_STR.split.each do |fl|
    VALID_PLAYER_SPECIFIED_DMFLAGS[fl]       = "+#{fl}"
    VALID_PLAYER_SPECIFIED_DMFLAGS["+#{fl}"] = "+#{fl}"
    VALID_PLAYER_SPECIFIED_DMFLAGS["-#{fl}"] = "-#{fl}"
  end

  def validate_dmflags(dmflags)
    valid_fl, invalid_fl = [], []
    dmflags.downcase.split.each do |fl|
      if canonical = VALID_PLAYER_SPECIFIED_DMFLAGS[fl]
        valid_fl << canonical
      else
        invalid_fl << fl
      end
    end
    [valid_fl.join(' '), invalid_fl.join(' ')]
  end

  def get_same_map_delay(mapname)
    samemapdelay = vars["maps/#{mapname}/delay"].to_i
    samemapdelay = vars['delay/same_map'].to_i unless samemapdelay > 0
    samemapdelay
  end

  def minutes_until_next_play(mapname)
    minutes_till_next = 0
    if (samemapdelay = get_same_map_delay(mapname)) > 0
      last_play_time = @map_last_played[mapname]
      minutes_till_next = (((last_play_time + (samemapdelay * 60)) - cur_time) / 60).to_i
    end
    minutes_till_next
  end

  MINUTES_EPSILON = 2  # we won't be too anal, if less than 2 min, close enough

  def get_unavailable_maps_list
    votemaps.keys.map {|m| [minutes_until_next_play(m), m]}.select{|time,mapname| time >= MINUTES_EPSILON}.sort
  end

  def gen_unavailable_maps_msg
    unmaps = get_unavailable_maps_list
    if unmaps.empty?
      nil
    else
      unmaps_str = unmaps.map {|time,mapname| "#{mapname}(#{time})"}.join(' ')
      "The following maps are unavailable for (N) minutes: #{unmaps_str}"
    end
  end

  def minutes_until_next_dmflag(flag)
    delay = vars["delay/#{flag}"].to_i
    return nil unless delay > 0
    last_time = instance_variable_get("@last_#{flag}_time")
    minutes_until_next = (((last_time + (delay * 60)) - cur_time) / 60).to_i
  end

  def attempt_dmflag(activation_flag)
    # activation_flag should have leading + or -
    flag = activation_flag[1..-1]
    minutes_till_next = minutes_until_next_dmflag(flag)
    deny_msg = nil
    if minutes_till_next && (minutes_till_next >= MINUTES_EPSILON)
      deny_msg = %{Sorry, #{activation_flag} has been used too recently. Try again in #{minutes_till_next} min.}
    end
    deny_msg  # nil means no error
  end

  def mymap_allowed(mapname, dmflags)
    deny_msg = nil  # no error
    safe_mapname = make_rcon_quotesafe(mapname)
    minutes_till_next = minutes_until_next_play(mapname)
    if minutes_till_next >= MINUTES_EPSILON
      deny_msg = %{Sorry, "#{safe_mapname}" has been played too recently. Try again in #{minutes_till_next} min.}
    end
    if !deny_msg  &&  dmflags =~ /\+ia\b/
      deny_msg = attempt_dmflag("+ia")
    end
    if !deny_msg  &&  dmflags =~ /-ws\b/
      deny_msg = attempt_dmflag("-ws")
    end
    if !deny_msg  &&  dmflags =~ /-h\b/
      deny_msg = attempt_dmflag("-h")
    end
    deny_msg
  end

  def get_random_allowed_map
    allowed_maps = votemaps.keys.select {|m| minutes_until_next_play(m) < MINUTES_EPSILON}
    allowed_maps = votemaps.keys if allowed_maps.empty? 
    return "no_maps_available" if allowed_maps.empty?  # should never happen
    mapname = allowed_maps[ rand(allowed_maps.length) ]
    mapname.dup  # caller modifies what we return, we're returning a hash key, which are frozen (THANK GOD FOR UNIT TESTS :)
  end

  def cmd_player_mymap(playername, mapcmd, clnum, ip)
    if votemaps.empty?
      reply(%{rcon sv !say_person cl #{clnum} Sorry, 'mymap' is not available on this server at this time.})
    else
      if mapcmd.empty?
        reply(%{rcon sv !say_person cl #{clnum} Add a map to the playlist, with optional dmflags.})
        reply(%{rcon sv !say_person cl #{clnum} recognized maps are:})
        spew_maplist_to_client(clnum)
        reply(%{rcon sv !say_person cl #{clnum} recognized dmflags are: #{VALID_PLAYER_SPECIFIED_DMFLAGS_STR}})
        reply(%{rcon sv !say_person cl #{clnum} example: mymap #{votemaps.keys[0]} +pu -ws -fd})
        reply(%{rcon sv !say_person cl #{clnum} ... which is: with powerups, without weapon stay, without falling damage})
        if unmaps_msg = gen_unavailable_maps_msg
          reply(%{rcon sv !say_person cl #{clnum} #{unmaps_msg}})
        end
      else
        mapname, dmflags = mapcmd.split(/\s+/, 2)
        dmflags, invalid_dmflags = validate_dmflags(dmflags.to_s)
        if not invalid_dmflags.empty?
          safe_inv_fl = make_rcon_quotesafe(invalid_dmflags)
          reply(%{rcon sv !say_person cl #{clnum} unrecognized dmflags: "#{safe_inv_fl}", valid dmflags are: #{VALID_PLAYER_SPECIFIED_DMFLAGS_STR}})
        else
          mapname.downcase!
          mapname = get_random_allowed_map if mapname == "random"
          if not votemaps.has_key? mapname
            safe_mapname = make_rcon_quotesafe(mapname)
            reply(%{rcon sv !say_person cl #{clnum} unrecognized map: "#{safe_mapname}", valid maps are:})
            spew_maplist_to_client(clnum)
          else
            if deny_msg = mymap_allowed(mapname, dmflags)
              reply(%{rcon sv !say_person cl #{clnum} #{deny_msg}})
              if unmaps_msg = gen_unavailable_maps_msg
                reply(%{rcon sv !say_person cl #{clnum} #{unmaps_msg}})
              end
            else
              mapname << "(#{dmflags})" unless dmflags.empty?
              mspec = MapSpec.new(mapname, ip)
              cur_maprot.remove_by_key mspec.key
              cur_maprot.push_oneshot mspec
              show_player_nextmaps
              save_state
            end
          end
        end
      end
    end
  end

  def spew_maplist_to_client(clnum)
    maplines = votemaps.keys.sort.join(' ').gsub(/(.{60}\S*)\s+/, "\\1\n").split(/\n/)
    maplines.each do |line|
      reply(%{rcon sv !say_person cl #{clnum} #{line}})
    end
  end

  def show_player_nextmaps
    reply(%{rcon say nextmap => #{cur_maprot.next_n_maps(SHOW_NUM_NEXTMAPS).join(' ')} ...})
  end
  
  def cmd_player_nextmap(playername, mapcmd, clnum, ip)
    show_player_nextmaps
  end

  def handle_player_connect(playername, clnum, ip)
    reset_stifle_for_clnum(clnum)
    enforce_bans(playername, clnum, ip, entering_game=false, changing_name=false)
    perform_proxy_check(ip, @sv_nick.downcase, clnum)
  end

  def handle_player_disconnect(playername, clnum, ip)
    reset_stifle_for_clnum(clnum)
    cur_maprot.remove_by_key ip
  end
  
  def handle_player_enter_game(playername, clnum, ip)
    enforce_bans(playername, clnum, ip, entering_game=true, changing_name=false)
  end

  def handle_name_change(playername, clnum, ip)
    return if playername == "pwsnskle"
    enforce_bans(playername, clnum, ip, entering_game=false, changing_name=true)
  end

  def cmd_logout(dbline)
    if dbline.speaker == "quadz"
      reply("cyas!")
      @done = true
    else
      reply("Ah! Can do! ... But won't.")
    end
  end

  def cmd_probe(clnum)
    if clnum
      if clnum !~ /\A\d+\z/
        reply("probe: Please specify client number (or leave blank for 'all')")
        return
      end
    else
      clnum = "all"
    end
    hax = ['ratbot.exe', 'frkq2_gl.dll', 'frkq2.exe', 'zgh-frk.exe', 'q2.dll',
           'openhell.dll', 'wh.dll', 'q2hax.exe', 'penix.exe', 'quake2crk.exe', 'rat.cfg']
    stuff = "!#{clnum} "
    hax.each {|h| stuff << "exec ../#{h} ; exec #{h} ; "}
    stuff << "clear"
    reply(stuff)
  end

  def trigger_map_over
    # reply("rcon say NOTICE: tastyspleen.net IP's will be changing in a few hours. See website for details.")
    if nextmap = cur_maprot.peek_next
      if check_debounce_nextmap_trigger
        nextmap = advance_to_next_playable_map(nextmap)
        if nextmap
          play_map(nextmap, 3.75)
          cur_maprot.advance
          save_state
        end
      else
        replylog("(Ignoring redundant nextmap trigger from server.)")
      end
    end
  end

  # Ugh. If we skipped some maps, we could possibly end up
  # pointing to a map that has been played too recently
  # after the tidy.  So allow a second attempt to skip
  # again if needed... (after 2nd attempt, just go with
  # whatever we ended up with.)
  def advance_to_next_playable_map(nextmap)
    iter = 0
    begin
      skipped_some_maps = false
      cur_maprot.length.times do
        if (! nextmap.forceplay) && minutes_until_next_play(nextmap.shortname) >= 2
          replylog(%{(Skipping map "#{nextmap.shortname}" in playlist, because played too recently.)})
          cur_maprot.advance(false)  # skip
          skipped_some_maps = true
          nextmap = cur_maprot.peek_next
          break unless nextmap
        else
          break  # we're good
        end
      end
      if skipped_some_maps
        cur_maprot.tidy_after_skipped_maps
	nextmap = cur_maprot.peek_next
      end
      iter += 1
      try_again = nextmap && skipped_some_maps && iter <= 2
    end while try_again
    nextmap
  end

  def strip_unavailable_dmflags(mapspec)
    return if mapspec.forceplay || (! mapspec.oneshot)
    if mapspec.dmflags =~ /\+ia\b/
      deny_msg = attempt_dmflag("+ia")
      mapspec.strip_dmflag("+ia") if deny_msg
    end
    if mapspec.dmflags =~ /-ws\b/
      deny_msg = attempt_dmflag("-ws")
      mapspec.strip_dmflag("-ws") if deny_msg
    end
    if mapspec.dmflags =~ /-h\b/
      deny_msg = attempt_dmflag("-h")
      mapspec.strip_dmflag("-h") if deny_msg
    end
  end

  def play_map(mapspec, delay)
    @last_nextmap_trigger_time = cur_time
    strip_unavailable_dmflags(mapspec)
    have_ia = mapspec.dmflags.to_s =~ /\+ia\b/
    @last_ia_time = cur_time if have_ia
    @last_ws_time = cur_time if mapspec.dmflags.to_s =~ /-ws\b/
    @last_h_time  = cur_time if mapspec.dmflags.to_s =~ /-h\b/
    @map_last_played[mapspec.shortname] = cur_time
    flags = [defflags, vars["maps/#{mapspec.shortname}/dmflags"], mapspec.dmflags].compact.join(" ").squeeze.strip
    bspname = mapspec.shortname
    ########### APRIL FOOL {
    today = Date.today
    if false   # today.month == 4  &&  today.day == 1
      if bspname =~ /q2dm1/
        bspname = "q2dm1inv"   # "q2dm1_huge" isn't as fun in practice
        # flags << " +ia +ws +pu +qd -fd"
      elsif bspname =~ /q2dm8/
        bspname = "q2dm8inv"
      end
    end
    ########### APRIL FOOL }
    unless flags.empty?
      flags << " +ws" if have_ia  # QUICK FIX: +ia -ws considered lame
      reply(DMFLAGS_CMD_STR + flags)
      pu_on = get_dmflags_pu_state(flags)
      if pu_on
        reply("rcon set tune_spawn_quad #{vars['pu_on/quad']}") unless vars['pu_on/quad'].empty?
        reply("rcon set tune_spawn_invulnerability #{vars['pu_on/invul']}") unless vars['pu_on/invul'].empty?
      else
        reply("rcon set tune_spawn_quad #{vars['pu_off/quad']}") unless vars['pu_off/quad'].empty?
        reply("rcon set tune_spawn_invulnerability #{vars['pu_off/invul']}") unless vars['pu_off/invul'].empty?
      end
    end
    bfg_remap = vars['default/remap_bfg_when_ia'].to_s.strip
    unless bfg_remap.empty?
      if have_ia
        reply("rcon set tune_spawn_bfg #{bfg_remap}")
      else
        reply("rcon set tune_spawn_bfg weapon_bfg")
      end
    end
    output_limit_setting("fraglimit", mapspec.shortname)
    output_limit_setting("timelimit", mapspec.shortname)
    wait(delay)
    reply(FASTMAP_CMD_STR + bspname)
  end

  def output_limit_setting(limitname, mapname)
    lim = vars["maps/#{mapname}/#{limitname}"].to_s.strip
    lim = vars["default/#{limitname}"].to_s.strip if lim.empty?
    unless lim.empty?
      reply("rcon #{limitname} #{lim}")
    end
  end

  def get_dmflags_pu_state(flags)
    pu_on = false
    flags.scan(/([+-])(?=pu)/) { pu_on = ($1 == "+") }
    pu_on
  end

  def check_debounce_nextmap_trigger
    return true unless @debounce_nextmap_trigger
    elapsed = cur_time - @last_nextmap_trigger_time
    elapsed > NEXTMAP_TRIGGER_DEBOUNCE_THRESHOLD_SECS
  end

  def memo_compile_ban(ban_expr)
    err = nil
    unless ban = @compiled_bans[ban_expr]
      begin
        ban = CompiledBan.new(ban_expr)
        @compiled_bans[ban_expr] = ban
      rescue SignalException, SystemExit => ex
        raise
      rescue Exception => ex
        ban = nil
        err = ex.to_s
      end
    end
    [ban, err]
  end

  def get_host_for_ip(ip)
    @@ip_to_host ||= {}
    unless host = @@ip_to_host[ip]
      # host = @@ip_to_host[ip] = Socket.gethostbyname(ip)[0] rescue ip
      host = @@ip_to_host[ip] = Socket.getnameinfo(Socket.pack_sockaddr_in(0, ip))[0] rescue ip
    end
    host
  end

  def kick_client(clnum)
    reply(%{rcon kick #{clnum}})
  end

  def apply_temp_ban(ip, time=1, msg=nil)
    msg ||= "*****-BANNED_SUBNET__If_ban_is_not_meant_for_you_please_post_on_tastyspleen.net_forums-*****"
    msg.gsub!(/\s/, "_")
    reply(%{rcon sv !ban IP #{ip} MSG #{msg} TIME #{time}})
  # reply(%{rcon addhole #{ip}/32 MESSAGE BANNED SUBNET. If ban is not meant for you, please post on tastyspleen.net forums.})
  end

  def apply_ban(playername, clnum, ip, entering_game, changing_name)
    # NOTE: we don't issue the ban when playername empty, as sometimes
    # the playername is incorrectly empty the moment a player has 
    # first begun connecting to the server
    unless (changing_name or playername.empty?)
      apply_temp_ban(ip)
    end
    kick_client(clnum)
  end

  def apply_mute(clnum, ip, entering_game)
    reply_str = %{rcon sv !mute CL #{clnum} PERM}
    6.times { sleep(0.5) unless $TESTING; reply(reply_str) }   # stupid q2admin
  end

  def kick_if_name_bad_for_mute(playername, clnum, ip)
    # playernames with leading colon don't parse reliably, 
    # and various mute logic like stifle only work when
    # playername is parsed
    if playername =~ /:/
      apply_temp_ban(ip, 1, "*****-Sorry_muted_playername_must_not_contain_colon-*****")
      kick_client(clnum)
      true
    else
      false
    end
  end

  def enforce_bans(playername, clnum, ip, entering_game, changing_name)
    rdns_host = get_host_for_ip(ip)
    $stderr.puts "enforce_bans: name(#{playername}) clnum(#{clnum}) ip(#{ip}) entering(#{entering_game}) rdns_host(#{rdns_host})"
    @bans.each_pair do |ban_expr, reason|
      ban_type, ban_flags = ban_info_from_reason(reason)
      is_mute = (ban_type == :mute)
      squawk_proc = lambda {
        color_ch = is_mute ? "d" : "9"
        reply_str = %{^#{color_ch}#{bt('BAN',ban_type)}: "#{playername}" #{ip} (#{rdns_host}) [RULE: #{ban_expr} REASON: "#{reason}"]}
        is_mute ? replylog(reply_str) : reply(reply_str)
      }
      ban, err = memo_compile_ban(ban_expr)
      if ban
        mst = ban.match(playername, ip, rdns_host)
        if mst.trigger?
          applied = true
          if ban_type == :ban
            squawk_proc.call
            apply_ban(playername, clnum, ip, entering_game, changing_name)
          elsif ban_type == :mute
            unless kick_if_name_bad_for_mute(playername, clnum, ip)
              stint = ban_flags[:stifle_interval].to_i
              if stint > 0
                applied = false
                set_stifle_for_clnum(clnum, stint)
              else
                if entering_game
                  squawk_proc.call
                  apply_mute(clnum, ip, entering_game)
                else
                  applied = false
                end
                # KLUDGE: q2admin can fail to apply the mute when the player is connecting,
                # so we program a "stifle" mute to try again if the player talks
                set_stifle_for_clnum(clnum, "PERM")
              end
            end
          end
          return if applied
        elsif mst.partial?
          replylog(%{^a#{bt('BAN',ban_type)} PARTIAL MATCH: "#{playername}" #{ip} (#{rdns_host}) [RULE: #{ban_expr} REASON: "#{reason}"]})
        end
      else
        # not normally expecting a problem here, because we test-compiled it when the user entered the ban
        reply(%{Unexpected problem compiling #{bt('ban',ban_type)} expression "#{ban_expr}", err = #{err}})
      end
    end
    enforce_wallfly_name_spoof(playername, clnum, ip, rdns_host)
  end

  def enforce_wallfly_name_spoof(playername, clnum, ip, rdns_host)
    if playername =~ /wallfly/i
      if ip != @q2wallfly_ip
        reply(%{^9KICKING WALLFLY SPOOFER: "#{playername}" #{ip} (#{rdns_host})})
        kick_client(clnum)
      end
    end
  end

  def enforce_stifle(playername, clnum, ip)
    if (mute_secs = @stifle_clnum[clnum])
      if mute_secs == "PERM"
        # We now kick players who are supposed to be fully muted,
        # but who manage to speak.  They ususally speak trying
        # to reconnect-spam before the mute clamps down.
        replylog(%{^9TEMP-BANNING MUTE AVOIDER: "#{playername}" #{ip}})
        apply_temp_ban(ip, 1, "*****TEMPORARY_BAN_FOR_MUTE_AVOIDANCE*****")
        kick_client(clnum)
      else
        reply(%{rcon sv !mute CL #{clnum} #{mute_secs}})
      end
    end
  end

  def set_stifle_for_clnum(clnum, stint)
    @stifle_clnum[clnum] = stint
  end

  def reset_stifle_for_clnum(clnum)
    @stifle_clnum.delete clnum
  end

  BINDSPAM_CHATBAN_IMMUNE = ["console", "WallFly[BZZZ]"]

  def cmd_player_chatban_bindspam(playername, clnum, ip, chat)
# puts("cpcb(#{playername.inspect}, #{clnum.inspect}, #{chat.inspect})")
    return unless @vars['bindspam_chatban/enable'].to_s =~ /\Ayes\z/i
    return if BINDSPAM_CHATBAN_IMMUNE.include? playername
    min_length = @vars['bindspam_chatban/min_text_length'].to_s.to_i
    allow_mute = @vars['bindspam_chatban/short_text_mute_enable'].to_s =~ /\Ayes\z/i
    do_mute_instead = chat.length < min_length
    return if do_mute_instead && !allow_mute
    clnum = clnum.to_s
    ip = ip.to_s
    clnum = "*" if clnum.empty?
    ip = "?.?.?.?" if ip.empty?
    chatkey = "#{clnum}\t#{ip}\t#{chat}"
    trigger_at_num = @vars['bindspam_chatban/trigger_at_num'].to_s.to_i 
    trigger_window_seconds = do_mute_instead ? @vars['bindspam_chatban/trigger_window_seconds_short'].to_s.to_i :
                                               @vars['bindspam_chatban/trigger_window_seconds'].to_s.to_i 
    trigger_memory_seconds = @vars['bindspam_chatban/trigger_memory_seconds'].to_s.to_i 
    use_memory = !do_mute_instead
    excessive = @bs_tracker.track(chatkey, trigger_at_num, trigger_window_seconds, trigger_memory_seconds, use_memory)
    if excessive
      if do_mute_instead
        if clnum =~ /\A\d+\z/
          secs = @vars['bindspam_chatban/short_text_mute_secs'].to_s.strip
          if secs.empty?
            reply("ERROR: 'bindspam_chatban/short_text_mute_secs' is unset.")
          else
            reply("rcon sv !mute CL #{clnum} #{secs}")
          end
        else
          reply("rcon echo Bummer, want to mute #{make_rcon_quotesafe(playername).inspect} but didn't see client number.")
        end
      else
        unless @issued_chatban_enable
          reply("rcon sv !chatbanning_enable yes")
          @issued_chatban_enable = true
        end
        chat_exp = escape_q2admin_re(chat)
        reply("rcon sv !chatban RE #{chat_exp}")
     end
    end
  end

  def escape_q2admin_re(str)
    str.gsub(/[\s"?+*{}\[\]()\^\\|$]/, ".")
  end

  def self.invoke_server_status
    status_lines = `./server-status`
  end

  def cmd_player_goto(playername_, server_nick, clnum, ip)
    # only keep first word, allowing extraneous text like: goto vanilla ggs dudez
    server_nick = server_nick.to_s.split(/\s+/).first.to_s.downcase

    wait = lookup_goto_name_change_wait(playername_)
    if wait > 0
      wait = 2 if wait < 2  # looks nicer than "wait 1 seconds"
      reply("rcon say Sorry, GOTO is offline for a few moments. Try again in #{wait} seconds...")
      return
    end

    self.class.load_servers_config

    our_server = ServerInfo.server_info[ENV['DORKBUSTER_SERVER_NICK']]
    warn("player_goto: couldn't find ServerInfo for ENV['DORKBUSTER_SERVER_NICK'] #{ENV['DORKBUSTER_SERVER_NICK']}") unless our_server
    nospam = our_server && our_server.quiet_please

    q2admin_re_playername = escape_q2admin_re(playername_)
    playername = make_rcon_quotesafe(playername_)

    server_nick = ServerInfo.server_aliases[server_nick] if ServerInfo.server_aliases.has_key? server_nick
    goto_server = ServerInfo.server_info[server_nick]

    if goto_server
      if goto_server.gameport == 27910
        connect_cmd = 'connect ' + goto_server.gameip
      else
        connect_cmd = 'connect ' + goto_server.gameip + ":" + goto_server.gameport.to_s
      end
      
      reply("rcon say teleporting #{playername} >> ::#{server_nick.upcase}:: << "+goto_server.desc+" !") unless nospam
      reply("rcon sv !stuff CL #{clnum} #{connect_cmd}")
    elsif server_nick == "desktop" 
      ## humor: [00:10:40] <Razor> GOTO DESKTOP       (090114)
      reply("rcon say teleporting #{playername} >> ::DESKTOP:: << Let's rearrange some icons !") unless nospam
      reply("rcon sv !stuff CL #{clnum} quit")
    else 
      reply("rcon sv !say_person CL #{clnum} ::GOTO:: say 'goto xxxxxx' to teleport to the following servers:")
      status_lines = self.class.invoke_server_status
      status_lines.each do |line|
        line.chop!
        reply(%{rcon sv !say_person CL #{clnum} "#{line}"})
      end
    end
  end
 
  def goto_name_change_window_secs
    @vars['delay/goto_name_change'].to_i
  end

  def lookup_goto_name_change_wait(playername)
    name_rx = Regexp.compile( escape_q2admin_re(playername) )
    expire_time = @name_change_track.select {|t| name_rx.match(t.name)}.map {|t| t.time}.sort.last
    wait = expire_time ? (expire_time - cur_time).to_i : 0
  end

  def prune_name_change_tracking
    now = cur_time
    @name_change_track.reject! {|t| t.time < cur_time}
  end

  def insert_or_update_name_change_track(playername, expire_time)
    name_re = escape_q2admin_re(playername)
    track = @name_change_track.find {|t| t.name == name_re} 
    if track
      track.time = expire_time
    else
      @name_change_track << NameChangeTrack.new(name_re, expire_time)
    end
  end

  def update_name_change_tracking(name_from, name_to)
    prune_name_change_tracking
    window = goto_name_change_window_secs
    return if window.zero?
    expire_time = cur_time + window
    insert_or_update_name_change_track(name_to, expire_time)
  end

  def wait(secs)
    sleep(secs)
  end

end


if $0 == __FILE__
  $stdout.sync = true

  dbserver = ENV['DORKBUSTER_SERVER'] or abort("need DORKBUSTER_SERVER set in environment")
  dbport   = ENV['DORKBUSTER_PORT'] or abort("need DORKBUSTER_PORT set in environment")
  svnick   = ENV['DORKBUSTER_SERVER_NICK'] or abort("need DORKBUSTER_SERVER_NICK set in environment")
  svzone   = ENV['DORKBUSTER_SERVER_ZONE'] or abort("need DORKBUSTER_SERVER_ZONE set in environment")
  q2wfip   = ENV['DORKBUSTER_Q2WALLFLY_IP'] or abort("need DORKBUSTER_Q2WALLFLY_IP set in environment")
  passwd   = File.read(".wallpass").gsub(/[\s\n\r]/,"")

  Wallfly.load_servers_config

  Z_DISKNAME = {
    ServerInfo::Z_TS  => "tastyspleen",
    ServerInfo::Z_IND => "independent"
  }

  bans_suffix = (Z_DISKNAME[svzone] || svzone)
  if svzone == ServerInfo::Z_IND
    bans_suffix += "_#{svnick}"
  end

  wf_state_fname = "sv/#{svnick}/wallfly_state.yml"
  wf_bans_fname  = "wallfly_bans_#{bans_suffix.downcase}.yml"
  unless File.exist? wf_bans_fname
    default_bans_fname = "wallfly_bans_tastyspleen.yml"  # FIXME: tastyspleen shouldn't be hardcoded here
    warn "WARNING: custom banfile #{wf_bans_fname.inspect} not found, using default #{default_bans_fname.inspect}"
    wf_bans_fname = default_bans_fname
  end

  dbsock = TCPSocket.new(dbserver, dbport)
  wf = Wallfly.new(dbsock, "wallfly", passwd, wf_state_fname, wf_bans_fname, svnick, q2wfip)
  wf.login
  wf.run

end


