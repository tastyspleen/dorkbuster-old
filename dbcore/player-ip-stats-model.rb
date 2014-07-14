
require 'og'


class IPHost
  property :ip, String
  property :hostname, String
end

class Playername
  property :playername, String
end

class Servername
  property :servername, String
end

class PlayerSeen
  property :first_seen, Time
  property :last_seen, Time
  property :times_seen, Integer
  refers_to :iphost, IPHost
  refers_to :playername, Playername
  refers_to :servername, Servername

  def self.log_player_seen(playername_str, ip_str, hostname_str, servername_str, timestamp)
    iphost = playername = servername = playerseen = nil
    PlayerSeen.ogstore.transaction {
      # TODO: want serializable isolation level for postgres
      iphost = IPHost.find_or_create_by_ip_and_hostname(ip_str, hostname_str)
      playername = Playername.find_or_create_by_playername(playername_str)
      servername = Servername.find_or_create_by_servername(servername_str)
      playerseen = PlayerSeen.find_or_create_by_iphost_oid_and_playername_oid_and_servername_oid(iphost.oid, playername.oid, servername.oid)
      
      if playerseen.first_seen.nil?
        playerseen.first_seen = timestamp
      end
      playerseen.last_seen = timestamp
      playerseen.times_seen = playerseen.times_seen.to_i + 1
      playerseen.save!
    }
  end
  
  def self.grep(substr, limit=1000)
    substr_esc = PlayerSeen.ogstore.escape(substr)
    sql =
      "SELECT #{Playername.table}.playername, #{Servername.table}.servername, "+
      "#{IPHost.table}.ip, #{IPHost.table}.hostname, "+
      "#{PlayerSeen.table}.first_seen, #{PlayerSeen.table}.last_seen, #{PlayerSeen.table}.times_seen "+
      "FROM #{PlayerSeen.table} LEFT JOIN #{IPHost.table} ON #{PlayerSeen.table}.iphost_oid = #{IPHost.table}.oid "+
      "LEFT JOIN #{Playername.table} ON #{PlayerSeen.table}.playername_oid = #{Playername.table}.oid "+
      "LEFT JOIN #{Servername.table} ON #{PlayerSeen.table}.servername_oid = #{Servername.table}.oid "+
      "WHERE #{Playername.table}.playername LIKE '%#{substr_esc}%' "+
      "OR #{IPHost.table}.ip LIKE '%#{substr_esc}%' "+
      "OR #{IPHost.table}.hostname LIKE '%#{substr_esc}%' "+
      "ORDER BY #{PlayerSeen.table}.last_seen DESC"
    sql << " LIMIT #{limit}" if limit
    res = PlayerSeen.ogstore.query(sql)
    # Even though we wanted ascending order,
    # we've used a descending sort combined with LIMIT, because
    # if the result set is truncated by LIMIT, we want the most
    # recently seen entries.  So we'll reverse the result.
    rows = []
    res.each_row {|row,dummy| rows << row}
    rows.reverse!
    rows
  end
end

class FragsDaily
  property :date, Date
  property :method, String      # ex: mg, cg, trap, phalanx, lava, squished, cratered, drowned
  property :count, Integer
  refers_to :inflictor, Playername
  refers_to :victim, Playername
end


# postgres:
# in theory, we can do:
#   store.exec "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
# inside a transaction block
# 
