#!/usr/bin/env ruby

require 'socket'
require 'fcntl'
require 'timeout'


def q2cmd(server_addr, server_port, cmd_str, udp_recv_timeout=3.0)
  resp, sock = nil, nil
  begin
    cmd = "\xFF\xFF\xFF\xFF#{cmd_str}\0"
    sock = UDPSocket.open
    sock.send(cmd, 0, server_addr, server_port)
    if select([sock], nil, nil, udp_recv_timeout)
      begin
        timeout(udp_recv_timeout) {
          sock.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK) if defined? Fcntl::O_NONBLOCK
          resp = sock.recvfrom(65536)
        }
      rescue Timeout::Error
        $stderr.puts "q2cmd: Timeout::Error in sock.recvfrom !"
      end
    end
    if resp
      resp[0] = resp[0][4..-1]  # trim leading 0xffffffff
    end
  rescue IOError, SystemCallError
  ensure
    sock.close if sock
  end
  resp ? resp[0] : nil
end


if $0 == __FILE__
  abort "Usage: server_addr server_port cmd_str" unless ARGV.length == 3

  server, port, cmd = *ARGV
  result = q2cmd(server, port, cmd)
  puts result
end

