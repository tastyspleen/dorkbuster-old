#!/usr/bin/env ruby

abort "Usage: #$0 server-nickname" unless ARGV.length == 1

svname = ARGV.shift

load "server-info.cfg"

dbport = $server_info[svname].dbport

puts "Launching dorkbuster #{svname} #{dbport} ..."

fork do
  Process.setsid
  fork do
    exec("ruby dorkbuster.rb #{svname} > /dev/null 2>>db-err.log &")
  end
end

sleep 3

puts "Starting droids..."
system("ruby rundroids.rb #{svname}")

