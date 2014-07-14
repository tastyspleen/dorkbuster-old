#!/usr/bin/env ruby

require 'socket'
require 'eventmachine'
require 'protocols/line_and_text'
require 'player_ip_stats_model'
require 'dataserver_config'


module Dataserver

  class DataserverQueryProtocol < EventMachine::Protocols::LineAndTextProtocol

    RESP_200_OK                      = "200 OK"
    RESP_402_UNRECOGNIZED_QUERY_CMD  = "402 Unrecognized query command"
    RESP_403_UNRECOGNIZED_STATS_DB   = "403 Unrecognized stats database"
    RESP_500_INTERNAL_ERROR          = "500 Internal error"

    def initialize(*args)
      super
    end

    def post_init
      super
      @remote_port, @remote_ip = Socket.unpack_sockaddr_in(self.get_peername)
      log("incoming connection")
    end

    def unbind
      log("connection unbound")
    end

    def receive_line(line)
      line.chomp!
      # $stderr.puts "query_server: got line: #{line.inspect}"
      begin
        protocol_parse(line)
      rescue Interrupt, NoMemoryError, SystemExit
        raise
      rescue Exception => ex
        log("receive_line: caught exception #{ex.inspect} processing line #{line.inspect} - #{ex.backtrace.inspect}")
        respond_and_terminate(RESP_500_INTERNAL_ERROR)
      end
    end

    def send_line(line)
      # $stderr.puts "query_server:send_line: #{line.inspect}"
      line += "\n" unless line[-1] == ?\n
      send_data(line)
    end

    def log(msg)
      time_str = Time.now.strftime("%Y-%m-%d %H:%M:%S %a")
      classname = "query_server"  # self.class.name.split(/:/)[-1]
      remote = "#@remote_ip:#@remote_port"
      $stderr.puts "[#{time_str}][#{remote}][#{classname}] #{msg}"
    end

    protected
  
    # query lines are tab-separated columns
    def protocol_parse(line)
      cmd, *args = line.split(/\t/, -1)
      case cmd
      when "quit"             then drop_client
      when "aliases_for_ip"   then query_aliases_for_ip(args)
      when "playerseen_grep"  then query_playerseen_grep(args)
      when "frag_total"       then query_frag_total(args)
      when "frag_list"        then query_frag_list(args)
      when "suicide_total"    then query_suicide_total(args)
      when "suicide_list"     then query_suicide_list(args)
      else
        log("protocol_parse: unrecognized query cmd #{cmd.inspect} parsing line #{line.inspect}")
        respond(RESP_402_UNRECOGNIZED_QUERY_CMD)
      end
    end

    def drop_client
      log("dropping client")
      close_connection_after_writing
    end

    ALIASES_LIMIT_DEFAULT = 100
    ALIASES_LIMIT_MAX = 1000
    def query_aliases_for_ip(args)
      ip_str, limit = *args
      ip_str = ip_str.to_s.strip
      limit = limit.to_s.strip.to_i
      if limit < 1
        limit = ALIASES_LIMIT_DEFAULT
      elsif limit > ALIASES_LIMIT_MAX
        limit = ALIASES_LIMIT_MAX
      end
      rows = PlayerIPStats::PlayerSeen.aliases_for_ip(ip_str, limit)
      # ROW: playername, servername, ip, hostname, first_seen, last_seen, times_seen
      response = rows.map {|row| row[0]}.uniq.join("\t")
      respond(RESP_200_OK, response)
    end

    PLAYERSEEN_GREP_LIMIT_DEFAULT = 10
    PLAYERSEEN_GREP_LIMIT_MAX = 1000
    def query_playerseen_grep(args)
      search_str, limit = *args
      search_str = search_str.to_s.strip
      limit = limit.to_s.strip.to_i
      if limit < 1
        limit = PLAYERSEEN_GREP_LIMIT_DEFAULT
      elsif limit > PLAYERSEEN_GREP_LIMIT_MAX
        limit = PLAYERSEEN_GREP_LIMIT_MAX
      end
      rows = PlayerIPStats::PlayerSeen.grep(search_str, limit)
      rows = rows.map {|row| row.join("\t")}
      respond(RESP_200_OK, rows)
    end

    def query_frag_total(args)
      dbname, inflictor, victim, method_str, servername, date = *args
      dbname = dbname.to_s.strip
      inflictor = inflictor.to_s.strip
      victim = victim.to_s.strip
      method_str = method_str.to_s.strip
      servername = servername.to_s.strip
      date = date.to_s.strip
      if date.empty?
        date = Date.today
      else
        date = Date.parse(date)
      end
      dbclass = frag_dbclass_for_dbname(dbname)
      if dbclass
        total = dbclass.total_frags(inflictor, victim, method_str, servername, date)
        respond(RESP_200_OK, total.to_s)
      else
        log("query_frag_total: unrecognized dbname #{dbname} args #{args.inspect}")
        respond(RESP_403_UNRECOGNIZED_STATS_DB)
      end
    end

    FRAG_LIST_LIMIT_DEFAULT = 10
    FRAG_LIST_LIMIT_MAX = 1000
    def query_frag_list(args)
      dbname, inflictor, victim, method_str, servername, date, limit = *args
      dbname = dbname.to_s.strip
      inflictor = inflictor.to_s.strip
      victim = victim.to_s.strip
      method_str = method_str.to_s.strip
      servername = servername.to_s.strip
      date = date.to_s.strip
      limit = limit.to_s.strip.to_i
      inflictor = nil if inflictor.empty?
      victim = nil if victim.empty?
      method_str = nil if method_str.empty?
      servername = nil if servername.empty?
      if date.empty?
        date = Date.today
      else
        date = Date.parse(date)
      end
      if limit < 1
        limit = FRAG_LIST_LIMIT_DEFAULT
      elsif limit > FRAG_LIST_LIMIT_MAX
        limit = FRAG_LIST_LIMIT_MAX
      end
      dbclass = frag_dbclass_for_dbname(dbname)
      if dbclass
        rows = dbclass.top_frags_list(inflictor, victim, method_str, servername, date, limit)
        rows = rows.map {|row| row.join("\t")}
        respond(RESP_200_OK, rows)
      else
        log("query_frag_list: unrecognized dbname #{dbname} args #{args.inspect}")
        respond(RESP_403_UNRECOGNIZED_STATS_DB)
      end
    end

    def query_suicide_total(args)
      dbname, victim, method_str, servername, date = *args
      dbname = dbname.to_s.strip
      victim = victim.to_s.strip
      method_str = method_str.to_s.strip
      servername = servername.to_s.strip
      date = date.to_s.strip
      if date.empty?
        date = Date.today
      else
        date = Date.parse(date)
      end
      dbclass = suicide_dbclass_for_dbname(dbname)
      if dbclass
        total = dbclass.total_suicides(victim, method_str, servername, date)
        respond(RESP_200_OK, total.to_s)
      else
        log("query_suicide_total: unrecognized dbname #{dbname} args #{args.inspect}")
        respond(RESP_403_UNRECOGNIZED_STATS_DB)
      end
    end

    SUICIDE_LIST_LIMIT_DEFAULT = 10
    SUICIDE_LIST_LIMIT_MAX = 1000
    def query_suicide_list(args)
      dbname, victim, method_str, servername, date, limit = *args
      dbname = dbname.to_s.strip
      victim = victim.to_s.strip
      method_str = method_str.to_s.strip
      servername = servername.to_s.strip
      date = date.to_s.strip
      limit = limit.to_s.strip.to_i
      victim = nil if victim.empty?
      method_str = nil if method_str.empty?
      servername = nil if servername.empty?
      if date.empty?
        date = Date.today
      else
        date = Date.parse(date)
      end
      if limit < 1
        limit = SUICIDE_LIST_LIMIT_DEFAULT
      elsif limit > SUICIDE_LIST_LIMIT_MAX
        limit = SUICIDE_LIST_LIMIT_MAX
      end
      dbclass = suicide_dbclass_for_dbname(dbname)
      if dbclass
        rows = dbclass.top_suicides_list(victim, method_str, servername, date, limit)
        rows = rows.map {|row| row.join("\t")}
        respond(RESP_200_OK, rows)
      else
        log("query_suicide_list: unrecognized dbname #{dbname} args #{args.inspect}")
        respond(RESP_403_UNRECOGNIZED_STATS_DB)
      end
    end

    def frag_dbclass_for_dbname(dbname)
      case dbname
      when "daily" then PlayerIPStats::FragsDaily
      when "monthly" then PlayerIPStats::FragsMonthly
      when "alltime" then PlayerIPStats::FragsAllTime
      else nil
      end
    end    

    def suicide_dbclass_for_dbname(dbname)
      case dbname
      when "daily" then PlayerIPStats::SuicidesDaily
      when "monthly" then PlayerIPStats::SuicidesMonthly
      when "alltime" then PlayerIPStats::SuicidesAllTime
      else nil
      end
    end    

    def respond(resp_code, resp_lines=[])
      send_line(resp_code)
      resp_lines.each do |line|
        line = "\t" if line.empty?  # can't send blank line, as blank line is record separator
        send_line(line)
      end
      send_line("")  # send record separator
    end
    
    def respond_and_terminate(resp_code, resp_lines=[])
      respond(resp_code, resp_lines)
      drop_client
    end
  end


  def self.start_query_server(host=QUERY_SERVER_IP, port=QUERY_SERVER_PORT)
    # assumes Og / database is already initialized

    EventMachine::start_server host, port, Dataserver::DataserverQueryProtocol
  end  

end





