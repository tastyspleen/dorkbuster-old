#!/usr/bin/env ruby

require 'q2cmd'
load 'server-info.cfg'


# def q2cmd(server_addr, server_port, cmd_str, udp_recv_timeout=3.0)

def rconcmd(sv, command_)
  command = command_.gsub(/\$\{nick\}/, sv.nick)
  out = "#{sv.nick}::#{sv.gameip}:#{sv.gameport} rcon #{command}"
  rcon_cmd = "rcon #{sv.rconpass} #{command}"
  res = q2cmd(sv.gameip, sv.gameport, rcon_cmd)   
  if res
    out << " [OK] #{res.to_s.strip.inspect}"
  else
    out << " [FAILED!]"
  end
  out
end

def rconcast(server_list, command_, local_only, specific_servers)
  threads = []
  server_list.each do |sv|
    if specific_servers
      next unless specific_servers.has_key? sv.nick
    elsif (sv.zone != ServerInfo::Z_TS) && !sv.locally_managed
      puts "skipping #{sv.nick}, neither #{ServerInfo::Z_TS} zone, nor locally_managed..."
      next
    end
    if sv.rconpass
      next if local_only && !sv.locally_managed
      threads << Thread.new(sv, command_) {|_sv, _cmd| rconcmd(_sv, _cmd)}
    else
      puts "skipping #{sv.nick}, no rconpass..."
    end
  end
  threads.each do |th|
    out = th.value rescue "(EXCEPTION ON RCONCAST THREAD)"
    puts out
  end
end
  
args = ARGV.dup
local_only = args.delete "--local"
force_all = args.delete "--all"
specific_servers = {}
args.delete_if do |x|
  if x =~ /\A-([\w-]+)\z/
    specific_servers[$1] = true
    true
  else
    false
  end
end
specific_servers = nil if specific_servers.empty?

abort("--local conflicts with --all") if local_only && force_all
abort("--all conflicts with specific server list on command line") if force_all && specific_servers

specific_servers = Hash[ *( $server_list.map {|sv| [sv.nick, true]}.flatten ) ] if force_all

args.each do |cmd|
  rconcast($server_list, cmd, local_only, specific_servers)
end

