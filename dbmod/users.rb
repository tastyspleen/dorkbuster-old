
module DBUserPerms
  PERM_NONE     = 0x0000
  PERM_DB_DEVEL = 0x0001
  PERM_AI       = 0x0002
  PERM_GUEST    = 0x0004
end

class DorkBusterUser
  include DBUserPerms
  
  attr_accessor :username, :passwd, :gender, :perms
  
  def initialize(username, passwd, gender, perms)
    @username, @passwd, @gender, @perms = username, passwd, gender, perms
  end
  
  def is_db_devel; (@perms & PERM_DB_DEVEL) != 0; end
  def is_ai;       (@perms & PERM_AI) != 0; end
  def is_guest;    (@perms & PERM_GUEST) != 0; end
end

class DorkBusterUserDatabase
  include DBUserPerms

  @@rcon_users = []
  @@sv_rcon_users = {}

  CryptSalt = '1x'

  class << self
    def match_user(username, pass_plain)
      pass_crypt = pass_plain.crypt(CryptSalt)
      @@rcon_users.each do |u|
        return u if (u.username == username  &&  u.passwd == pass_crypt)
      end
      nil
    end

    def find_user(username, userlist=@@rcon_users)
      userlist.find {|u| u.username == username}
    end

    def sv_authorized_users(svnick)
      @@sv_rcon_users[svnick]
    end

    def filter_servers_authorized_for_user(server_list, login_name)
      server_list.select {|sv| sv_authorized_users(sv.nick).any? {|u| u.username == login_name } }
    end
  end

end


# Inelegant hack.  Load users.cfg once for each known server.
# Accumulate table of users allowed on each server.
# Restore the 'current' server environment afterward.

orig_sv_nick = ENV['DORKBUSTER_SERVER_NICK']
orig_sv_zone = ENV['DORKBUSTER_SERVER_ZONE']

$server_list.each do |sv|
  ENV['DORKBUSTER_SERVER_NICK'] = sv.nick
  ENV['DORKBUSTER_SERVER_ZONE'] = sv.zone
  load 'users.cfg'
  class DorkBusterUserDatabase
    @@sv_rcon_users[ ENV['DORKBUSTER_SERVER_NICK'] ] = @@rcon_users
  end
end

ENV['DORKBUSTER_SERVER_NICK'] = orig_sv_nick
ENV['DORKBUSTER_SERVER_ZONE'] = orig_sv_zone
load 'users.cfg'  # load again, because orig server nick (like 'dbmux') may not be in normal $server_list

# class DorkBusterUserDatabase
#   @@rcon_users = @@sv_rcon_users[ ENV['DORKBUSTER_SERVER_NICK'] ]
# end


