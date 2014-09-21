#!/usr/bin/env ruby

$:.unshift "./dataserver"

require 'query_client'

sort_by_times_seen = ARGV.delete "--sort-by-times-seen"
coalesce_names = ARGV.delete "--coalesce-names"
arrange_names_by_ip = ARGV.delete "--names-by-ip"

abort "--coalesce-names and --names-by-ip are mutually exclusive" if coalesce_names && arrange_names_by_ip

class Logger
  def log(msg)
    STDERR.puts msg
  end
end

# name    server  ip              hostname                                first_seen              last_seen               times 
# Quaz    railz   71.197.123.181  c-71-197-123-181.hsd1.ca.comcast.net    2008-08-07 07:49:57     2008-09-12 00:09:34     22

C_NAME = 0
C_SV = 1
C_IP = 2
C_HOST = 3
C_FIRST_SEEN = 4
C_LAST_SEEN = 5
C_TIMES_SEEN = 6

def merge_row_data(row, new_row)
  xsv, sv = row[C_SV], new_row[C_SV]
  xsvs = xsv.split(/,/)
  xsvs << sv unless xsvs.include? sv
  row[C_SV] = xsvs.join(",")

  xip, ip = row[C_IP], new_row[C_IP]
  xips = xip.split(/,/)
  xips << ip unless xips.include? ip
  row[C_IP] = xips.join(",")

  xhost, host = row[C_HOST], new_row[C_HOST]
  xhosts = xhost.split(/,/)
  xhosts << host unless xhosts.include? host
  row[C_HOST] = xhosts.join(",")

  row[C_FIRST_SEEN] = new_row[C_FIRST_SEEN] if new_row[C_FIRST_SEEN] < row[C_FIRST_SEEN]
  row[C_LAST_SEEN] = new_row[C_LAST_SEEN] if new_row[C_LAST_SEEN] > row[C_LAST_SEEN]

  row[C_TIMES_SEEN] = (row[C_TIMES_SEEN].to_i + new_row[C_TIMES_SEEN].to_i).to_s
end

def do_coalesce_names(rows)
  by_name = {}
  rows.each do |row|
    lcname = row[C_NAME].downcase
    if by_name.has_key? lcname
      xrow = by_name[lcname]
      merge_row_data(xrow, row)
    else
      by_name[lcname] = row
    end
  end
  by_name.values
end

NIC_IP = 0
NIC_HOST = 1
NIC_TIMES_SEEN = 2
NIC_FIRST_SEEN = 3
NIC_LAST_SEEN = 4
NIC_NAMES = 5

def merge_row_into_iprow(row, iprow)
  iprow[NIC_IP] ||= row[C_IP]
  iprow[NIC_HOST] ||= row[C_HOST]
  iprow[NIC_TIMES_SEEN] = (iprow[NIC_TIMES_SEEN].to_i + row[C_TIMES_SEEN].to_i).to_s 
  iprow[NIC_FIRST_SEEN] = row[C_FIRST_SEEN] if iprow[NIC_FIRST_SEEN].nil? || (row[C_FIRST_SEEN] < iprow[NIC_FIRST_SEEN]) 
  iprow[NIC_LAST_SEEN] = row[C_LAST_SEEN] if iprow[NIC_LAST_SEEN].nil? || (row[C_LAST_SEEN] < iprow[NIC_LAST_SEEN]) 
  names = (iprow[NIC_NAMES] ||= Hash.new(0))
  names[row[C_NAME]] += row[C_TIMES_SEEN].to_i
end

def flatten_iprow_names(by_ip_hash)
  by_ip_hash.each_value do |iprow|
    names = iprow[NIC_NAMES]
    iprow[NIC_NAMES] = names.keys.sort_by{|n| -names[n]}.map{|n| "#{n}(#{names[n]})"}.join(" ")
  end
end

def do_arrange_names_by_ip(rows)
  by_ip = {}
  rows.each do |row|
    ip = row[C_IP]
    iprow = (by_ip[ip] ||= [])
    merge_row_into_iprow(row, iprow)
  end
  flatten_iprow_names(by_ip)
  by_ip.values
end

qy = QueryClient.new(Logger.new)

# rows = qy.playerseen_grep(ARGV.join(" "), 9999)

rows = []
ARGV.each {|term| rows += qy.playerseen_grep(term, 99999)}

if rows.length > 0
  if coalesce_names
    rows = do_coalesce_names(rows)
  elsif arrange_names_by_ip
    rows = do_arrange_names_by_ip(rows)
  end

  if sort_by_times_seen
    if coalesce_names
      rows = rows.sort_by {|row| [row[C_TIMES_SEEN].to_i,row[C_LAST_SEEN]]}.reverse
    else
      sort_col = arrange_names_by_ip ? NIC_TIMES_SEEN : C_TIMES_SEEN
      rows = rows.sort_by {|row| -(row[sort_col].to_i)}
    end
  else
    sort_col = arrange_names_by_ip ? NIC_FIRST_SEEN : C_FIRST_SEEN
    rows = rows.sort_by {|row| row[sort_col]}
  end

  if coalesce_names
    rows.each do |r|
    # row = [r[C_TIMES_SEEN],r[C_NAME],r[C_FIRST_SEEN],r[C_LAST_SEEN],r[C_SV],r[C_IP],r[C_HOST]]
      row = [r[C_TIMES_SEEN],r[C_NAME],r[C_FIRST_SEEN],r[C_LAST_SEEN],r[C_SV]]
      puts( row.join("\t") )
    end
  else
    rows.each {|row| puts row.join("\t")}
  end
else
  puts "not found"
end

