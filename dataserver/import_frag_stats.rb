#!/usr/bin/env ruby
#
# Example invocation:
# 
# $ ruby -I./dataserver dataserver/import_frag_stats.rb vanilla baseq2/vanilla*.log
#
# or:
#
# $ zcat baseq2/vanilla*.log.gz | ruby -I./dataserver dataserver/import_frag_stats.rb vanilla
# 

require 'dataserver/update_client'
require 'dbmod/obit_parse_q2'

# [2006-03-31 19:57] glo-worm was popped by {{{{QUAKER}}}}'s grenade
# [2006-03-31 19:57] {{{{QUAKER}}}} was blown away by Melon's super shotgun
# [2014-06-01 00:39] Demon was railed by Ban Dam
# [2014-06-01 00:39] Fugu was disintegrated by MaxCow's BFG blast

class Logger
  def log(msg)
    warn msg
  end
end

class FragData
  attr_reader :frags_by_date, :suicides_by_date
  attr_reader :cur_date, :cur_frags, :cur_suicides

  def initialize
    @frags_by_date = {}
    @suicides_by_date = {}
    @cur_date = nil
  end

  def set_cur_date(datestr)
    @cur_frags = (@frags_by_date[datestr] ||= Hash.new(0))
    @cur_suicides = (@suicides_by_date[datestr] ||= Hash.new(0))
    @cur_date = datestr
  end
  
  def log_frag(inflictor, victim, method_str)
    return if playername_is_bot?(inflictor)
    key = "#{inflictor}\t#{victim}\t#{method_str}"
    @cur_frags[key] += 1
  end

  def log_suicide(victim, method_str)
    return if playername_is_bot?(victim)
    key = "#{victim}\t#{method_str}"
    @cur_suicides[key] += 1
  end

  def playername_is_bot?(name)
    name[0..4] == "[BOT]"
  end
end # FragData

class FragStatsImporter
  attr_reader :fragdata

  def initialize(sv_nick, logger)
    @sv_nick = sv_nick
    @logger = logger
    @up = UpdateClient.new(@logger)
    @fragdata = FragData.new
  end

  def accept(log_line)
    if log_line =~ /\A\[(\d{4}-\d{2}-\d{2}) \d{2}:\d{2}\] (.+)\z/
      date = $1
      line = $2
      if @fragdata.cur_date != date
        @fragdata.set_cur_date(date)
      end
# warn "calling parser with cur_date=#{@fragdata.cur_date} line=#{line.inspect}"
      ObitParseQ2.parse_obit_line(line, @fragdata)
    end
  end

  # don't forget @up.connect
  #
  
  #   @up.frag(inflictor, victim, method_str, @sv_nick, Date.today, 1)

  #   @up.suicide(victim, method_str, @sv_nick, Date.today, 1)

end # ImportFragStats


sv_nick = ARGV.shift
logger = Logger.new
imp = FragStatsImporter.new(sv_nick, logger)

ARGF.each_line do |log_line|
  log_line.chomp!
  imp.accept log_line
end

fbd = imp.fragdata.frags_by_date
sbd = imp.fragdata.suicides_by_date

fbd.keys.sort.each do |date|
  dat = fbd[date]
  dat.keys.sort.each do |key|
    val = dat[key]
    puts "#{date}\t#{key}\t#{val}"
  end
end


