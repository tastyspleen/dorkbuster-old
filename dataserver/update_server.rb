#!/usr/bin/env ruby

require 'eventmachine'
require 'protocols/line_and_text'
require 'player_ip_stats_model'
require 'dataserver_config'

module Dataserver

  CryptSalt = '1x'  # TODO: make this random

  def self.auth_login(username_attempt, password_attempt)
    password_attempt = password_attempt.crypt(CryptSalt)
    login_attempt = [username_attempt, password_attempt]
    authorized_logins = load_password_data
    authorized_logins.include? login_attempt
  end

  def self.load_password_data(fname=UPDATE_SERVER_PASSWORD_FILE)
    logins = []
    IO.foreach(fname) do |line|
      line.strip!
      next if line.empty?
      logins << line.split(/\s+/, 2)
    end
    logins
  end

  class DataserverUpdateProtocol < EventMachine::Protocols::LineAndTextProtocol

    ST_AUTH = :auth
    ST_ACCEPT_UPDATES = :update
    ST_TERMINATING = :term

    RESP_200_OK                      = "200 OK"
    RESP_400_BAD_AUTH_PROTOCOL       = "400 Bad or missing auth protocol start"
    RESP_401_AUTH_LOGIN_FAIL         = "401 Bad username or password"
    RESP_402_UNRECOGNIZED_UPDATE_CMD = "402 Unrecognized update command"
    RESP_403_ARGUMENT_ERROR          = "403 Argument error"
    RESP_500_INTERNAL_ERROR          = "500 Internal error"

    def initialize(*args)
      super
      @state = ST_AUTH
      @@ip_hostname_cache ||= {}
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
      # $stderr.puts "update_server: got line: #{line.inspect}"
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
      line += "\n" unless line[-1] == ?\n
      send_data(line)
    end

    def log(msg)
      time_str = Time.now.strftime("%Y-%m-%d %H:%M:%S %a")
      classname = "update_server"  # self.class.name.split(/:/)[-1]
      remote = "#@remote_ip:#@remote_port"
      $stderr.puts "[#{time_str}][#{remote}][#{classname}] #{msg}"
    end

    protected

    def protocol_parse(line)
      case @state
      when ST_AUTH            then protocol_parse_auth(line)
      when ST_ACCEPT_UPDATES  then protocol_parse_update(line)
      when ST_TERMINATING     then line = nil  # ignore further input
      else
        log("protocol_parse: unknown state #{@state.inspect} parsing line #{line.inspect}")
        respond_and_terminate(RESP_500_INTERNAL_ERROR)
      end
    end

    def protocol_parse_auth(line) 
      if line =~ /\Aauth (\w+) (\S+)\z/
        login, pass = $1, $2
        if Dataserver.auth_login(login, pass)
          log("login accepted for user '#{login}'")
          @state = ST_ACCEPT_UPDATES
          respond(RESP_200_OK)
        else
          log("login failed for user '#{login}'")
          respond_and_terminate(RESP_401_AUTH_LOGIN_FAIL)
        end
      else
        log("bad auth protocol: #{line.inspect}")
        respond_and_terminate(RESP_400_BAD_AUTH_PROTOCOL)
      end
    end

    # update lines are tab-separated columns
    def protocol_parse_update(line)
      cmd, *args = line.split(/\t/, -1)
      case cmd
      when "quit"        then drop_client
      when "playerseen"  then update_playerseen(args)
      when "frag"        then update_frag(args)
      when "suicide"     then update_suicide(args)
      else
        log("protocol_parse_update: unrecognized update cmd #{cmd.inspect} parsing line #{line.inspect}")
        respond(RESP_402_UNRECOGNIZED_UPDATE_CMD)
      end
    end

    def drop_client
      log("dropping client")
      close_connection_after_writing
      @state = ST_TERMINATING
    end

    def update_playerseen(args)
      playername, ip, servername, timestamp_secs, times_seen = *args
      playername = playername.to_s.strip
      ip = ip.to_s.strip
      servername = servername.to_s.strip
      timestamp_secs = timestamp_secs.to_s.strip.to_i
      times_seen = times_seen.to_s.strip
      times_seen = times_seen.empty? ? 1 : times_seen.to_i
      if playername.empty? || ip.empty? || servername.empty? || timestamp_secs == 0
        log("update_playerseen: one or more bad args: #{args.inspect}")
        respond(RESP_403_ARGUMENT_ERROR)
      else
        timestamp = Time.at(timestamp_secs).gmtime
        hostname = cached_hostname_lookup(ip)
        PlayerIPStats::PlayerSeen.log_player_seen(playername, ip, hostname, servername, timestamp, times_seen)
        respond(RESP_200_OK)
      end
    end

    def update_frag(args)
      inflictor, victim, method_str, servername, date, count = *args
      inflictor = inflictor.to_s.strip
      victim = victim.to_s.strip
      method_str = method_str.to_s.strip
      servername = servername.to_s.strip
      date = date.to_s.strip
      count = count.to_s.strip.to_i
      count = 1 if count < 1
      if date.empty?
        date = Date.today
      else
        date = Date.parse(date)
      end
      if inflictor.empty? || victim.empty? || method_str.empty? || servername.empty?
        log("update_frag: one or more bad args: #{args.inspect}")
        respond(RESP_403_ARGUMENT_ERROR)
      else
        PlayerIPStats.log_frag(inflictor, victim, method_str, servername, count, date)
        respond(RESP_200_OK)
      end
    end

    def update_suicide(args)
      victim, method_str, servername, date, count = *args
      victim = victim.to_s.strip
      method_str = method_str.to_s.strip
      servername = servername.to_s.strip
      date = date.to_s.strip
      count = count.to_s.strip.to_i
      count = 1 if count < 1
      if date.empty?
        date = Date.today
      else
        date = Date.parse(date)
      end
      if victim.empty? || method_str.empty? || servername.empty?
        log("update_suicide: one or more bad args: #{args.inspect}")
        respond(RESP_403_ARGUMENT_ERROR)
      else
        PlayerIPStats.log_suicide(victim, method_str, servername, count, date)
        respond(RESP_200_OK)
      end
    end

    def respond(resp_code)
      send_line(resp_code)
    end

    def respond_and_terminate(resp_code)
      respond(resp_code)
      drop_client
    end

    def cached_hostname_lookup(ip)
      hostname = @@ip_hostname_cache[ip]
      unless hostname
        begin
          # result = Socket.gethostbyname(ip)
	  result = Socket.getnameinfo( Socket.pack_sockaddr_in(0, ip) )
          hostname = result.first if result && !result.first.to_s.empty?
          @@ip_hostname_cache[ip] = hostname
        rescue Interrupt, NoMemoryError, SystemExit => ex
          raise
        rescue Exception => ex
          log("cached_hostname_lookup: #{ex.inspect}")
        end
      end
      hostname || ip
    end

  end

  def self.start_update_server(host=UPDATE_SERVER_IP, port=UPDATE_SERVER_PORT)
    # assumes Og / database is already initialized
      
    EventMachine::start_server host, port, Dataserver::DataserverUpdateProtocol
  end  

end




