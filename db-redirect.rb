#!/usr/bin/env ruby

require 'thread'
require 'fastthread'
require 'socket'
load 'server-info.cfg'

Thread.abort_on_exception = true

threads = []
$server_list.each do |sv|
  threads << Thread.new(sv.nick, sv.dbip, sv.dbport) do |nick, dbip, dbport|
    sv = TCPServer.new(dbport.to_i)
    loop do
      begin
        cl = sv.accept
        10.times { cl.print "this #{nick} db moved to #{dbip}:#{dbport}\r\n"; sleep 1}
      ensure
        cl.close if cl
      end
    end
  end
end

threads.each {|th| th.join}  # wait forever

