#!/usr/bin/env ruby
#
# Example invocation:
# 
# $ ruby -I./dataserver dataserver/preparse_frag_stats.rb vanilla baseq2/vanilla*.log
#
# or:
#
# $ zcat ../remote-frag-logs/vanilla-*.log.gz | ruby dataserver/preparse_frag_logs.rb vanilla >> ../parsed-frag-logs/vanilla.txt
# 

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

  def clear
    @frags_by_date.clear
    @suicides_by_date.clear
    @cur_date = nil
    @cur_frags = nil
    @cur_suicides = nil
  end

  def dump_frag_data(sv_nick, io=STDOUT)
    dump_frag_hash(@frags_by_date, sv_nick, "f", io)
    dump_frag_hash(@suicides_by_date, sv_nick, "s", io)
  end
  
  def dump_frag_hash(fh, sv_nick, type, io)
    fh.keys.sort.each do |date|
      dat = fh[date]
      dat.keys.sort.each do |key|
        val = dat[key]
        io.puts "#{date}\t#{sv_nick}\t#{type}\t#{key}\t#{val}"
      end
    end
  end

  def log_frag(inflictor, victim, method_str)
    inflictor = normalize_name(inflictor)
    victim = normalize_name(victim)
    return if playername_is_bot?(inflictor)
    key = "#{inflictor}\t#{victim}\t#{method_str}"
    @cur_frags[key] += 1
  end

  def log_suicide(victim, method_str)
    victim = normalize_name(victim)
    return if playername_is_bot?(victim)
    key = "#{victim}\t#{method_str}"
    @cur_suicides[key] += 1
  end

  def normalize_name(name)
    name.tr("[\x00-\x1f\x80-\xff]", "").strip
  end

  def playername_is_bot?(name)
    name[0..4] == "[BOT]"
  end
end # FragData

class FragLogParser
  attr_reader :fragdata

  def initialize(sv_nick, logger)
    @sv_nick = sv_nick
    @logger = logger
    @fragdata = FragData.new
  end

  def accept(log_line)
    if log_line =~ /\A\[(\d{4}-\d{2}-\d{2}) \d{2}:\d{2}\] (.+)\z/
      date = $1
      line = $2
      if @fragdata.cur_date != date
        flush
        STDERR.print "#{date} "
        @fragdata.set_cur_date(date)
      end
      unless line =~ /\A(?:Rcon from |status\z)/
        ObitParseQ2.parse_obit_line(line, @fragdata)
      end
    end
  end

  def flush
    @fragdata.dump_frag_data(@sv_nick)
    @fragdata.clear
  end
end # ImportFragStats


sv_nick = ARGV.shift
logger = Logger.new
flp = FragLogParser.new(sv_nick, logger)

ARGF.each_line do |log_line|
  log_line.chomp!
  flp.accept log_line
end
flp.flush

STDERR.puts

