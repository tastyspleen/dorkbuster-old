#!/usr/bin/env ruby

require 'dbcore/q2rcon'
require 'dbcore/gamestate'

abort "Usage: #$0 server_nick" unless ARGV.length == 1

server_nick = ARGV.shift

class Logger
  def log(msg)
  end
end

gs = GameState.new(Logger.new, server_nick)
gs.load

nbip = gs.names_by_ip

nbip.each_pair do |ip,names|
  names.each_pair do |name, stats|
    last_seen_time = stats[:last_seen].tv_sec
    times_seen = stats[:times_seen]
    puts "#{ip}\t#{name}\t#{last_seen_time}\t#{times_seen}"
  end
end



