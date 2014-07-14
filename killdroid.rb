#!/usr/bin/env ruby

abort "Usage: #$0 server-nickname droidname" unless ARGV.length == 2

servername = ARGV.shift
droidname = ARGV.shift
droidpath = "droids/#{droidname}"
logpath = "sv/#{servername}/#{droidname}.log"
pidpath = "sv/#{servername}/#{droidname}.pid"

if test ?f, pidpath
  oldpid = File.read(pidpath).gsub(/[\s\n\r]/,"").to_i
  if oldpid > 0
    puts "Killing previous #{droidname} pid #{oldpid}..."
    Process.kill("TERM", oldpid) rescue nil
    File.unlink(pidpath)
    sleep 2
  end
else
  puts "Droid not running? No pid file found at #{pidpath}"
end


