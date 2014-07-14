#!/usr/bin/env ruby

load 'server-info.cfg'

abort "Usage: #$0 server-nickname droidname" unless ARGV.length == 2

servername = ARGV.shift
droidname = ARGV.shift
droidpath = "droids/#{droidname}"
logpath = "sv/#{servername}/#{droidname}.log"
pidpath = "sv/#{servername}/#{droidname}.pid"

test ?f, droidpath or abort "File #{droidpath} not found"
test ?x, droidpath or abort "File #{droidpath} not executable"

ENV['DORKBUSTER_SERVER']      = $server_info[servername].dbip
ENV['DORKBUSTER_PORT']        = $server_info[servername].dbport.to_s
ENV['DORKBUSTER_SERVER_NICK'] = servername
ENV['DORKBUSTER_SERVER_ZONE'] = $server_info[servername].zone
ENV['DORKBUSTER_LOGPATH']     = File.expand_path(logpath)
ENV['DORKBUSTER_Q2WALLFLY_IP'] = $q2wallfly_ip

if test ?f, pidpath
  system("./killdroid.rb #{servername} #{droidname}")
end

abort "skipping #{droidname} on #{servername}, no rcon in cfg." if $server_info[servername].rconpass.nil? 

fork do
  Process.setsid
  fork do

    File.open(pidpath, "w") {|f| f.print($$) }
    exec "exec #{droidpath} >> #{logpath} 2>&1"

  end
end

