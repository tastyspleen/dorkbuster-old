
require 'socket'
require 'date'

require 'update_client'
require 'query_client'

require 'test/unit'

# def bmsimple(n=1)
#   before = Time.now
#   n.times {|i| yield(i)}
#   after = Time.now
#   $stderr.puts "\n#{n} iterations in #{after-before} seconds."
# end

class MockLogger
  def log(msg)
    $stderr.puts msg
  end
end

class TestDataserverClients < Test::Unit::TestCase # :nodoc: all

  def setup
    @logger = MockLogger.new
    @ds = IO.popen("ruby run_dataserver.rb -test --create-indices update query")
    puts "Waiting dataserver ready..." until @ds.gets == "DATASERVER_READY\n"
  end

  def teardown
    warn("teardown...")
    Process.kill("KILL", @ds.pid) if @ds
  end

  def test_all
    do_test_coalescing_backlog_queue
    do_test_playerseen
    do_test_fragstats
  end

  def do_test_coalescing_backlog_queue
    q = CoalescingBacklogQueue.new
    q.push(:aaa, 1)
    q.push(:bbb, 1)
    q.push(:ccc, 1)
    assert_equal( 3, q.length )
    q.push(:aaa, 2)
    q.push(:bbb, 3)
    q.push(:ccc, 4)
    assert_equal( 3, q.length )
    q.push(:quit, 1)
    
    th = Thread.new do
      result = []
      loop do
        env = q.pop
        break if env[0] == :quit
        result << env
      end
      result
    end
    result = th.value
    
    assert_equal( [[:aaa, 3], [:bbb, 4], [:ccc, 5]], result )
  end

  def do_test_playerseen
    up = UpdateClient.new(@logger, "127.0.0.1", 12345)
    up.connect
    t = Time.now

    # add some playerseen updates
    up.playerseen("ToxicWankey^MZC",  "80.7.163.161", "mutant", t, 1)
    up.playerseen("ToxicWankey^MZC",  "80.7.163.161", "vanilla", t+1, 2)
    up.playerseen("uberwhiner",       "80.7.163.161", "mutant", t+2, 1)
    up.playerseen("n00bsauce",        "80.7.163.161", "mutant", t+3, 1)
    up.playerseen("WallFly[BZZZ]",    "127.0.0.1",    "mutant", t+4, 10)
    up.playerseen("chaingun_lamer",   "70.87.101.66", "mutant", t+5, 1)
    up.flush

    qy = QueryClient.new(@logger, "127.0.0.1", 12346)

    # try a playerseen grep
    rows = qy.playerseen_grep("Toxic", 100)
    assert_match( /\AToxic.*\t1\nToxic.*\t2\z/, rejoin(rows) )

    # try playerseen aliases for IP
    resp = qy.aliases_for_ip("80.7.163.161", 10)
    assert_equal( ["n00bsauce", "uberwhiner", "ToxicWankey^MZC"], resp )

    up.close
    qy.close
  end

  def do_test_fragstats
    up = UpdateClient.new(@logger, "127.0.0.1", 12345)
    up.connect
    dstart = Date.parse("2007-01-15")
    yesterday = (dstart - 1).to_s
    today = dstart.to_s

    # add some frags
    up.frag("chaingun_lamer", "ToxicWankey^MZC",  "cg", "mutant", yesterday, 1)
    up.frag("trap_ho",        "ToxicWankey^MZC", "trap", "xatrix", yesterday, 2)
    up.frag("chaingun_lamer", "ToxicWankey^MZC",  "bfg", "vanilla", today, 2)
    
    # add some suicides
    up.suicide("ToxicWankey^MZC",  "grenade", "mutant", yesterday, 2)
    up.suicide("chaingun_lamer",   "bfg", "vanilla", today, 1)
    up.flush

    qy = QueryClient.new(@logger, "127.0.0.1", 12346)

    # query some frag totals
    ttl = QueryClient::TOTAL
    resp = qy.frag_total("daily", "chaingun_lamer", "ToxicWankey^MZC", ttl, ttl, today)
    assert_equal( 2, resp )
    resp = qy.frag_total("daily", "chaingun_lamer", "ToxicWankey^MZC", ttl, ttl, yesterday)
    assert_equal( 1, resp )
    resp = qy.frag_total("monthly", "chaingun_lamer", "ToxicWankey^MZC", ttl, ttl, today)
    assert_equal( 3, resp )
    resp = qy.frag_total("alltime", "chaingun_lamer", "ToxicWankey^MZC", ttl, ttl, today)
    assert_equal( 3, resp )
   
    resp = qy.frag_total("daily", ttl, "ToxicWankey^MZC", ttl, ttl, yesterday)
    assert_equal( 3, resp )
    resp = qy.frag_total("alltime", ttl, "ToxicWankey^MZC", ttl, ttl, today)
    assert_equal( 5, resp )
   
    # query top frags list
    rows = qy.frag_list("daily", "", ttl, ttl, ttl, today, 10)
    assert_match( /\Achaingun_lamer\t__total__\t__total__\t__total__\t2\z/, rejoin(rows) )
    rows = qy.frag_list("daily", "", ttl, ttl, ttl, yesterday, 10)
    assert_match( /\Atrap_ho\t__total__\t__total__\t__total__\t2\nchaingun_lamer\t__total__\t__total__\t__total__\t1\z/, rejoin(rows) )

    # try the fuzzy name matches
    resp = qy.frag_total("daily", ttl, "wAnK", ttl, ttl, yesterday)
    assert_equal( 3, resp )
    rows = qy.frag_list("daily", "aInGuN", ttl, ttl, ttl, today, 10)
    assert_match( /\Achaingun_lamer\t__total__\t__total__\t__total__\t2\z/, rejoin(rows) )
    
    # exercise all 16 cases in frags query (alltime case) :-/
    rows = qy.frag_list("alltime", nil, nil, nil, nil, today, 10); p rows
    rows = qy.frag_list("alltime", nil, nil, nil, ttl, today, 10); p rows
    rows = qy.frag_list("alltime", nil, nil, ttl, nil, today, 10); p rows
    rows = qy.frag_list("alltime", nil, nil, ttl, ttl, today, 10); p rows
    rows = qy.frag_list("alltime", nil, ttl, nil, nil, today, 10); p rows
    rows = qy.frag_list("alltime", nil, ttl, nil, ttl, today, 10); p rows
    rows = qy.frag_list("alltime", nil, ttl, ttl, nil, today, 10); p rows
    rows = qy.frag_list("alltime", nil, ttl, ttl, ttl, today, 10); p rows
    rows = qy.frag_list("alltime", ttl, nil, nil, nil, today, 10); p rows
    rows = qy.frag_list("alltime", ttl, nil, nil, ttl, today, 10); p rows
    rows = qy.frag_list("alltime", ttl, nil, ttl, nil, today, 10); p rows
    rows = qy.frag_list("alltime", ttl, nil, ttl, ttl, today, 10); p rows
    rows = qy.frag_list("alltime", ttl, ttl, nil, nil, today, 10); p rows
    rows = qy.frag_list("alltime", ttl, ttl, nil, ttl, today, 10); p rows
    rows = qy.frag_list("alltime", ttl, ttl, ttl, nil, today, 10); p rows
    rows = qy.frag_list("alltime", ttl, ttl, ttl, ttl, today, 10); p rows

    # exercise all 16 cases in frags query (non-alltime case) :-/
    rows = qy.frag_list("daily", nil, nil, nil, nil, today, 10); p rows
    rows = qy.frag_list("daily", nil, nil, nil, ttl, today, 10); p rows
    rows = qy.frag_list("daily", nil, nil, ttl, nil, today, 10); p rows
    rows = qy.frag_list("daily", nil, nil, ttl, ttl, today, 10); p rows
    rows = qy.frag_list("daily", nil, ttl, nil, nil, today, 10); p rows
    rows = qy.frag_list("daily", nil, ttl, nil, ttl, today, 10); p rows
    rows = qy.frag_list("daily", nil, ttl, ttl, nil, today, 10); p rows
    rows = qy.frag_list("daily", nil, ttl, ttl, ttl, today, 10); p rows
    rows = qy.frag_list("daily", ttl, nil, nil, nil, today, 10); p rows
    rows = qy.frag_list("daily", ttl, nil, nil, ttl, today, 10); p rows
    rows = qy.frag_list("daily", ttl, nil, ttl, nil, today, 10); p rows
    rows = qy.frag_list("daily", ttl, nil, ttl, ttl, today, 10); p rows
    rows = qy.frag_list("daily", ttl, ttl, nil, nil, today, 10); p rows
    rows = qy.frag_list("daily", ttl, ttl, nil, ttl, today, 10); p rows
    rows = qy.frag_list("daily", ttl, ttl, ttl, nil, today, 10); p rows
    rows = qy.frag_list("daily", ttl, ttl, ttl, ttl, today, 10); p rows

    # query some suicide totals
    resp = qy.suicide_total("daily", "chaingun_lamer", ttl, ttl, today)
    assert_equal( 1, resp )
    resp = qy.suicide_total("daily", "ToxicWankey^MZC", ttl, ttl, yesterday)
    assert_equal( 2, resp )
    resp = qy.suicide_total("monthly", ttl, ttl, ttl, today)
    assert_equal( 3, resp )
    resp = qy.suicide_total("alltime", ttl, ttl, ttl, today)
    assert_equal( 3, resp )
   
    # query top suicides list
    rows = qy.suicide_list("daily", "", ttl, ttl, today, 10)
    assert_match( /\Achaingun_lamer\t__total__\t__total__\t1\z/, rejoin(rows) )
    rows = qy.suicide_list("daily", "", ttl, ttl, yesterday, 10)
    assert_match( /\AToxicWankey\^MZC\t__total__\t__total__\t2\z/, rejoin(rows) )
    rows = qy.suicide_list("alltime", "", ttl, ttl, today, 10)
    assert_match( /\AToxicWankey\^MZC\t__total__\t__total__\t2\nchaingun_lamer\t__total__\t__total__\t1\z/, rejoin(rows) )

    up.close
    qy.close
  end

  def rejoin(rows)
    rows.map {|r| r.join("\t")}.join("\n")
  end

end


