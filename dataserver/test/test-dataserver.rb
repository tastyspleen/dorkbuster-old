
require 'socket'
require 'date'

require 'player_ip_stats_model'  # for STATS_TOTAL_NAME constant

require 'test/unit'


# def bmsimple(n=1)
#   before = Time.now
#   n.times {|i| yield(i)}
#   after = Time.now
#   $stderr.puts "\n#{n} iterations in #{after-before} seconds."
# end

class TestDataserver < Test::Unit::TestCase # :nodoc: all

  def setup
    @ds = IO.popen("ruby run_dataserver.rb -test --create-indices update query")
    @ds.gets  # wait until initialized
  end

  def teardown
    warn("teardown...")
    Process.kill("KILL", @ds.pid) if @ds
  end

  def test_all
    do_test_playerseen
    do_test_fragstats
  end

  def do_test_playerseen
    up = TCPSocket.new('127.0.0.1', 12345)
    t = Time.now.tv_sec
    
    # login
    up.puts "auth testing 1-2-3"
    assert_match( /^200 /, up.gets )
    
    # add some playerseen updates
    up.puts( ["playerseen", "ToxicWankey^MZC",  "80.7.163.161", "mutant", t, 1].join("\t") )
    assert_match( /^200 /, up.gets )
    up.puts( ["playerseen", "ToxicWankey^MZC",  "80.7.163.161", "vanilla", t+1, 2].join("\t") )
    assert_match( /^200 /, up.gets )
    up.puts( ["playerseen", "uberwhiner",       "80.7.163.161", "mutant", t+2, 1].join("\t") )
    assert_match( /^200 /, up.gets )
    up.puts( ["playerseen", "n00bsauce",        "80.7.163.161", "mutant", t+3, 1].join("\t") )
    assert_match( /^200 /, up.gets )
    up.puts( ["playerseen", "WallFly[BZZZ]",    "127.0.0.1", "mutant", t+4, 10].join("\t") )
    assert_match( /^200 /, up.gets )

    qy = TCPSocket.new('127.0.0.1', 12346)
    
    # try a playerseen grep
    qy.puts( ["playerseen_grep", "Toxic", 100].join("\t") )
    assert_match( /\A200 OK\n.*Toxic.*\t1\n.*Toxic.*\t2\n\n\z/, get_resp(qy) )
    
    # try playerseen aliases for IP
    qy.puts( ["aliases_for_ip", "80.7.163.161", 10].join("\t") )
    # maybe the query_server should actually do the times_seen vs. last_seen "mix" like db does?
    # .... so that we just get a nice tab-sep list of akas back ?
    # .... other wise we'd need to get rows back with times_seen etc.
    assert_match( /\A200 OK\nn00bsauce\tuberwhiner\tToxicWankey\^MZC\n\n\z/, get_resp(qy) )

    up.puts("quit")    
    up.close
    qy.puts("quit")
    qy.close
  end

  def do_test_fragstats
    up = TCPSocket.new('127.0.0.1', 12345)
    dstart = Date.parse("2007-01-15")
    yesterday = (dstart - 1).to_s
    today = dstart.to_s

    # login
    up.puts "auth testing 1-2-3"
    assert_match( /^200 /, up.gets )

    # add some frags
    up.puts( ["frag", "chaingun_lamer", "ToxicWankey^MZC",  "cg", "mutant", yesterday, 1].join("\t") )
    assert_match( /^200 /, up.gets )
    up.puts( ["frag", "trap_ho",        "ToxicWankey^MZC", "trap", "xatrix", yesterday, 2].join("\t") )
    assert_match( /^200 /, up.gets )
    up.puts( ["frag", "chaingun_lamer", "ToxicWankey^MZC",  "bfg", "vanilla", today, 2].join("\t") )
    assert_match( /^200 /, up.gets )
    
    # add some suicides
    up.puts( ["suicide", "ToxicWankey^MZC",  "grenade", "mutant", yesterday, 2].join("\t") )
    assert_match( /^200 /, up.gets )
    up.puts( ["suicide", "chaingun_lamer",   "bfg", "vanilla", today, 1].join("\t") )
    assert_match( /^200 /, up.gets )

    qy = TCPSocket.new('127.0.0.1', 12346)

    # query some frag totals
    ttl = PlayerIPStats::STATS_TOTAL_NAME
    qy.puts( ["frag_total", "daily", "chaingun_lamer", "ToxicWankey^MZC", ttl, ttl, today].join("\t") )
    assert_match( /\A200 OK\n2\n\n\z/, get_resp(qy) )
    qy.puts( ["frag_total", "daily", "chaingun_lamer", "ToxicWankey^MZC", ttl, ttl, yesterday].join("\t") )
    assert_match( /\A200 OK\n1\n\n\z/, get_resp(qy) )
    qy.puts( ["frag_total", "monthly", "chaingun_lamer", "ToxicWankey^MZC", ttl, ttl, today].join("\t") )
    assert_match( /\A200 OK\n3\n\n\z/, get_resp(qy) )
    qy.puts( ["frag_total", "alltime", "chaingun_lamer", "ToxicWankey^MZC", ttl, ttl, today].join("\t") )
    assert_match( /\A200 OK\n3\n\n\z/, get_resp(qy) )

    qy.puts( ["frag_total", "daily", ttl, "ToxicWankey^MZC", ttl, ttl, yesterday].join("\t") )
    assert_match( /\A200 OK\n3\n\n\z/, get_resp(qy) )
    qy.puts( ["frag_total", "alltime", ttl, "ToxicWankey^MZC", ttl, ttl, today].join("\t") )
    assert_match( /\A200 OK\n5\n\n\z/, get_resp(qy) )

    # query top frags list
    qy.puts( ["frag_list", "daily", "", ttl, ttl, ttl, today, 10].join("\t") )
    assert_match( /\A200 OK\nchaingun_lamer\t__total__\t__total__\t__total__\t2\n\n\z/, get_resp(qy) )
    qy.puts( ["frag_list", "daily", "", ttl, ttl, ttl, yesterday, 10].join("\t") )
    assert_match( /\A200 OK\ntrap_ho\t__total__\t__total__\t__total__\t2\nchaingun_lamer\t__total__\t__total__\t__total__\t1\n\n\z/, get_resp(qy) )

    # query some suicide totals
    qy.puts( ["suicide_total", "daily", "chaingun_lamer", ttl, ttl, today].join("\t") )
    assert_match( /\A200 OK\n1\n\n\z/, get_resp(qy) )
    qy.puts( ["suicide_total", "daily", "ToxicWankey^MZC", ttl, ttl, yesterday].join("\t") )
    assert_match( /\A200 OK\n2\n\n\z/, get_resp(qy) )
    qy.puts( ["suicide_total", "monthly", ttl, ttl, ttl, today].join("\t") )
    assert_match( /\A200 OK\n3\n\n\z/, get_resp(qy) )
    qy.puts( ["suicide_total", "alltime", ttl, ttl, ttl, today].join("\t") )
    assert_match( /\A200 OK\n3\n\n\z/, get_resp(qy) )

    # query top suicides list
    qy.puts( ["suicide_list", "daily", "", ttl, ttl, today, 10].join("\t") )
    assert_match( /\A200 OK\nchaingun_lamer\t__total__\t__total__\t1\n\n\z/, get_resp(qy) )
    qy.puts( ["suicide_list", "daily", "", ttl, ttl, yesterday, 10].join("\t") )
    assert_match( /\A200 OK\nToxicWankey\^MZC\t__total__\t__total__\t2\n\n\z/, get_resp(qy) )
    qy.puts( ["suicide_list", "alltime", "", ttl, ttl, today, 10].join("\t") )
    assert_match( /\A200 OK\nToxicWankey\^MZC\t__total__\t__total__\t2\nchaingun_lamer\t__total__\t__total__\t1\n\n\z/, get_resp(qy) )

    up.puts("quit")    
    up.close
    qy.puts("quit")
    qy.close
  end

  def get_resp(sock)
    resp = ""
    begin
      line = sock.gets
      resp << line
    end until line == "\n"
    resp
  end
end



# irb(main):001:0> require 'socket'
# => true
# irb(main):002:0> up = TCPSocket.new('127.0.0.1', 12345)
# => #<TCPSocket:0x2c23bd0>
# irb(main):003:0>
# irb(main):004:0* up.puts "xauth update updatepass"
# => nil
# irb(main):005:0> up.gets
# => "400 Bad or missing auth protocol start\n"
# irb(main):006:0> up.puts "xauth update updatepass"
# => nil
# irb(main):007:0> up = TCPSocket.new('127.0.0.1', 12345)
# => #<TCPSocket:0x2c17d98>
# irb(main):008:0> up.puts "auth update updatepass"
# => nil
# irb(main):009:0> up.gets
# => "200 OK\n"
# irb(main):010:0> ps = ["playerseen", "12.34.56.79", "mutant", Time.now.tv_sec]
# => ["playerseen", "12.34.56.79", "mutant", 1179302936]
# irb(main):011:0> up.puts ps.join("\t")
# => nil
# irb(main):012:0> up.gets
# => "403 Argument error\n"
# irb(main):013:0> ps = ["playerseen", "ToxicWankey^MZC", "12.34.56.79", "mutant", Time.now.tv_sec]
# => ["playerseen", "ToxicWankey^MZC", "12.34.56.79", "mutant", 1179303120]
# irb(main):014:0> up.puts ps.join("\t")
# => nil
# irb(main):015:0> up.gets
# => "200 OK\n"
# irb(main):016:0> ps = ["playerseen", "ToxicWankey^MZC", "12.34.56.79", "vanilla", Time.now.tv_sec]
# => ["playerseen", "ToxicWankey^MZC", "12.34.56.79", "vanilla", 1179303567]
# irb(main):017:0> up.puts ps.join("\t")
# => nil
# irb(main):018:0> up.gets
# => "200 OK\n"
# irb(main):019:0> qy = TCPSocket.new('127.0.0.1', 12346)
# => #<TCPSocket:0x2bee998>
# irb(main):020:0> pg = ["playerseen_grep", "Toxic", 100]
# => ["playerseen_grep", "Toxic", 100]
# irb(main):021:0> qy.puts pg.join("\t")
# => nil
# irb(main):022:0>

