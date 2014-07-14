#!/usr/local/bin/ruby -w
#
# The Quake2 Dork Buster (multi-admin rcon server monitor)
#
# author: Bill Kelly <billk@cts.com>
#

require 'ftools'
require 'socket'

DorkBusterName = "dorkbuster rcon server"
DorkBusterVersion = "v0.6.0"


usage = "Usage: #{$0.split(/\//)[-1]} server-nickname"
abort(usage) unless ARGV.length == 1

server_nick = ARGV.shift

sv_cfg_filename = "server-info.cfg"

abort("Directory sv/#{server_nick} not found.") unless test ?d, "sv/#{server_nick}"
abort("Server config file #{sv_cfg_filename} not found. Please see server-example.cfg") unless test ?f, sv_cfg_filename
abort("users.cfg not found. Please see users-example.cfg") unless test ?f, "users.cfg"

load sv_cfg_filename
server_ip      = $server_info[server_nick].gameip
server_port    = $server_info[server_nick].gameport
rcon_password  = $server_info[server_nick].rconpass
db_port        = $server_info[server_nick].dbport

ENV['DORKBUSTER_SERVER']      = $server_info[server_nick].dbip
ENV['DORKBUSTER_PORT']        = db_port.to_s
ENV['DORKBUSTER_SERVER_NICK'] = server_nick
ENV['DORKBUSTER_SERVER_ZONE'] = $server_info[server_nick].zone

SepBar = '*' * 79

module IRB; class Abort < Exception; end; end  # for rescue clause when not using IRB

class Array
  def rndpick
    self.at(rand(self.length))
  end
end

$:.unshift "./dataserver"

require 'dbcore/dbmod'
require 'dbcore/ansi'
require 'dbmod/colors'
require 'dbcore/q2dmflags'
require 'dbcore/q2wallfly'
require 'dbcore/q2rcon'
require 'dbcore/gamestate-db'
require 'dbmod/sillyq2'
require 'dbcore/rcon-server'

# load remaining modules
Dir["dbmod/*.rb"].each {|mod| require mod }

# require 'dike'
# Dike.log STDERR
# Thread.new { loop { sleep(10) and Dike.finger } }

rs = RconServer.new(server_nick, rcon_password, server_ip, server_port, db_port)
rs.run



# require 'IRB'
# IRB.start

