#!/usr/bin/env ruby

require 'wallfly/dorkbuster-client'  # TODO: dorkbuster-client should really be in dbcore/ :(

found_nonflag = false
explicit_servers_list, args = ARGV.partition {|o| !found_nonflag && !(found_nonflag = o[0] != ?-)}

usage = "Usage: #{File.basename($0)} [-server [-server]] dbcmd [dbcmd2 ...]"
abort(usage) unless args.length >= 1

dbcmds = args

sv_cfg_filename = "server-info.cfg"
abort("Server config file #{sv_cfg_filename} not found. Please see server-example.cfg") unless test ?f, sv_cfg_filename
load sv_cfg_filename

if explicit_servers_list == ["--all"]
  explicit_servers_list = ServerInfo.server_list.select {|sv| sv.has_key?(:dbport)}.map {|sv| "-#{sv.nick}"}
end

explicit_servers = {}
explicit_servers_list.each {|svflag| sv = svflag[1..-1]; explicit_servers[sv] = true}

credentials_fname = ".dbcast-credentials"
abort("Can't find #{credentials_fname}. Should contain whitespace-separated dorkbuster user and password.") unless test ?f, credentials_fname

dbuser, dbpass = File.read(credentials_fname).gsub(/\s+/,' ').strip.split
abort("Username or password missing from #{credentials_fname}") unless dbuser && dbpass

unknown_servers = false
explicit_servers.keys.each do |sv|
  if ! ServerInfo.server_info.has_key?(sv)
    warn "unknown server: #{sv}"
    unknown_servers = true
  end
end
exit if unknown_servers

class DbClientHandler

  def initialize(sock, db_username, db_password)
    @myname = db_username
    @db = DorkBusterClient.new(sock, db_username, db_password)
    @done = false
  end

  def close
    @db.close
  end

  def login
    @db.login
  end

  def reply(str)
    @db.speak(str)
  end

  def run
    while not @done
      @db.get_parse_new_data
      while dbline = @db.next_parsed_line
        puts "db_event: [#{dbline.kind}] time=#{dbline.time} speaker=#{dbline.speaker} cmd=#{dbline.cmd}"
      end
      @db.wait_new_data unless @done
    end
  end

  def wait_print(timeout_secs=2.0)
    @db.wait_new_data(timeout_secs)
    @db.get_parse_new_data
    while dbline = @db.next_parsed_line
      puts dbline.raw_line
    end
  end

end


$server_list.each do |sv|
  next if  !explicit_servers.empty?  &&  !explicit_servers.has_key?(sv.nick)
  puts "connecting to #{sv.nick}..."
  dbsock = dbc = nil
  begin
    dbsock = TCPSocket.new(sv.dbip, sv.dbport.to_s)
    dbc = DbClientHandler.new(dbsock, dbuser, dbpass)
    dbc.login
    dbcmds.each do |cmd|
      next if cmd.strip.empty?
      dbc.reply(cmd)
      sleep(0.5)
      dbc.wait_print
    end
    dbc.close
  rescue Interrupt, NoMemoryError, SystemExit => ex
    abort "exception processing #{sv.nick}: #{ex.inspect} ... aborting."
  rescue Exception => ex
    puts "exception processing #{sv.nick}: #{ex.inspect} ... continuing..."
    if dbc
      dbc.close rescue nil
    elsif dbsock
      dbsock.close rescue nil
    end
  end
end


