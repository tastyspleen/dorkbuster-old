#!/usr/bin/env ruby

load 'server-info.cfg'

abort "Usage: #$0 server-nickname-or-all [specific droid names]" unless ARGV.length >= 1

servername = ARGV.shift

if ARGV.empty?
  droids = Dir["droids/*"].collect {|pathname| File.basename(pathname) }
else
  droids = [*ARGV]
end

abort "no droids found..." if droids.empty?

if servername == "all"
  servernames = $server_info.keys
else
  servernames = [servername]
end

servernames.each do |servername|
  droids.each do |droidname|
    puts "killing #{droidname} on #{servername}..."
    system "ruby killdroid.rb #{servername} #{droidname}"
  end
end

