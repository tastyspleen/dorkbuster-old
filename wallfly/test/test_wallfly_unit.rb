
require 'test/wf_test_config'

class TestMapSpec < Test::Unit::TestCase
  def test_simple
    mspec = MapSpec.new("train")
    assert_equal( "train", mspec.shortname )
    assert( ! mspec.dmflags )
  end
  
  def test_dmflags_parse
    mspec = MapSpec.new("train(+a +pu -sm)")
    assert_equal( "train", mspec.shortname )
    assert_equal( "+a +pu -sm", mspec.dmflags )
  end
end

class TestMapRot < Test::Unit::TestCase
  def test_single
    rot = MapRot.new
    assert( ! rot.peek_next )

    rot.reset("aa")      
    assert_equal( "aa", rot.peek_next.shortname )
    rot.advance
    assert( ! rot.peek_next )
  end
  
  def test_multiple
    rot = MapRot.new("aa bb cc")
    assert_equal( "aa", rot.peek_next.shortname )
    assert_equal( "aa bb cc", rot.to_s  )
    rot.advance
    assert_equal( "bb", rot.peek_next.shortname )
    assert_equal( "bb cc", rot.to_s  )
    rot.advance
    assert_equal( "cc", rot.peek_next.shortname )
    assert_equal( "cc", rot.to_s  )
    rot.advance
    assert( ! rot.peek_next )
  end
  
  def test_with_dmflags
    rot = MapRot.new("aa(+a +pu) bb cc(+sm) dd(-a -pu -sm)")
    assert_equal( "aa", rot.peek_next.shortname )
    assert_equal( "+a +pu", rot.peek_next.dmflags )
    rot.advance
    assert_equal( "bb", rot.peek_next.shortname )
    assert( ! rot.peek_next.dmflags )
    rot.advance
    assert_equal( "cc", rot.peek_next.shortname )
    assert_equal( "+sm", rot.peek_next.dmflags )
    rot.advance
    assert_equal( "dd", rot.peek_next.shortname )
    assert_equal( "-a -pu -sm", rot.peek_next.dmflags )
    rot.advance
    assert( ! rot.peek_next )
  end

  def test_repeat
    rot = MapRot.new("aa bb cc -repeat")
    assert_equal( "aa", rot.peek_next.shortname )
    rot.advance
    assert_equal( "bb", rot.peek_next.shortname )
    rot.advance
    assert_equal( "cc", rot.peek_next.shortname )
    rot.advance
    assert_equal( "aa", rot.peek_next.shortname )
  end
  
  def test_oneshot_list
    rot = MapRot.new("aa bb cc -repeat")
    assert_equal( "aa bb cc", rot.next_n_maps(5).join(' ') )
    m1a = MapSpec.new("fubar", "123.45.67.89")
    m1b = MapSpec.new("shazam", "123.45.67.89")
    m2a = MapSpec.new("catanus", "86.75.30.9")
    m2b = MapSpec.new("wazoo", "86.75.30.9")
    rot.push_oneshot m1a
    assert_equal( "fubar aa bb cc", rot.next_n_maps(5).join(' ') )
    rot.push_oneshot m2a
    assert_equal( "fubar catanus aa bb cc", rot.next_n_maps(5).join(' ') )
    rot.push_oneshot m1b
    assert_equal( "fubar catanus shazam aa bb", rot.next_n_maps(5).join(' ') )
    rot.remove_by_key m1a.key
    assert_equal( "catanus aa bb cc", rot.next_n_maps(5).join(' ') )
    rot.advance
    assert_equal( "aa bb cc", rot.next_n_maps(5).join(' ') )
    rot.advance
    assert_equal( "bb cc aa", rot.next_n_maps(5).join(' ') )
  end

  def test_offlist_deferred_oneshots
    rot = MapRot.new("aa bb cc dd ee ff gg hh ii -repeat")
    onlist_defer = 1
    offlist_defer = 2
    rot.set_onlist_oneshot_defer_proc lambda{onlist_defer}
    rot.set_offlist_oneshot_defer_proc lambda{offlist_defer}
    c1_ip = "123.45.67.89"
    c2_ip = "86.75.30.9"
    c3_ip = "99.88.77.66"
    assert_equal( "aa bb cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
    rot.push_oneshot MapSpec.new("fubar", c1_ip)
    assert_equal( "aa bb fubar cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
    rot.push_oneshot MapSpec.new("shazam", c2_ip)
    assert_equal( "aa bb fubar cc dd shazam ee ff gg hh ii", rot.next_n_maps.join(' ') )
    # test maintaining deferrals after skipped maps
    rot.advance(false)  # skip
    rot.tidy_after_skipped_maps
    assert_equal( "bb cc fubar dd ee shazam ff gg hh ii aa", rot.next_n_maps.join(' ') )
    # try an onlist map
    rot.push_oneshot MapSpec.new("ii", c3_ip)
    assert_equal( "bb cc fubar dd ee shazam ff ii gg hh ii aa", rot.next_n_maps.join(' ') )
    # play them all
    8.times {rot.advance}
    assert_equal( "gg hh ii aa bb cc dd ee ff", rot.next_n_maps.join(' ') )
    # play a rotation map
    rot.advance
    assert_equal( "hh ii aa bb cc dd ee ff gg", rot.next_n_maps.join(' ') )
    # the rotation map should count against the deferral
    rot.push_oneshot MapSpec.new("fubar", c1_ip)
    assert_equal( "hh fubar ii aa bb cc dd ee ff gg", rot.next_n_maps.join(' ') )
    # play out one rotation map again
    3.times {rot.advance}
    assert_equal( "aa bb cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
    # adding an onlist map should go to the front now
    rot.push_oneshot MapSpec.new("gg", c1_ip)
    assert_equal( "gg aa bb cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
    # play out two rotation maps
    3.times {rot.advance}
    assert_equal( "cc dd ee ff gg hh ii aa bb", rot.next_n_maps.join(' ') )
    # offlist map should to to front now
    rot.push_oneshot MapSpec.new("shazam", c1_ip)
    assert_equal( "shazam cc dd ee ff gg hh ii aa bb", rot.next_n_maps.join(' ') )
  end

  def test_onlist_priority_over_offlist
    rot = MapRot.new("aa bb cc dd ee ff gg hh ii -repeat")
    onlist_defer = 0
    offlist_defer = 2
    rot.set_onlist_oneshot_defer_proc lambda{onlist_defer}
    rot.set_offlist_oneshot_defer_proc lambda{offlist_defer}
    c1_ip = "123.45.67.89"
    c2_ip = "86.75.30.9"
    c3_ip = "99.88.77.63"
    c4_ip = "99.88.77.64"
    c5_ip = "99.88.77.65"
    assert_equal( "aa bb cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
    rot.push_oneshot MapSpec.new("fubar", c1_ip)
    assert_equal( "aa bb fubar cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
    rot.push_oneshot MapSpec.new("gg", c2_ip)
    assert_equal( "gg aa fubar bb cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
    rot.remove_by_key(c2_ip)
    assert_equal( "aa bb fubar cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
    rot.push_oneshot MapSpec.new("gg", c2_ip)
    assert_equal( "gg aa fubar bb cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
    rot.push_oneshot MapSpec.new("hh", c3_ip)
    assert_equal( "gg hh fubar aa bb cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
    rot.push_oneshot MapSpec.new("ii", c4_ip)
    assert_equal( "gg hh fubar ii aa bb cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
    rot.push_oneshot MapSpec.new("spumco", c5_ip)
    assert_equal( "gg hh fubar ii aa spumco bb cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
    rot.remove_by_key(c1_ip)
    assert_equal( "gg hh ii spumco aa bb cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
    rot.push_oneshot MapSpec.new("ff", c1_ip)
    assert_equal( "gg hh ii spumco ff aa bb cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
    rot.remove_by_key(c2_ip)
    rot.remove_by_key(c3_ip)
    assert_equal( "ii ff spumco aa bb cc dd ee ff gg hh ii", rot.next_n_maps.join(' ') )
  end
end

class TestBindSpamTracker < Test::Unit::TestCase
  def test_something
    start_time = Time.now
    cur_time = start_time
    bs = BindSpamTracker.new( lambda{cur_time} )
    trigger_at_num = 3
    trigger_window_seconds = 10
    trigger_memory_seconds = 60
    assert( !bs.track("foo", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    assert( !bs.track("foo", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    assert( !bs.track("bar", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    assert(  bs.track("foo", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    assert( !bs.track("bar", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    assert(  bs.track("bar", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    assert( !bs.track("baz", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    cur_time += 6
    assert( !bs.track("baz", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    cur_time += 6
    # 3rd baz, but should not trip because 1st is outside 10 sec window
    assert( !bs.track("baz", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    cur_time += 4
    # 4th baz, three baz's should now be within the window
    assert(  bs.track("baz", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    cur_time += 30
    # the tripped phrases should still be within the memory window
    assert(  bs.track("foo", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    assert(  bs.track("bar", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    assert(  bs.track("baz", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    cur_time = start_time + trigger_memory_seconds + 1
    # outside the initial memory window, foo and bar should be free now
    assert( !bs.track("foo", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    assert( !bs.track("bar", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    assert(  bs.track("baz", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    cur_time = start_time + trigger_memory_seconds + 6 + 6 + 4
    assert(  bs.track("baz", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    cur_time += 1
    assert( !bs.track("baz", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    # test cleaning...
    assert_equal( 3, bs.instance_eval{ @bs.length } )
    assert_equal( 3, bs.instance_eval{ @bs_memory.length } )
    cur_time += BindSpamTracker::CLEAN_INTERVAL_SECS
    assert( !bs.track("qux", trigger_at_num, trigger_window_seconds, trigger_memory_seconds) )
    assert_equal( 1, bs.instance_eval{ @bs.length } )
    assert_equal( 0, bs.instance_eval{ @bs_memory.length } )
  end
end

class TestCompiledBan < Test::Unit::TestCase
  def test_name_not_equal
    ban = CompiledBan.new(%{cpe-.*hawaii.res.rr.com,name!=dr\\.death\\(dxm\\),name!=buttfuncis})
    mst = ban.match("foo",           "12.34.56.78", "timbuktu.com")
    assert( !mst.trigger? ) ; assert ( !mst.partial? )
    mst = ban.match("dr.death(dxm)", "12.34.56.78", "timbuktu.com")
    assert( !mst.trigger? ) ; assert ( !mst.partial? )
    mst = ban.match("damien the dest", "67.49.159.95", "cpe-67-49-159-95.hawaii.res.rr.com")
    assert( mst.trigger? ) ; assert ( mst.partial? )
    mst = ban.match("damien the dest", "67.49.159.95", "cpe-67-49-159-95.timbuktu.res.rr.com")
    assert( !mst.trigger? ) ; assert ( !mst.partial? )
    mst = ban.match("dr.death(dxm)", "67.49.159.95", "cpe-67-49-159-95.hawaii.res.rr.com")
    assert( !mst.trigger? ) ; assert ( mst.partial? )
  end
  def test_name_equal
    ban = CompiledBan.new(%{cpe-.*hawaii.res.rr.com,name==foo,name==bar})
    mst = ban.match("foo",           "12.34.56.78", "cpe-67-49-159-95.hawaii.res.rr.com")
    assert( mst.trigger? ) ; assert ( mst.partial? )
    mst = ban.match("bar",           "12.34.56.78", "cpe-67-49-159-95.hawaii.res.rr.com")
    assert( mst.trigger? ) ; assert ( mst.partial? )
    mst = ban.match("baz",           "12.34.56.78", "cpe-67-49-159-95.hawaii.res.rr.com")
    assert( !mst.trigger? ) ; assert ( mst.partial? )
  end
  def test_name_only
    ban = CompiledBan.new(%{name==buttfuncis,name==jessoco})
    mst = ban.match("foo",           "12.34.56.78", "cpe-67-49-159-95.hawaii.res.rr.com")
    assert( ! mst.trigger? ) ; assert ( ! mst.partial? )
    mst = ban.match("buttfuncis",    "12.34.56.78", "cpe-67-49-159-95.hawaii.res.rr.com")
    assert( mst.trigger? ) ; assert ( ! mst.partial? )
    mst = ban.match("jessoco",       "12.34.56.78", "cpe-67-49-159-95.hawaii.res.rr.com")
    assert( mst.trigger? ) ; assert ( ! mst.partial? )
  end
  def test_multiple_iphost
    ban = CompiledBan.new(%{hawaii.res.rr.com,12.34.56.78})
    mst = ban.match("foo",           "12.34.56.78", "cpe-67-49-159-95.hawaii.res.rr.com")
    assert( mst.trigger? ) ; assert ( mst.partial? )
    mst = ban.match("foo",           "99.99.99.99", "cpe-67-49-159-95.hawaii.res.rr.com")
    assert( mst.trigger? ) ; assert ( mst.partial? )
    mst = ban.match("foo",           "12.34.56.78", "cpe-67-49-159-95.buttfuncis.res.rr.com")
    assert( mst.trigger? ) ; assert ( mst.partial? )
    mst = ban.match("foo",           "99.99.99.99", "cpe-67-49-159-95.buttfuncis.res.rr.com")
    assert( ! mst.trigger? ) ; assert ( ! mst.partial? )
  end
end


#
# TODO:
#   wanted: 
#     watch for downloads, if someone plays a custom map,
#     keep track of longest download time observered
#     multiply that by some scaling factor, 
#     and use that to establish a delay factor for
#     playing ---
#       "Sorry, last custom map caused 18 minute download (7 min avg.)  Next custom in 36 minutes."
#
#     be neat if players could ask for live-stats in game
#     and server statistics too as "average map length"
#       - how often a map tends to complete
#       - avg map duration for current server load:
#           (reports back) q2dm3 (The Fragpipe)  7.45 minutes at server load 23 of 32 (0.71875)
#

# TODO:
#   - allow weapon overrides:  gl=rail quad=none hb=rl
#   - make voteflags cmd, to specify legal votable dmflags for that server
#   - add help cmd
#
# DONE:
#   + admin command to insert/remove oneshot maps
#   + remove fluff dependency in changing maps (need default timelimit/fraglimit spec then?)
#   + added rdns-based bans
#   + save/load settings from disk
#   + ignore duplicate fraglimit hit / timelimit hit
#   + coalesce dmflags defaults+custom into one request !!
#   + enforce timelimit between playing same map
#   + enforce timelimit between some flags usage, like +ia
#   + added player nextmap cmd (for viewing next maps up)
#   + added invul/quad overrides when +pu / -pu
#   + added -h and -ws limits
#   + added unset command
#


