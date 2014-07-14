
require 'date'
require 'og'


StopwatchRecord = Struct.new(:count, :total_elapsed, :mintime, :maxtime)

class Stopwatch
  def initialize
    @data = {}
    @total_count = 0
  end
  
  def measure(name)
    before = Time.now
    yield
    elapsed = Time.now - before
    rec = (@data[name] ||= StopwatchRecord.new(0, 0))
    rec.count += 1
    rec.total_elapsed += elapsed
    if rec.mintime.nil? || (rec.mintime > elapsed)
      rec.mintime = elapsed
    end
    if rec.maxtime.nil? || (rec.maxtime < elapsed)
      rec.maxtime = elapsed
    end
    @total_count += 1
    if (@total_count % 1000) == 0
      show_stats
      clear_stats
    end
  end
  
  def clear_stats
    @data.clear
  end

  def show_stats
    $stderr.puts "\nSTOPWATCH: total_count #@total_count"
    @data.keys.sort.each do |name|
      rec = @data[name]
      $stderr.printf("STOPWATCH: avg %6.3f  min %6.3f  max %6.3f - %s\n",
          rec.total_elapsed / rec.count,
          rec.mintime, rec.maxtime, name)
    end
  end
end

$SW = Stopwatch.new



module PlayerIPStats

class IPHost
  property :ip, String, :unique => true
  property :hostname, String
end

class Playername
  property :playername, String, :unique => true
end

class Servername
  property :servername, String, :unique => true
end

class PlayerSeen
  property :first_seen, Time
  property :last_seen, Time
  property :times_seen, Integer
  refers_to :iphost, IPHost
  refers_to :playername, Playername
  refers_to :servername, Servername

  def self.create_unique_index
    sql = "CREATE UNIQUE INDEX #{table}_unique ON #{table} "+
          "(iphost_oid, playername_oid, servername_oid)"
    begin
      ogstore.exec(sql)
    rescue Og::StoreException => ex
    end
  end

  def self.log_player_seen(playername_str, ip_str, hostname_str, servername_str, timestamp, times_seen_inc=1)
    iphost = playername = servername = playerseen = nil
$SW.measure("log_player_seen") {
    PlayerSeen.ogstore.transaction {
      # NOTE: can't do IPHost.find_or_create_by_ip_and_hostname, because only the
      #       IP address is required to be unique.  So we'll find_or_create_by_ip,
      #       and then add in the hostname if it didn't exist.
      iphost = IPHost.find_or_create_by_ip(ip_str)
      if iphost.hostname != hostname_str
        update_hostname = iphost.hostname.to_s.empty? || hostname_str != ip_str
        if update_hostname
          iphost.hostname = hostname_str
          iphost.save!
        end
      end
      playername = Playername.find_or_create_by_playername(playername_str)
      servername = Servername.find_or_create_by_servername(servername_str)
      playerseen = PlayerSeen.find_or_create_by_iphost_oid_and_playername_oid_and_servername_oid(iphost.oid, playername.oid, servername.oid)
      
      if playerseen.first_seen.nil?
        playerseen.first_seen = timestamp
      end
      playerseen.last_seen = timestamp
      playerseen.times_seen = playerseen.times_seen.to_i + times_seen_inc
      playerseen.save!
    }
}
  end
  
  def self.grep(substr, limit=1000, columns=["playername", "ip", "hostname"])
    substr_esc = PlayerSeen.ogstore.escape(substr)
    store_type =  ogstore.ogmanager.options[:store]
    like_op = (store_type == :postgresql) ? 'ILIKE' : 'LIKE'
    sql =
      "SELECT #{Playername.table}.playername, #{Servername.table}.servername, "+
      "#{IPHost.table}.ip, #{IPHost.table}.hostname, "+
      "#{PlayerSeen.table}.first_seen, #{PlayerSeen.table}.last_seen, #{PlayerSeen.table}.times_seen "+
      "FROM #{PlayerSeen.table} LEFT JOIN #{IPHost.table} ON #{PlayerSeen.table}.iphost_oid = #{IPHost.table}.oid "+
      "LEFT JOIN #{Playername.table} ON #{PlayerSeen.table}.playername_oid = #{Playername.table}.oid "+
      "LEFT JOIN #{Servername.table} ON #{PlayerSeen.table}.servername_oid = #{Servername.table}.oid "
      searches = []
      searches << "#{Playername.table}.playername #{like_op} '%#{substr_esc}%'" if columns.include? "playername"
      searches << "#{IPHost.table}.ip #{like_op} '%#{substr_esc}%'" if columns.include? "ip"
      searches << "#{IPHost.table}.hostname #{like_op} '%#{substr_esc}%'" if columns.include? "hostname"
      unless searches.empty?
        sql << "WHERE "
        sql << searches.join(" OR ")
      end
      sql << " ORDER BY #{PlayerSeen.table}.last_seen DESC"
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

  def self.aliases_for_ip(ip_str, limit=100)
    ipstr_esc = PlayerSeen.ogstore.escape(ip_str)
    sql =
      "SELECT #{Playername.table}.playername, #{Servername.table}.servername, "+
      "#{IPHost.table}.ip, #{IPHost.table}.hostname, "+
      "#{PlayerSeen.table}.first_seen, #{PlayerSeen.table}.last_seen, #{PlayerSeen.table}.times_seen "+
      "FROM #{PlayerSeen.table} LEFT JOIN #{IPHost.table} ON #{PlayerSeen.table}.iphost_oid = #{IPHost.table}.oid "+
      "LEFT JOIN #{Playername.table} ON #{PlayerSeen.table}.playername_oid = #{Playername.table}.oid "+
      "LEFT JOIN #{Servername.table} ON #{PlayerSeen.table}.servername_oid = #{Servername.table}.oid "+
      "WHERE #{IPHost.table}.ip = '#{ipstr_esc}' "+
      # weight playername usage frequency against recentness of last use
      "ORDER BY ( (1.0 / (GREATEST(1, (current_date - #{PlayerSeen.table}.last_seen::date)::integer + 1))) * #{PlayerSeen.table}.times_seen) DESC"
#     "ORDER BY #{PlayerSeen.table}.last_seen DESC"
    sql << " LIMIT #{limit}" if limit
    res = PlayerSeen.ogstore.query(sql)
    rows = []
    res.each_row {|row,dummy| rows << row}
    rows
  end

  # Try an exact playername lookup.  If that fails, do a case-insensitive substring
  # grep for the most recently seen similar name.
  # NOTE: Returns a Playername object, not just a string.  (Or, nil if not found.)
  def self.find_closest_playername(playername_str)
    player = Playername.find_by_playername(playername_str)
    return player if player
    rows = self.grep(playername_str, 1, ["playername"])
    return nil if rows.empty?
    closest_name = rows.last[0]
    $stderr.puts "find_closest_playername: #{playername_str.inspect} -> #{closest_name.inspect}"
    Playername.find_by_playername(closest_name)
  end
end

# We use the following identifer to accumulate stats for
# "any server" or "any method" or "any victim" etc.
# NOTE: This means a player can never be named the same
# as this identifier.  If a player ever did have exactly
# that name, we should munge the playername somehow.
STATS_TOTAL_NAME = "__total__"

class SuicidesAllTime
  property :method, String      # ex: mg, cg, trap, phalanx, lava, squished, cratered, drowned
  property :date, Date
  property :count, Integer
  refers_to :servername, Servername
  refers_to :victim, Playername

  def self.create_unique_index
    sql = "CREATE UNIQUE INDEX #{table}_unique ON #{table} "+
          "(servername_oid, victim_oid, method, date)"
    begin
      ogstore.exec(sql)
    rescue Og::StoreException => ex
    end
  end

  def self.log_suicide(victim_name_str, method_str, servername_str, count=1, date=Date.today)
    date = get_insert_date(date)
    victim = server = nil
    __total__ = STATS_TOTAL_NAME

    # sanity-check playername (can't handle a player called __total__)
    victim_name_str = "total" if victim_name_str == __total__

    #self.ogstore.transaction {  # NOTE: Now using a single transaction in PlayerIPStats.log_suicide 
victim = servername = nil    
$SW.measure("log_suicide_#{table}__find") {
    
      @playername_total ||= Playername.find_or_create_by_playername(__total__)
      @servername_total ||= Servername.find_or_create_by_servername(__total__)

      victim     = Playername.find_or_create_by_playername(victim_name_str)
      servername = Servername.find_or_create_by_servername(servername_str)

}

      date_str = "#{date.year}-#{date.month}-#{date.mday}"

      # We want to update 8 different records, comprising various
      # combinations of frag count totals.
      # First, find out which rows already exist:

      # puts "\n**************************************************************"
      # sql = "SELECT rowid, oid, servername_oid, victim_oid, method, count FROM #{self.table} ORDER BY rowid"
      # res = self.ogstore.query(sql)
      # res.each_row do |row,dummy|
      #   puts "row=#{row.inspect}"
      # end

existing_rows = nil
$SW.measure("log_suicide_#{table}__scan") {

      svo = servername.oid  ; svt = @servername_total.oid
      vmo = victim.oid      ; vmt = @playername_total.oid
      mod = method_str      ; mot = __total__
      
      sql = 
        "SELECT oid, servername_oid, victim_oid, method, count " +
        "FROM #{self.table} " +
        "WHERE " +
           "(servername_oid = #{svo} AND victim_oid = #{vmo} AND method = '#{mod}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svo} AND victim_oid = #{vmo} AND method = '#{mot}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svo} AND victim_oid = #{vmt} AND method = '#{mod}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svo} AND victim_oid = #{vmt} AND method = '#{mot}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svt} AND victim_oid = #{vmo} AND method = '#{mod}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svt} AND victim_oid = #{vmo} AND method = '#{mot}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svt} AND victim_oid = #{vmt} AND method = '#{mod}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svt} AND victim_oid = #{vmt} AND method = '#{mot}' AND date = '#{date_str}')"

    # WAY SLOWER IN POSTGRES:
    # sql = 
    #   "SELECT oid, servername_oid, victim_oid, method, count " +
    #   "FROM #{self.table} " +
    #   "WHERE " +
    #       "(servername_oid = #{servername.oid} OR servername_oid = #{@servername_total.oid}) " +
    #   "AND (victim_oid = #{victim.oid} OR victim_oid = #{@playername_total.oid}) " +
    #   "AND (method = '#{method_str}' OR method = '#{__total__}') " +
    #   "AND date = '#{date_str}'"
    #
      # puts "\nSQL = #{sql}"
      res = self.ogstore.query(sql)
      existing_rows = {}
      res.each_row do |row,dummy|
        row_key = gen_row_key(*row[1..3])  # servername_oid..method
        existing_rows[row_key] = [row[0], row[4]]  # [oid, count]
      end
      # puts "existing_rows=#{existing_rows.inspect}"
}

$SW.measure("log_suicide_#{table}__update") {

      store_type =  ogstore.ogmanager.options[:store]
      if store_type == :sqlite
        update_suicide_counts__sqlite(@servername_total.oid, @playername_total.oid, servername.oid, victim.oid, method_str, date_str, existing_rows, count)
      elsif store_type == :postgresql
        update_suicide_counts__postgresql(@servername_total.oid, @playername_total.oid, servername.oid, victim.oid, method_str, date_str, existing_rows, count)
      else
        raise "unknown store type @{store_type}"
      end
}

    #}
  end

  def self.total_suicides(victim_name_str, method_str, servername_str, date=Date.today)
    date = get_insert_date(date)
    total = 0
    __total__ = STATS_TOTAL_NAME
    
    @playername_total ||= Playername.find_or_create_by_playername(__total__)
    @servername_total ||= Servername.find_or_create_by_servername(__total__)

    if victim_name_str == __total__
      victim = @playername_total
    else
      victim = PlayerSeen.find_closest_playername(victim_name_str)
    end
    
    if servername_str == __total__
      servername = @servername_total
    else
      servername = Servername.find_by_servername(servername_str)
    end

    if victim && servername
      suicide_record = self.find_by_servername_oid_and_victim_oid_and_method_and_date(servername.oid, victim.oid, method_str, date)
      if suicide_record
        total = suicide_record.count.to_i
      end
    end
    total
  end

  ##
  ## TODO: Optimize top_suicides_list query with qtype, ala top_frags_list.
  ##
  def self.top_suicides_list(victim_name_str, method_str, servername_str, date=Date.today, limit=10)
    date = get_insert_date(date)
    __total__ = STATS_TOTAL_NAME
    
    @playername_total ||= Playername.find_or_create_by_playername(__total__)
    @servername_total ||= Servername.find_or_create_by_servername(__total__)
    date_str = "#{date.year}-#{date.month}-#{date.mday}"

    if victim_name_str.nil?
      victim = nil
    elsif victim_name_str == __total__
      victim = @playername_total
    else
      victim = PlayerSeen.find_closest_playername(victim_name_str)
      return [] unless victim
    end
    
    if servername_str.nil?
      servername = nil
    elsif servername_str == __total__
      servername = @servername_total
    else
      servername = Servername.find_by_servername(servername_str)
      return [] unless servername
    end

    ptotal = @playername_total
    stotal = @servername_total

    sql =
      "SELECT P1.playername AS victim, " +
             "FRAG.method, SV.servername AS server, FRAG.count " +
        "FROM #{self.table} FRAG, #{Playername.table} P1, " +
             "#{Servername.table} SV " +
       "WHERE " +
         (victim ? "FRAG.victim_oid = #{victim.oid}" : "FRAG.victim_oid <> #{ptotal.oid}") +
        " AND " + (servername ? "FRAG.servername_oid = #{servername.oid}" : "FRAG.servername_oid <> #{stotal.oid}") +
        " AND " + (method_str ? "FRAG.method = '#{method_str}'" : "FRAG.method <> '#{__total__}'") +
        " AND FRAG.date = '#{date_str}' " +
         "AND P1.oid = FRAG.victim_oid " +
         "AND SV.oid = FRAG.servername_oid " +
         "ORDER BY FRAG.count DESC"
    sql << " LIMIT #{limit}" if limit
    res = ogstore.query(sql)
    rows = []
    res.each_row {|row,dummy| rows << row}
    rows
  end

  # SuicidesAllTime always uses epoch for date.  It's a waste of a
  # column, but on the other hand it's consistent with the other
  # Suicides classes.
  def self.get_insert_date(date)
    Date.new(1970, 1, 1)
  end

  protected

  def self.update_suicide_counts__postgresql(servername_total_oid, playername_total_oid, servername_oid, victim_oid, method_str, date_str, existing_rows, count)
    __total__ = STATS_TOTAL_NAME
    sql = ""
    sql << gen_update_suicide_count_sql__postgresql(servername_oid,       victim_oid,           method_str, date_str, existing_rows, count)
    sql << gen_update_suicide_count_sql__postgresql(servername_oid,       victim_oid,           __total__,  date_str, existing_rows, count)
    sql << gen_update_suicide_count_sql__postgresql(servername_oid,       playername_total_oid, method_str, date_str, existing_rows, count)
    sql << gen_update_suicide_count_sql__postgresql(servername_oid,       playername_total_oid, __total__,  date_str, existing_rows, count)
    sql << gen_update_suicide_count_sql__postgresql(servername_total_oid, victim_oid,           method_str, date_str, existing_rows, count)
    sql << gen_update_suicide_count_sql__postgresql(servername_total_oid, victim_oid,           __total__,  date_str, existing_rows, count)
    sql << gen_update_suicide_count_sql__postgresql(servername_total_oid, playername_total_oid, method_str, date_str, existing_rows, count)
    sql << gen_update_suicide_count_sql__postgresql(servername_total_oid, playername_total_oid, __total__,  date_str, existing_rows, count)
    ogstore.exec(sql)
  end

  def self.gen_update_suicide_count_sql__postgresql(servername_oid, victim_oid, method_str, date_str, existing_rows, count)
    row_key = gen_row_key(servername_oid, victim_oid, method_str)
    if rowdat = existing_rows[row_key]
      # update existing row
      oid, old_count = *rowdat
      sql =
        "UPDATE #{self.table} " +
        "SET count=#{old_count.to_i + count} " +
        "WHERE oid=#{oid};\n"
    else
      # insert new row (Unfortunately, sqlite doesn't have postgres' nextval, so
      # as far as I know we've got to insert the row first, then update it to set
      # the oid.)
      sql =
        "INSERT INTO #{self.table} (oid, servername_oid, victim_oid, method, date, count) " +
        "VALUES (nextval('#{self.table}_oid_seq'), #{servername_oid}, #{victim_oid}, '#{method_str}', '#{date_str}', #{count});\n"
    end
    sql
  end

  def self.update_suicide_counts__sqlite(servername_total_oid, playername_total_oid, servername_oid, victim_oid, method_str, date_str, existing_rows, count)
    __total__ = STATS_TOTAL_NAME
    sql = ""
    sql << gen_update_suicide_count_sql__sqlite(servername_oid,       victim_oid,           method_str, date_str, existing_rows, count)
    sql << gen_update_suicide_count_sql__sqlite(servername_oid,       victim_oid,           __total__,  date_str, existing_rows, count)
    sql << gen_update_suicide_count_sql__sqlite(servername_oid,       playername_total_oid, method_str, date_str, existing_rows, count)
    sql << gen_update_suicide_count_sql__sqlite(servername_oid,       playername_total_oid, __total__,  date_str, existing_rows, count)
    sql << gen_update_suicide_count_sql__sqlite(servername_total_oid, victim_oid,           method_str, date_str, existing_rows, count)
    sql << gen_update_suicide_count_sql__sqlite(servername_total_oid, victim_oid,           __total__,  date_str, existing_rows, count)
    sql << gen_update_suicide_count_sql__sqlite(servername_total_oid, playername_total_oid, method_str, date_str, existing_rows, count)
    sql << gen_update_suicide_count_sql__sqlite(servername_total_oid, playername_total_oid, __total__,  date_str, existing_rows, count)
    
    # NOTE: For some reason, can't build the whole SQL string containing
    # multiple inserts and updates and exec it all in one shot.  (No errors
    # were reported, but only some of the queries were executed, apparently.)
    # So we'll break it back down into lines... :-(
    sql.each_line do |line|
      ogstore.exec(line)
    end
  end

  def self.gen_update_suicide_count_sql__sqlite(servername_oid, victim_oid, method_str, date_str, existing_rows, count)
    row_key = gen_row_key(servername_oid, victim_oid, method_str)
    if rowdat = existing_rows[row_key]
      # update existing row
      oid, old_count = *rowdat
      sql =
        "UPDATE #{self.table} " +
        "SET count=#{old_count.to_i + count} " +
        "WHERE oid=#{oid};\n"
    else
      # insert new row (Unfortunately, sqlite doesn't have postgres' nextval, so
      # as far as I know we've got to insert the row first, then update it to set
      # the oid.)
      sql =
        "INSERT INTO #{self.table} (oid, servername_oid, victim_oid, method, date, count) " +
        "VALUES (NULL, #{servername_oid}, #{victim_oid}, '#{method_str}', '#{date_str}', #{count});\n" +
        "UPDATE #{self.table} " +
        "SET oid=(SELECT last_insert_rowid()) " +
        "WHERE rowid=(SELECT last_insert_rowid());\n"
    end
    sql
  end
  
  def self.gen_row_key(servername_oid, victim_oid, method_str)
    [servername_oid, victim_oid, method_str].join("\t")
  end

  # pure Og update, easy to write, but slow:  
  # def self.update_suicide_count(servername, victim, method_str, count, date)
  #   suicide_record = self.find_or_create_by_servername_oid_and_victim_oid_and_method_and_date(servername.oid, victim.oid, method_str, date)
  #   suicide_record.count = suicide_record.count.to_i + count
  #   suicide_record.save!
  # end
end

class SuicidesMonthly < SuicidesAllTime
  # SuicidesMonthly always uses the 1st of the month.
  def self.get_insert_date(date)
    Date.new(date.year, date.month, 1)
  end
end

class SuicidesDaily < SuicidesAllTime
  def self.get_insert_date(date)
    date
  end
end


def self.log_suicide(victim_name_str, method_str, servername_str, count=1, date=Date.today)
  SuicidesAllTime.ogstore.transaction {
    SuicidesAllTime.log_suicide(victim_name_str, method_str, servername_str, count, date)
    SuicidesMonthly.log_suicide(victim_name_str, method_str, servername_str, count, date)
    SuicidesDaily.log_suicide(victim_name_str, method_str, servername_str, count, date)
  }
end


class FragsAllTime
  property :method, String      # ex: mg, cg, trap, phalanx, lava, squished, cratered, drowned
  property :date, Date
  property :count, Integer
  refers_to :servername, Servername
  refers_to :inflictor, Playername
  refers_to :victim, Playername

  def self.create_unique_index
    sql = "CREATE UNIQUE INDEX #{table}_unique ON #{table} "+
          "(servername_oid, inflictor_oid, victim_oid, method, date)"
    begin
      ogstore.exec(sql)
    rescue Og::StoreException => ex
    end
  end

  def self.log_frag(inflictor_name_str, victim_name_str, method_str, servername_str, count=1, date=Date.today)
    date = get_insert_date(date)
    inflictor = victim = server = nil
    __total__ = STATS_TOTAL_NAME
    
    # sanity-check playernames (can't handle a player called __total__)
    inflictor_name_str = "total" if inflictor_name_str == __total__
    victim_name_str = "total" if victim_name_str == __total__
    
    #self.ogstore.transaction {  NOTE: Now using a single transaction in PlayerIPStats.log_frag
inflictor = victim = servername = nil
$SW.measure("log_frag_#{table}__find") {

      @playername_total ||= Playername.find_or_create_by_playername(__total__)
      @servername_total ||= Servername.find_or_create_by_servername(__total__)

      inflictor  = Playername.find_or_create_by_playername(inflictor_name_str)
      victim     = Playername.find_or_create_by_playername(victim_name_str)
      servername = Servername.find_or_create_by_servername(servername_str)

}

      date_str = "#{date.year}-#{date.month}-#{date.mday}"

      # We want to update 16 different records, comprising various
      # combinations of frag count totals.
      # First, find out which rows already exist:

      # puts "\n**************************************************************"
      # sql = "SELECT rowid, oid, servername_oid, inflictor_oid, victim_oid, method, count FROM #{self.table} ORDER BY rowid"
      # res = self.ogstore.query(sql)
      # res.each_row do |row,dummy|
      #   puts "row=#{row.inspect}"
      # end

existing_rows = nil
$SW.measure("log_frag_#{table}__scan") {

      svo = servername.oid  ; svt = @servername_total.oid
      ifo = inflictor.oid   ; ift = @playername_total.oid
      vmo = victim.oid      ; vmt = @playername_total.oid
      mod = method_str      ; mot = __total__
      
      sql = 
        "SELECT oid, servername_oid, inflictor_oid, victim_oid, method, count " +
        "FROM #{self.table} " +
        "WHERE " +
           "(servername_oid = #{svo} AND inflictor_oid = #{ifo} AND victim_oid = #{vmo} AND method = '#{mod}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svo} AND inflictor_oid = #{ifo} AND victim_oid = #{vmo} AND method = '#{mot}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svo} AND inflictor_oid = #{ifo} AND victim_oid = #{vmt} AND method = '#{mod}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svo} AND inflictor_oid = #{ifo} AND victim_oid = #{vmt} AND method = '#{mot}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svo} AND inflictor_oid = #{ift} AND victim_oid = #{vmo} AND method = '#{mod}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svo} AND inflictor_oid = #{ift} AND victim_oid = #{vmo} AND method = '#{mot}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svo} AND inflictor_oid = #{ift} AND victim_oid = #{vmt} AND method = '#{mod}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svo} AND inflictor_oid = #{ift} AND victim_oid = #{vmt} AND method = '#{mot}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svt} AND inflictor_oid = #{ifo} AND victim_oid = #{vmo} AND method = '#{mod}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svt} AND inflictor_oid = #{ifo} AND victim_oid = #{vmo} AND method = '#{mot}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svt} AND inflictor_oid = #{ifo} AND victim_oid = #{vmt} AND method = '#{mod}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svt} AND inflictor_oid = #{ifo} AND victim_oid = #{vmt} AND method = '#{mot}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svt} AND inflictor_oid = #{ift} AND victim_oid = #{vmo} AND method = '#{mod}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svt} AND inflictor_oid = #{ift} AND victim_oid = #{vmo} AND method = '#{mot}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svt} AND inflictor_oid = #{ift} AND victim_oid = #{vmt} AND method = '#{mod}' AND date = '#{date_str}') " +
        "OR (servername_oid = #{svt} AND inflictor_oid = #{ift} AND victim_oid = #{vmt} AND method = '#{mot}' AND date = '#{date_str}')";

    # WAY SLOWER IN POSTGRES:
    # sql = 
    #   "SELECT oid, servername_oid, inflictor_oid, victim_oid, method, count " +
    #   "FROM #{self.table} " +
    #   "WHERE " +
    #       "(servername_oid = #{servername.oid} OR servername_oid = #{@servername_total.oid}) " +
    #   "AND (inflictor_oid = #{inflictor.oid} OR inflictor_oid = #{@playername_total.oid}) " +
    #   "AND (victim_oid = #{victim.oid} OR victim_oid = #{@playername_total.oid}) " +
    #   "AND (method = '#{method_str}' OR method = '#{__total__}') " +
    #   "AND date = '#{date_str}'"
    #   
      # puts "\nSQL = #{sql}"
      res = self.ogstore.query(sql)
      existing_rows = {}
      res.each_row do |row,dummy|
        row_key = gen_row_key(*row[1..4])  # servername_oid..method
        existing_rows[row_key] = [row[0], row[5]]  # [oid, count]
      end
      # puts "existing_rows=#{existing_rows.inspect}"

}

$SW.measure("log_frag_#{table}__update") {

      store_type =  ogstore.ogmanager.options[:store]
      if store_type == :sqlite
        update_frag_counts__sqlite(@servername_total.oid, @playername_total.oid, servername.oid, inflictor.oid, victim.oid, method_str, date_str, existing_rows, count)
      elsif store_type == :postgresql
        update_frag_counts__postgresql(@servername_total.oid, @playername_total.oid, servername.oid, inflictor.oid, victim.oid, method_str, date_str, existing_rows, count)
      else
        raise "unknown store type @{store_type}"
      end
}
    #}
  end

  def self.total_frags(inflictor_name_str, victim_name_str, method_str, servername_str, date=Date.today)
    date = get_insert_date(date)
    total = 0
    __total__ = STATS_TOTAL_NAME
    
    @playername_total ||= Playername.find_or_create_by_playername(__total__)
    @servername_total ||= Servername.find_or_create_by_servername(__total__)

    if inflictor_name_str == __total__
      inflictor = @playername_total
    else
      inflictor = PlayerSeen.find_closest_playername(inflictor_name_str)
    end

    if victim_name_str == __total__
      victim = @playername_total
    else
      victim = PlayerSeen.find_closest_playername(victim_name_str)
    end
    
    if servername_str == __total__
      servername = @servername_total
    else
      servername = Servername.find_by_servername(servername_str)
    end

    if inflictor && victim && servername
      frag_record = self.find_by_servername_oid_and_inflictor_oid_and_victim_oid_and_method_and_date(servername.oid, inflictor.oid, victim.oid, method_str, date)
      if frag_record
        total = frag_record.count.to_i
      end
    end
    total
  end

  def self.top_frags_list(inflictor_name_str, victim_name_str, method_str, servername_str, date=Date.today, limit=10)
    date = get_insert_date(date)
    __total__ = STATS_TOTAL_NAME
    
    @playername_total ||= Playername.find_or_create_by_playername(__total__)
    @servername_total ||= Servername.find_or_create_by_servername(__total__)
    date_str = "#{date.year}-#{date.month}-#{date.mday}"

    if inflictor_name_str.nil?
      inflictor = nil
    elsif inflictor_name_str == __total__
      inflictor = @playername_total
    else
      inflictor = PlayerSeen.find_closest_playername(inflictor_name_str)
      return [] unless inflictor
    end

    if victim_name_str.nil?
      victim = nil
    elsif victim_name_str == __total__
      victim = @playername_total
    else
      victim = PlayerSeen.find_closest_playername(victim_name_str)
      return [] unless victim
    end
    
    if servername_str.nil?
      servername = nil
    elsif servername_str == __total__
      servername = @servername_total
    else
      servername = Servername.find_by_servername(servername_str)
      return [] unless servername
    end

    ptotal = @playername_total
    stotal = @servername_total

    qtype = (inflictor  ? 8 : 0) |
            (victim     ? 4 : 0) |
            (servername ? 2 : 0) |
            (method_str ? 1 : 0)

    sql =
      "SELECT P1.playername AS inflictor, P2.playername AS victim, " +
             "FRAG.method, SV.servername AS server, FRAG.count " +
        "FROM #{self.table} FRAG, #{Playername.table} P1, #{Playername.table} P2, " +
             "#{Servername.table} SV " +
       "WHERE "
    if date_is_relevant?
      if qtype == 0
        sql << "FRAG.date = '#{date_str}' AND " 
      else
        sql << "(FRAG.date = '#{date_str}' AND " 
      end
    else
      if qtype != 0
        sql << "("
      end
    end
    sql << case qtype
    when  0 then "(FRAG.inflictor_oid <> #{ptotal.oid} AND FRAG.victim_oid <> #{ptotal.oid} AND FRAG.servername_oid <> #{stotal.oid} AND FRAG.method <> '#{__total__}') "
    when  1 then "FRAG.method = '#{method_str}') AND (FRAG.inflictor_oid <> #{ptotal.oid} AND FRAG.victim_oid <> #{ptotal.oid} AND FRAG.servername_oid <> #{stotal.oid}) "
    when  2 then "FRAG.servername_oid = #{servername.oid}) AND (FRAG.inflictor_oid <> #{ptotal.oid} AND FRAG.victim_oid <> #{ptotal.oid} AND FRAG.method <> '#{__total__}') "
    when  3 then "FRAG.servername_oid = #{servername.oid} AND FRAG.method = '#{method_str}') AND (FRAG.inflictor_oid <> #{ptotal.oid} AND FRAG.victim_oid <> #{ptotal.oid}) "
    when  4 then "FRAG.victim_oid = #{victim.oid}) AND (FRAG.inflictor_oid <> #{ptotal.oid} AND FRAG.servername_oid <> #{stotal.oid} AND FRAG.method <> '#{__total__}') "
    when  5 then "FRAG.victim_oid = #{victim.oid} AND FRAG.method = '#{method_str}') AND (FRAG.inflictor_oid <> #{ptotal.oid} AND FRAG.servername_oid <> #{stotal.oid}) "
    when  6 then "FRAG.victim_oid = #{victim.oid} AND FRAG.servername_oid = #{servername.oid}) AND (FRAG.inflictor_oid <> #{ptotal.oid} AND FRAG.method <> '#{__total__}') "
    when  7 then "FRAG.victim_oid = #{victim.oid} AND FRAG.servername_oid = #{servername.oid} AND FRAG.method = '#{method_str}') AND (FRAG.inflictor_oid <> #{ptotal.oid}) "
    when  8 then "FRAG.inflictor_oid = #{inflictor.oid}) AND (FRAG.victim_oid <> #{ptotal.oid} AND FRAG.servername_oid <> #{stotal.oid} AND FRAG.method <> '#{__total__}') "
    when  9 then "FRAG.inflictor_oid = #{inflictor.oid} AND FRAG.method = '#{method_str}') AND (FRAG.victim_oid <> #{ptotal.oid} AND FRAG.servername_oid <> #{stotal.oid}) "
    when 10 then "FRAG.inflictor_oid = #{inflictor.oid} AND FRAG.servername_oid = #{servername.oid}) AND (FRAG.victim_oid <> #{ptotal.oid} AND FRAG.method <> '#{__total__}') "
    when 11 then "FRAG.inflictor_oid = #{inflictor.oid} AND FRAG.servername_oid = #{servername.oid} AND FRAG.method = '#{method_str}') AND (FRAG.victim_oid <> #{ptotal.oid}) "
    when 12 then "FRAG.inflictor_oid = #{inflictor.oid} AND FRAG.victim_oid = #{victim.oid}) AND (FRAG.servername_oid <> #{stotal.oid} AND FRAG.method <> '#{__total__}') "
    when 13 then "FRAG.inflictor_oid = #{inflictor.oid} AND FRAG.victim_oid = #{victim.oid} AND FRAG.method = '#{method_str}') AND (FRAG.servername_oid <> #{stotal.oid}) "
    when 14 then "FRAG.inflictor_oid = #{inflictor.oid} AND FRAG.victim_oid = #{victim.oid} AND FRAG.servername_oid = #{servername.oid}) AND (FRAG.method <> '#{__total__}') "
    when 15 then "FRAG.inflictor_oid = #{inflictor.oid} AND FRAG.victim_oid = #{victim.oid} AND FRAG.servername_oid = #{servername.oid} AND FRAG.method = '#{method_str}') "
    end
    sql <<    
        "AND     (P1.oid = FRAG.inflictor_oid " +
             "AND P2.oid = FRAG.victim_oid " +
             "AND SV.oid = FRAG.servername_oid) " +
         "ORDER BY FRAG.count DESC"
    sql << " LIMIT #{limit}" if limit
$stderr.puts "qtype #{qtype}: #{sql}"
    res = ogstore.query(sql)
    rows = []
    res.each_row {|row,dummy| rows << row}
    rows
  end

  # FragsAllTime always uses epoch for date.  It's a waste of a
  # column, but on the other hand it's consistent with the other
  # Frags classes.
  def self.get_insert_date(date)
    Date.new(1970, 1, 1)
  end
  
  def self.date_is_relevant?
    false
  end

  protected

  def self.update_frag_counts__postgresql(servername_total_oid, playername_total_oid, servername_oid, inflictor_oid, victim_oid, method_str, date_str, existing_rows, count)
    __total__ = STATS_TOTAL_NAME
    sql = ""
    sql << gen_update_frag_count_sql__postgresql(servername_oid,       inflictor_oid,        victim_oid,           method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_oid,       inflictor_oid,        victim_oid,           __total__,  date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_oid,       inflictor_oid,        playername_total_oid, method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_oid,       inflictor_oid,        playername_total_oid, __total__,  date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_oid,       playername_total_oid, victim_oid,           method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_oid,       playername_total_oid, victim_oid,           __total__,  date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_oid,       playername_total_oid, playername_total_oid, method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_oid,       playername_total_oid, playername_total_oid, __total__,  date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_total_oid, inflictor_oid,        victim_oid,           method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_total_oid, inflictor_oid,        victim_oid,           __total__,  date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_total_oid, inflictor_oid,        playername_total_oid, method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_total_oid, inflictor_oid,        playername_total_oid, __total__,  date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_total_oid, playername_total_oid, victim_oid,           method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_total_oid, playername_total_oid, victim_oid,           __total__,  date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_total_oid, playername_total_oid, playername_total_oid, method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__postgresql(servername_total_oid, playername_total_oid, playername_total_oid, __total__,  date_str, existing_rows, count)
    # $stderr.puts "update_frag_count: #{sql}"
    ogstore.exec(sql)
  end

  def self.gen_update_frag_count_sql__postgresql(servername_oid, inflictor_oid, victim_oid, method_str, date_str, existing_rows, count)
    row_key = gen_row_key(servername_oid, inflictor_oid, victim_oid, method_str)
    if rowdat = existing_rows[row_key]
      # update existing row
      oid, old_count = *rowdat
      sql =
        "UPDATE #{self.table} " +
        "SET count=#{old_count.to_i + count} " +
        "WHERE oid=#{oid};\n"
    else
      sql =
        "INSERT INTO #{self.table} (oid, servername_oid, inflictor_oid, victim_oid, method, date, count) " +
        "VALUES (nextval('#{self.table}_oid_seq'), #{servername_oid}, #{inflictor_oid}, #{victim_oid}, '#{method_str}', '#{date_str}', #{count});\n"
    end
    sql
  end
  
  def self.update_frag_counts__sqlite(servername_total_oid, playername_total_oid, servername_oid, inflictor_oid, victim_oid, method_str, date_str, existing_rows, count)
    __total__ = STATS_TOTAL_NAME
    sql = ""
    sql << gen_update_frag_count_sql__sqlite(servername_oid,       inflictor_oid,        victim_oid,           method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_oid,       inflictor_oid,        victim_oid,           __total__,  date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_oid,       inflictor_oid,        playername_total_oid, method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_oid,       inflictor_oid,        playername_total_oid, __total__,  date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_oid,       playername_total_oid, victim_oid,           method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_oid,       playername_total_oid, victim_oid,           __total__,  date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_oid,       playername_total_oid, playername_total_oid, method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_oid,       playername_total_oid, playername_total_oid, __total__,  date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_total_oid, inflictor_oid,        victim_oid,           method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_total_oid, inflictor_oid,        victim_oid,           __total__,  date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_total_oid, inflictor_oid,        playername_total_oid, method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_total_oid, inflictor_oid,        playername_total_oid, __total__,  date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_total_oid, playername_total_oid, victim_oid,           method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_total_oid, playername_total_oid, victim_oid,           __total__,  date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_total_oid, playername_total_oid, playername_total_oid, method_str, date_str, existing_rows, count)
    sql << gen_update_frag_count_sql__sqlite(servername_total_oid, playername_total_oid, playername_total_oid, __total__,  date_str, existing_rows, count)
    
    # NOTE: For some reason, can't build the whole SQL string containing
    # multiple inserts and updates and exec it all in one shot.  (No errors
    # were reported, but only some of the queries were executed, apparently.)
    # So we'll break it back down into lines... :-(
    sql.each_line do |line|
      ogstore.exec(line)
    end
  end

  def self.gen_update_frag_count_sql__sqlite(servername_oid, inflictor_oid, victim_oid, method_str, date_str, existing_rows, count)
    row_key = gen_row_key(servername_oid, inflictor_oid, victim_oid, method_str)
    if rowdat = existing_rows[row_key]
      # update existing row
      oid, old_count = *rowdat
      sql =
        "UPDATE #{self.table} " +
        "SET count=#{old_count.to_i + count} " +
        "WHERE oid=#{oid};\n"
    else
      # insert new row (Unfortunately, sqlite doesn't have postgres' nextval, so
      # as far as I know we've got to insert the row first, then update it to set
      # the oid.)
      sql =
        "INSERT INTO #{self.table} (oid, servername_oid, inflictor_oid, victim_oid, method, date, count) " +
        "VALUES (NULL, #{servername_oid}, #{inflictor_oid}, #{victim_oid}, '#{method_str}', '#{date_str}', #{count});\n" +
        "UPDATE #{self.table} " +
        "SET oid=(SELECT last_insert_rowid()) " +
        "WHERE rowid=(SELECT last_insert_rowid());\n"
    end
    sql
  end
  
  def self.gen_row_key(servername_oid, inflictor_oid, victim_oid, method_str)
    [servername_oid, inflictor_oid, victim_oid, method_str].join("\t")
  end

  # pure Og update, easy to write, but slow:  
  # def self.update_frag_count(servername, inflictor, victim, method_str, count, date)
  #   frag_record = self.find_or_create_by_servername_oid_and_inflictor_oid_and_victim_oid_and_method_and_date(servername.oid, inflictor.oid, victim.oid, method_str, date)
  #   frag_record.count = frag_record.count.to_i + count
  #   frag_record.save!
  # end
end

class FragsMonthly < FragsAllTime
  # FragsMonthly always uses the 1st of the month.
  def self.get_insert_date(date)
    Date.new(date.year, date.month, 1)
  end
  def self.date_is_relevant?
    true
  end
end

class FragsDaily < FragsAllTime
  def self.get_insert_date(date)
    date
  end
  def self.date_is_relevant?
    true
  end
end


def self.log_frag(inflictor_name_str, victim_name_str, method_str, servername_str, count=1, date=Date.today)
  FragsAllTime.ogstore.transaction {
    FragsAllTime.log_frag(inflictor_name_str, victim_name_str, method_str, servername_str, count, date)
    FragsMonthly.log_frag(inflictor_name_str, victim_name_str, method_str, servername_str, count, date)
    FragsDaily.log_frag(inflictor_name_str, victim_name_str, method_str, servername_str, count, date)
  }
end

def self.create_all_indices
  PlayerSeen.create_unique_index
  SuicidesAllTime.create_unique_index
  SuicidesMonthly.create_unique_index
  SuicidesDaily.create_unique_index
  FragsAllTime.create_unique_index
  FragsMonthly.create_unique_index
  FragsDaily.create_unique_index
end

end # module


# postgres:
# in theory, we can do:
#   store.exec "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
# inside a transaction block
# 

