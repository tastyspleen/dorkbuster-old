
require 'test/wf_test_config'

class TestWallflyFunctional < Test::Unit::TestCase
  include WallflyTestConfig

  DMFLAGS_CMD_STR = Wallfly::DMFLAGS_CMD_STR
  FASTMAP_CMD_STR = Wallfly::FASTMAP_CMD_STR
  WF_LOGOUT_STR = %{12:34:59 quadz: wf, logout\r\n}
  TEST_STATE_FNAME = "wallfly_test_state.yml"
  TEST_BANS_FNAME = "wallfly_test_bans.yml"

  def setup
    File.delete(TEST_STATE_FNAME) rescue nil
    File.delete(TEST_BANS_FNAME) rescue nil
    setup_with_state(TEST_STATE_FNAME, TEST_BANS_FNAME)
  end
  
  def setup_with_state(state_fname, bans_fname)
    @mock_db_server = TCPServer.new(TEST_PORT)
    @lo_client = TCPSocket.new(TEST_HOST, TEST_PORT)
    @sv_client = @mock_db_server.accept
    sv_nick = "vanilla"
    q2wfip = "12.34.56.78"
    @wf = Wallfly.new(@lo_client, DB_USERNAME, DB_PASSWORD, state_fname, bans_fname, sv_nick, q2wfip)
    @wf.debounce_nextmap_trigger = false
    @wf.vars['delay/goto_name_change'] = "6"
  end
  
  def teardown
    @wf.close
    @sv_client.close
    @mock_db_server.close
  end    

  def test_persist_settings
    wf, sv_client = @wf, @sv_client

    votemaps_str = "wazoo fubar shazam"
    defflags_str = "-pu +a +h -ia +fd +ip +qd +sf +ws"
    maprot_str = "aa bb cc -repeat"
    
    sendstr( %{12:34:00 quadz: wf votemaps-set #{votemaps_str}\r\n} +
	     %{12:34:00 quadz: wf defflags #{defflags_str}\r\n} +
	     %{12:34:00 quadz: wf nextmap #{maprot_str}\r\n} +
	     %{12:34:00 quadz: wf ban cpe-.*hawaii.res.rr.com damien the dest\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run

    teardown
    setup_with_state(TEST_STATE_FNAME, TEST_BANS_FNAME)
    
    wf, sv_client = @wf, @sv_client
    
    tstamp = wf.gen_ban_timestamp
    reason_ann = "__quadz__#{tstamp}"

    assert_equal( defflags_str, wf.defflags )
    assert_equal( votemaps_str.split.sort, wf.votemaps.keys.sort )
    assert_equal( maprot_str, wf.cur_maprot.to_s )
    assert_equal( "damien_the_dest#{reason_ann}", wf.bans["cpe-.*hawaii.res.rr.com"] )
  end

  def test_mymap
    wf, sv_client = @wf, @sv_client

    defflags_str = "-pu +a +h -ia +fd +ip +qd +sf +ws"
    
    sendstr( %{12:34:00 quadz: wf votemaps-set wazoo fubar shazam\r\n} +
	     %{12:34:00 quadz: wf votemaps-set\r\n} +
	     %{12:34:00 quadz: wf defflags #{defflags_str}\r\n} +
	     %{12:34:00 quadz: wf defflags\r\n} +
	     %{12:34:00 quadz: wf nextmap aa bb cc -repeat\r\n} +
	     %{12:34:01 * Fraglimit hit.\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap fubar +pu +a -h +ia            [12|123.45.67.89]\r\n} +
	     %{12:35:02 * Fraglimit hit.\r\n} +
	     %{12:34:01 * bobo the chimp: mymap shazam pu ws           [3|86.75.30.9]\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap wazoo            [12|123.45.67.89]\r\n} +
	     %{12:34:01 * bobo the chimp: mymap fubar -ws           [3|86.75.30.9]\r\n} +
	     %{12:35:02 * Timelimit hit.\r\n} +
	     %{12:36:02 * Fraglimit hit.\r\n} +
	     %{12:36:02 * Fraglimit hit.\r\n} +
	     %{12:37:01 * bobo the chimp: mymap random +pu           [3|86.75.30.9]\r\n} +
	     %{12:37:02 * Timelimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{votemaps => fubar shazam wazoo\r}, sv_client )
    expect( %{votemaps => fubar shazam wazoo\r}, sv_client )
    expect( %{defflags => #{defflags_str}\r}, sv_client )
    expect( %{defflags => #{defflags_str}\r}, sv_client )
    expect( %{nextmap => aa bb cc -repeat\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + "\r", sv_client )
    expect( FASTMAP_CMD_STR + %{aa\r}, sv_client )
    expect( %{rcon say nextmap => fubar(+pu +a -h +ia) bb cc aa ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu +a -h +ia +ws\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{fubar\r}, sv_client )
    expect( %{rcon say nextmap => shazam(+pu +ws) bb cc aa ...\r}, sv_client )
    expect( %{rcon say nextmap => shazam(+pu +ws) wazoo bb cc aa ...\r}, sv_client )
    expect( %{rcon say nextmap => wazoo fubar(-ws) bb cc aa ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + "\r", sv_client )
    expect( FASTMAP_CMD_STR + %{wazoo\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ -ws\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{fubar\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + "\r", sv_client )
    expect( FASTMAP_CMD_STR + %{bb\r}, sv_client )
    # random... it's gotta be one of the votemaps:
    expect( /rcon say nextmap => (wazoo|fubar|shazam)\(\+pu\) cc aa bb \.\.\./, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + " +pu\r", sv_client )
    expect( /#{Regexp.quote(FASTMAP_CMD_STR)}(wazoo|fubar|shazam)/, sv_client )
    expect( %{cyas!\r}, sv_client )
    
    # now for the error conditions
    sendstr( %{12:34:01 * l33t_]<w4k3r_d00d: mymap            [12|123.45.67.89]\r\n} +
	     %{12:34:01 * name " ha$or: mymap shazam         [?]\r\n} +
	     %{12:34:01 * bobo the chimp: mymap shazam -ia +fu ws penis $rcon         [3|86.75.30.9]\r\n} +
	     %{12:34:01 * bobo the chimp: mymap rail$gunalley -ws        [3|86.75.30.9]\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( /say_person cl 12 Add a map/, sv_client )
    expect( /say_person cl 12 recognized maps are/, sv_client )
    expect( /say_person cl 12 fubar shazam wazoo/, sv_client )
    expect( /say_person cl 12 recognized dmflags are/, sv_client )
    expect( /say_person cl 12 example: mymap/, sv_client )
    expect( /say_person cl 12 .*which is:/, sv_client )
    expect( /rcon say Sorry "name ' ha\+or", couldn't/, sv_client )
    expect( /say_person cl 3 unrecognized dmflags: "\+fu penis \+rcon", valid dmflags/, sv_client )
    expect( /say_person cl 3 unrecognized map: "rail\+gunalley", valid maps/, sv_client )
    expect( /say_person cl 3 fubar shazam wazoo/, sv_client )
    expect( %{cyas!\r}, sv_client )
    
    # hot DISCONNECT action !
    sendstr( %{12:34:01 * l33t_]<w4k3r_d00d: mymap wazoo           [12|123.45.67.89]\r\n} +
	     %{12:34:01 * bobo the chimp: mymap shazam pu ws           [3|86.75.30.9]\r\n} +
	     %{10:41:13 DISCONNECT:  [12]  "l33t_ha_ha_ha"         123.45.67.89:33876 score:3 ping:64\r\n} +
	     %{12:34:00 quadz: wf nextmap\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{rcon say nextmap => wazoo cc aa bb ...\r}, sv_client )
    expect( %{rcon say nextmap => wazoo shazam(+pu +ws) cc aa bb ...\r}, sv_client )
    # verify wazoo is removed when client disco's
    expect( %{nextmap => shazam(+pu +ws) cc aa bb -repeat\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end

  def test_mymap_no_votemaps
    wf, sv_client = @wf, @sv_client

    sendstr( %{12:34:01 * l33t_]<w4k3r_d00d: mymap fubar +pu +a -h +ia            [12|123.45.67.89]\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( /say_person cl 12 Sorry, 'mymap' is not available/, sv_client )
    expect( %{cyas!\r}, sv_client )
  end
  
  def test_votemaps_add_remove
    wf, sv_client = @wf, @sv_client

    sendstr( %{12:34:00 quadz: wf votemaps-set wazoo fubar shazam\r\n} +
	     %{12:34:00 quadz: wf votemaps-add egg plant\r\n} +
	     %{12:34:00 quadz: wf votemaps-remove fubar shazam\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{votemaps => fubar shazam wazoo\r}, sv_client )
    expect( %{votemaps => egg fubar plant shazam wazoo\r}, sv_client )
    expect( %{votemaps => egg plant wazoo\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end
  
  def test_nextmap
    wf, sv_client = @wf, @sv_client
    
    # test nextmap set and fraglimit hit trigger
    sendstr( %{12:34:00 quadz: wf, nextmap train\r\n} +
	     %{12:34:01 * bozo: blah blah\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{nextmap => train\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{train\r}, sv_client )
    expect( %{cyas!\r}, sv_client )

    # test showing map list
    wf.reset
    sendstr( %{12:34:00 quadz: wf, nextmap\r\n} +
	     %{12:34:00 quadz: wf nextmap\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{nextmap => -none\r}, sv_client )
    expect( %{nextmap => -none\r}, sv_client )
    expect( %{cyas!\r}, sv_client )

    # test setting to -none removes trigger
    wf.reset
    sendstr( %{12:34:00 quadz: wf nextmap bunk1\r\n} +
	     %{12:34:00 quadz: wf nextmap -none\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{nextmap => bunk1\r}, sv_client )
    expect( %{nextmap => -none\r}, sv_client )
    expect( %{cyas!\r}, sv_client )

    # test multiple maps rotation
    wf.reset
    sendstr( %{12:34:00 quadz: wf nextmap aa bb(+a +pu) cc(-sm)\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{nextmap => aa bb(+a +pu) cc(-sm)\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{aa\r}, sv_client )
    expect( DMFLAGS_CMD_STR + %{+a +pu\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{bb\r}, sv_client )
    expect( DMFLAGS_CMD_STR + %{-sm\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{cc\r}, sv_client )
    expect( %{cyas!\r}, sv_client )

    # test -repeat
    wf.reset
    sendstr( %{12:34:00 quadz: wf nextmap aa bb -repeat\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{nextmap => aa bb -repeat\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{aa\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{bb\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{aa\r}, sv_client )

    # test succesive nextmap pushes
  end

  def test_ingame_nextmap
    wf, sv_client = @wf, @sv_client

    sendstr( %{12:34:00 quadz: wf nextmap aa bb cc -repeat\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: nextmap            [12|123.45.67.89]\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{nextmap => aa bb cc -repeat\r}, sv_client )
    expect( %{rcon say nextmap => aa bb cc ...\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end

  def test_debounce_nextmap_trigger
    wf, sv_client = @wf, @sv_client
    
    wf.debounce_nextmap_trigger = true

    # test nextmap set and fraglimit hit trigger
    sendstr( %{12:34:00 quadz: wf, nextmap aa bb\r\n} +
	     %{12:34:01 * bozo: blah blah\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{nextmap => aa bb\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{aa\r}, sv_client )
    expect( %{(Ignoring redundant nextmap trigger from server.)\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end

  def test_cmd_set
    wf, sv_client = @wf, @sv_client
    
    wf.vars.clear
    
    sendstr( %{12:34:00 quadz: wf, set\r\n} +
	     %{12:34:00 quadz: wf, set bad?varname\r\n} +
	     %{12:34:00 quadz: wf, set plover\r\n} +
	     %{12:34:00 quadz: wf, set plover 45\r\n} +
	     %{12:34:00 quadz: wf, set plover\r\n} +
	     %{12:34:00 quadz: wf, set xyzzy a quick brown f0x\r\n} +
	     %{12:34:00 quadz: wf, set\r\n} +
	     %{12:34:00 quadz: wf, unset xyzzy\r\n} +
	     %{12:34:00 quadz: wf, set\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{illegal characters in varname "bad?varname"\r}, sv_client )
    expect( %{"plover" is not set\r}, sv_client )
    expect( %{"plover" => 45\r}, sv_client )
    expect( %{"plover" => 45\r}, sv_client )
    expect( %{"xyzzy" => a quick brown f0x\r}, sv_client )
    expect( %{"plover" => 45\r}, sv_client )
    expect( %{"xyzzy" => a quick brown f0x\r}, sv_client )
    expect( %{"plover" => 45\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end
  
  def test_enforce_delay_between_repeated_mymap
    wf, sv_client = @wf, @sv_client

    defflags_str = "-pu +a +h -ia +fd +ip +qd +sf +ws"

    sendstr( %{12:34:00 quadz: wf votemaps-set wazoo fubar shazam\r\n} +
	     %{12:34:00 quadz: wf defflags #{defflags_str}\r\n} +
	     %{12:34:00 quadz: wf, set delay/same_map 45\r\n} +
	     %{12:34:00 quadz: wf nextmap aa fubar fubar cc -repeat\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap fubar +pu +a -h +ia            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap fubar +pu +a -h +ia            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{votemaps => fubar shazam wazoo\r}, sv_client )
    expect( %{defflags => #{defflags_str}\r}, sv_client )
    expect( %{"delay/same_map" => 45\r}, sv_client )
    expect( %{nextmap => aa fubar fubar cc -repeat\r}, sv_client )
    expect( %{rcon say nextmap => fubar(+pu +a -h +ia) aa fubar fubar cc ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu +a -h +ia +ws\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{fubar\r}, sv_client )
    expect( /say_person cl 12 Sorry, "fubar" has been played too recently. Try again in 45 min./, sv_client )
    expect( /say_person cl 12 The following maps are unavailable.*fubar\(45\)/, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + "\r", sv_client )
    expect( FASTMAP_CMD_STR + %{aa\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
    
    $wf_cur_time += (45 * 60)
    
    sendstr( %{12:34:01 * l33t_]<w4k3r_d00d: mymap fubar +pu +a -h +ia            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap fubar +pu +a -h +ia            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{rcon say nextmap => fubar(+pu +a -h +ia) fubar fubar cc aa ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu +a -h +ia +ws\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{fubar\r}, sv_client )
    expect( /say_person cl 12 Sorry, "fubar" has been played too recently. Try again in 45 min./, sv_client )
    expect( /say_person cl 12 The following maps are unavailable.*fubar\(45\)/, sv_client )
    expect( %{(Skipping map "fubar" in playlist, because played too recently.)\r}, sv_client )
    expect( %{(Skipping map "fubar" in playlist, because played too recently.)\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + "\r", sv_client )
    expect( FASTMAP_CMD_STR + %{cc\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end

  def test_map_skip_minclients
    wf, sv_client = @wf, @sv_client

    wf.squelch_replylog = true
    
    # sanity check:
    dbline = DBLine.new("12:34:01 * Fraglimit hit. ncl:10 apl:1")
    assert( dbline.is_map_over? )
    
    defflags_str = "-pu +a +h -ia +fd +ip +qd +sf +ws"
    
    sendstr(
      %{12:34:00 quadz: wf set delay/same_map 10\r\n} +
      %{12:34:00 quadz: wf set maps/teenymap/minclients 2\r\n} +
      %{12:34:00 quadz: wf set maps/smallmap/minclients 3\r\n} +
      %{12:34:00 quadz: wf set maps/medimap/minclients 5\r\n} +
      %{12:34:00 quadz: wf set maps/largemap/minclients 8\r\n} +
      %{12:34:00 quadz: wf set maps/megamap/minclients 12\r\n} +
      %{12:34:00 quadz: wf defflags #{defflags_str}\r\n} +
      %{12:34:00 quadz: wf votemaps-set teenymap smallmap medimap largemap megamap\r\n} +
      %{12:34:00 quadz: wf nextmap megamap largemap medimap smallmap teenymap -repeat\r\n} +
      %{12:34:01 * Fraglimit hit. ncl:10 apl:1\r\n} +
      %{12:35:01 * Timelimit hit. ncl:10 apl:1\r\n} +
      %{12:36:01 * Fraglimit hit. ncl:10 apl:1\r\n} +
      %{12:37:01 * Timelimit hit. ncl:10 apl:1\r\n} +
      %{12:38:01 * Fraglimit hit. ncl:10 apl:1\r\n} +
      %{12:39:01 * Timelimit hit. ncl:10 apl:1\r\n} +
      WF_LOGOUT_STR, sv_client
    )
    wf.run

    # We have apl:1, so we meet NONE of the maps minclients criteria.
    # Leaving us with teenymap as the initial nearest fit, then
    # the next largest map, and so on, until we run out.
    
    expect( %{"delay/same_map" => 10\r}, sv_client )
    expect( %{"maps/teenymap/minclients" => 2\r}, sv_client )
    expect( %{"maps/smallmap/minclients" => 3\r}, sv_client )
    expect( %{"maps/medimap/minclients" => 5\r}, sv_client )
    expect( %{"maps/largemap/minclients" => 8\r}, sv_client )
    expect( %{"maps/megamap/minclients" => 12\r}, sv_client )
    expect( %{defflags => #{defflags_str}\r}, sv_client )    
  # expect( %{votemaps => largemap medimap megamap smallmap teenymap\r}, sv_client )
  # expect( %{nextmap => megamap largemap medimap smallmap teenymap -repeat\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{teenymap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{smallmap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{medimap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{largemap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{megamap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{largemap\r}, sv_client )  # at this point it's given up and just gone with the next in the list (because ALL maps have now been played too recently)
    expect( %{cyas!\r}, sv_client )

    $wf_cur_time += (10 * 60)

    assert_equal( [], wf.get_random_allowed_maplist )  # not enough players for any
    
    sendstr(
      %{12:34:00 quadz: wf nextmap megamap largemap medimap smallmap teenymap -repeat\r\n} +
      %{12:34:01 * Fraglimit hit. ncl:10 apl:5\r\n} +
      %{12:35:01 * Fraglimit hit. ncl:10 apl:5\r\n} +
      %{12:36:01 * Fraglimit hit. ncl:10 apl:5\r\n} +
      %{12:37:01 * Fraglimit hit. ncl:10 apl:5\r\n} +
      %{12:38:01 * Fraglimit hit. ncl:10 apl:5\r\n} +
      %{12:39:01 * Fraglimit hit. ncl:10 apl:5\r\n} +
      WF_LOGOUT_STR, sv_client
    )
    wf.run

    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{medimap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{smallmap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{teenymap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{largemap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{megamap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{largemap\r}, sv_client )  # at this point it's given up and just gone with the next in the list (because ALL maps have now been played too recently)
    expect( %{cyas!\r}, sv_client )

    
    $wf_cur_time += (10 * 60)

    assert_equal( %w[teenymap smallmap medimap].sort, wf.get_random_allowed_maplist.sort )

    
    sendstr(
      %{12:34:00 quadz: wf nextmap megamap largemap medimap smallmap teenymap -repeat\r\n} +
      %{12:34:01 * bobo the chimp: mymap megamap           [3|86.75.30.9]\r\n} +
      %{12:34:01 * Fraglimit hit. ncl:10 apl:3\r\n} +
      %{12:34:01 * bobo the chimp: mymap megamap           [3|86.75.30.9]\r\n} +
      %{12:34:01 * ultran00b: mymap largemap          [4|86.75.30.10]\r\n} +
      %{12:34:01 * Fraglimit hit. ncl:10 apl:2\r\n} +
      %{12:34:01 * bobo the chimp: mymap megamap           [3|86.75.30.9]\r\n} +
      %{12:34:01 * ultran00b: mymap largemap          [4|86.75.30.10]\r\n} +
      %{12:34:01 * hootenanny: mymap medimap           [5|86.75.30.11]\r\n} +
      %{12:34:01 * Fraglimit hit. ncl:10 apl:1\r\n} +
      WF_LOGOUT_STR, sv_client
    )
    wf.run

    mega_needed = (12 * Wallfly::MYMAP_APL_LIMIT_REDUCE).round
    large_needed = (8 * Wallfly::MYMAP_APL_LIMIT_REDUCE).round
    medi_needed = (5 * Wallfly::MYMAP_APL_LIMIT_REDUCE).round
    expect( %{rcon say nextmap => megamap megamap largemap medimap smallmap teenymap ...\r}, sv_client )
    expect( /say_person cl 3 BTW: Map 'megamap' will be skipped if there are not at least #{mega_needed} active players/, sv_client )
    expect( %{rcon say Sorry, skipping map 'megamap' because not enough active players.\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{smallmap\r}, sv_client )
    
    expect( %{rcon say nextmap => megamap teenymap megamap largemap medimap smallmap ...\r}, sv_client )
    expect( /say_person cl 3 BTW: Map 'megamap' will be skipped if there are not at least #{mega_needed} active players/, sv_client )
    expect( %{rcon say nextmap => megamap largemap teenymap megamap largemap medimap smallmap ...\r}, sv_client )
    expect( /say_person cl 4 BTW: Map 'largemap' will be skipped if there are not at least #{large_needed} active players/, sv_client )
    expect( %{rcon say Sorry, skipping map 'megamap', and 1 other, because not enough active players.\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{teenymap\r}, sv_client )

    expect( %{rcon say nextmap => megamap megamap largemap medimap smallmap teenymap ...\r}, sv_client )
    expect( /say_person cl 3 BTW: Map 'megamap' will be skipped if there are not at least #{mega_needed} active players/, sv_client )
    expect( %{rcon say nextmap => megamap largemap megamap largemap medimap smallmap teenymap ...\r}, sv_client )
    expect( /say_person cl 4 BTW: Map 'largemap' will be skipped if there are not at least #{large_needed} active players/, sv_client )
    expect( %{rcon say nextmap => megamap largemap medimap megamap largemap medimap smallmap teenymap ...\r}, sv_client )
    expect( /say_person cl 5 BTW: Map 'medimap' will be skipped if there are not at least #{medi_needed} active players/, sv_client )
    # NOTE: despite intending to skip medimap, we end up picking it anyway, because
    # small and teeny have been played too recently, so we fell back to medi as the
    # best available fit:
  # expect( %{rcon say Sorry, skipping map 'megamap', and 2 others, because not enough active players.\r}, sv_client )
    expect( %{rcon say Sorry, skipping map 'megamap', and 1 other, because not enough active players.\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{medimap\r}, sv_client )

    expect( %{cyas!\r}, sv_client )

    
    $wf_cur_time += (10 * 60)
    
    sendstr(
      %{12:34:00 quadz: wf nextmap megamap largemap medimap smallmap teenymap -repeat\r\n} +
      %{12:34:01 * Timelimit hit. ncl:2 apl:0\r\n} +
      %{12:34:01 * Timelimit hit. ncl:2 apl:0\r\n} +
      %{12:34:01 * Timelimit hit. ncl:2 apl:0\r\n} +
      %{12:34:01 * Timelimit hit. ncl:2 apl:0\r\n} +
      %{12:34:01 * Timelimit hit. ncl:2 apl:0\r\n} +
      %{12:34:01 * Timelimit hit. ncl:2 apl:0\r\n} +
      WF_LOGOUT_STR, sv_client
    )
    wf.run

    # Special situation: With active_players zero, we remove the
    # map from the recently played tracking (since presumably
    # nobody was there to enjoy it, it shouldn't be off limits
    # when someone does finally join and mymap it.)
  # expect( %{nextmap => megamap largemap medimap smallmap teenymap -repeat\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{teenymap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{teenymap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{teenymap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{teenymap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{teenymap\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{teenymap\r}, sv_client )
    expect( %{cyas!\r}, sv_client )

  end

  def test_enforce_delay_between_repeated_ia
    wf, sv_client = @wf, @sv_client

    defflags_str = "-pu +a +h -ia +fd +ip +qd +sf +ws"

    sendstr( %{12:34:00 quadz: wf votemaps-set wazoo fubar shazam plugh plover\r\n} +
	     %{12:34:00 quadz: wf defflags #{defflags_str}\r\n} +
	     %{12:34:00 quadz: wf, set delay/ia 45\r\n} +
	     %{12:34:00 quadz: wf nextmap aa bb cc -repeat\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap fubar +pu +a -h +ia            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap wazoo +pu +a -h +ia            [12|123.45.67.89]\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap wazoo +pu +a -h            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{votemaps => fubar plover plugh shazam wazoo\r}, sv_client )
    expect( %{defflags => #{defflags_str}\r}, sv_client )
    expect( %{"delay/ia" => 45\r}, sv_client )
    expect( %{nextmap => aa bb cc -repeat\r}, sv_client )
    expect( %{rcon say nextmap => fubar(+pu +a -h +ia) aa bb cc ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu +a -h +ia +ws\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{fubar\r}, sv_client )
    expect( /say_person cl 12 Sorry, \+ia has been used too recently. Try again in 45 min./, sv_client )
    expect( %{rcon say nextmap => wazoo(+pu +a -h) aa bb cc ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu +a -h\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{wazoo\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + "\r", sv_client )
    expect( FASTMAP_CMD_STR + %{aa\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  
    $wf_cur_time += (45 * 60)

    # NOTE: buttfuncis will sneak in another +ia, but it should be detected at play time
    sendstr( %{12:34:01 * l33t_]<w4k3r_d00d: mymap plugh +pu +a -h +ia            [12|123.45.67.89]\r\n} +
	     %{12:34:01 * buttfuncis: mymap wazoo +pu +a -h +ia +ip            [13|123.45.67.90]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap plover +pu +a -h +ia            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{rcon say nextmap => plugh(+pu +a -h +ia) bb cc aa ...\r}, sv_client )
    expect( %{rcon say nextmap => plugh(+pu +a -h +ia) wazoo(+pu +a -h +ia +ip) bb cc aa ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu +a -h +ia +ws\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{plugh\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu +a -h +ip\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{wazoo\r}, sv_client )
    expect( /say_person cl 12 Sorry, \+ia has been used too recently. Try again in 45 min./, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + "\r", sv_client )
    expect( FASTMAP_CMD_STR + %{bb\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end

  def test_enforce_delay_between_repeated_ws
    wf, sv_client = @wf, @sv_client

    defflags_str = "-pu +a +h -ia +fd +ip +qd +sf +ws"

    sendstr( %{12:34:00 quadz: wf votemaps-set wazoo fubar shazam plugh plover\r\n} +
	     %{12:34:00 quadz: wf defflags #{defflags_str}\r\n} +
	     %{12:34:00 quadz: wf, set delay/ws 45\r\n} +
	     %{12:34:00 quadz: wf nextmap aa bb cc -repeat\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap fubar +pu +a -h -ws            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap wazoo +pu +a -h -ws            [12|123.45.67.89]\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap wazoo +pu +a -h            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{votemaps => fubar plover plugh shazam wazoo\r}, sv_client )
    expect( %{defflags => #{defflags_str}\r}, sv_client )
    expect( %{"delay/ws" => 45\r}, sv_client )
    expect( %{nextmap => aa bb cc -repeat\r}, sv_client )
    expect( %{rcon say nextmap => fubar(+pu +a -h -ws) aa bb cc ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu +a -h -ws\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{fubar\r}, sv_client )
    expect( /say_person cl 12 Sorry, \-ws has been used too recently. Try again in 45 min./, sv_client )
    expect( %{rcon say nextmap => wazoo(+pu +a -h) aa bb cc ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu +a -h\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{wazoo\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + "\r", sv_client )
    expect( FASTMAP_CMD_STR + %{aa\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  
    $wf_cur_time += (45 * 60)

    sendstr( %{12:34:01 * l33t_]<w4k3r_d00d: mymap plugh +pu +a -h -ws            [12|123.45.67.89]\r\n} +
	     %{12:34:01 * buttfuncis: mymap wazoo +pu +a -h -ws +ip            [13|123.45.67.90]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap plover +pu +a -h -ws            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{rcon say nextmap => plugh(+pu +a -h -ws) bb cc aa ...\r}, sv_client )
    expect( %{rcon say nextmap => plugh(+pu +a -h -ws) wazoo(+pu +a -h -ws +ip) bb cc aa ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu +a -h -ws\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{plugh\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu +a -h +ip\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{wazoo\r}, sv_client )
    expect( /say_person cl 12 Sorry, \-ws has been used too recently. Try again in 45 min./, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + "\r", sv_client )
    expect( FASTMAP_CMD_STR + %{bb\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end

  def test_enforce_delay_between_repeated_h
    wf, sv_client = @wf, @sv_client

    defflags_str = "-pu +a +h -ia +fd +ip +qd +sf +ws"

    sendstr( %{12:34:00 quadz: wf votemaps-set wazoo fubar shazam plugh plover\r\n} +
	     %{12:34:00 quadz: wf defflags #{defflags_str}\r\n} +
	     %{12:34:00 quadz: wf, set delay/h 45\r\n} +
	     %{12:34:00 quadz: wf nextmap aa bb cc -repeat\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap fubar +pu +a -h            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap wazoo +pu +a -h            [12|123.45.67.89]\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap wazoo +pu +a            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{votemaps => fubar plover plugh shazam wazoo\r}, sv_client )
    expect( %{defflags => #{defflags_str}\r}, sv_client )
    expect( %{"delay/h" => 45\r}, sv_client )
    expect( %{nextmap => aa bb cc -repeat\r}, sv_client )
    expect( %{rcon say nextmap => fubar(+pu +a -h) aa bb cc ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu +a -h\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{fubar\r}, sv_client )
    expect( /say_person cl 12 Sorry, \-h has been used too recently. Try again in 45 min./, sv_client )
    expect( %{rcon say nextmap => wazoo(+pu +a) aa bb cc ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu +a\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{wazoo\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + "\r", sv_client )
    expect( FASTMAP_CMD_STR + %{aa\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  
    $wf_cur_time += (45 * 60)

    sendstr( %{12:34:01 * l33t_]<w4k3r_d00d: mymap plugh +pu +a -h            [12|123.45.67.89]\r\n} +
	     %{12:34:01 * buttfuncis: mymap wazoo -h            [13|123.45.67.90]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap plover +pu +a -h            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{rcon say nextmap => plugh(+pu +a -h) bb cc aa ...\r}, sv_client )
    expect( %{rcon say nextmap => plugh(+pu +a -h) wazoo(-h) bb cc aa ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu +a -h\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{plugh\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{wazoo\r}, sv_client )
    expect( /say_person cl 12 Sorry, \-h has been used too recently. Try again in 45 min./, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + "\r", sv_client )
    expect( FASTMAP_CMD_STR + %{bb\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end

  def test_powerup_remap_settings
    wf, sv_client = @wf, @sv_client

    defflags_str = "-pu +a +h -ia +fd +ip +qd +sf +ws"

    wf.vars['pu_off/quad'] = "weapon_railgun"
    wf.vars['pu_off/invul'] = "item_pack"
    wf.vars['pu_on/quad'] = "item_quad"
    wf.vars['pu_on/invul'] = "item_invulnerability"

    sendstr( %{12:34:00 quadz: wf votemaps-set wazoo fubar shazam plugh plover\r\n} +
	     %{12:34:00 quadz: wf defflags #{defflags_str}\r\n} +
	     %{12:34:00 quadz: wf nextmap aa bb cc -repeat\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap fubar +pu            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: mymap wazoo -pu            [12|123.45.67.89]\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{votemaps => fubar plover plugh shazam wazoo\r}, sv_client )
    expect( %{defflags => #{defflags_str}\r}, sv_client )
    expect( %{nextmap => aa bb cc -repeat\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{\r}, sv_client )
    expect( "rcon set tune_spawn_quad weapon_railgun\r", sv_client )
    expect( "rcon set tune_spawn_invulnerability item_pack\r", sv_client )
    expect( FASTMAP_CMD_STR + %{aa\r}, sv_client )
    expect( %{rcon say nextmap => fubar(+pu) bb cc aa ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ +pu\r}, sv_client )
    expect( "rcon set tune_spawn_quad item_quad\r", sv_client )
    expect( "rcon set tune_spawn_invulnerability item_invulnerability\r", sv_client )
    expect( FASTMAP_CMD_STR + %{fubar\r}, sv_client )
    expect( %{rcon say nextmap => wazoo(-pu) bb cc aa ...\r}, sv_client )
    expect( DMFLAGS_CMD_STR + defflags_str + %{ -pu\r}, sv_client )
    expect( "rcon set tune_spawn_quad weapon_railgun\r", sv_client )
    expect( "rcon set tune_spawn_invulnerability item_pack\r", sv_client )
    expect( FASTMAP_CMD_STR + %{wazoo\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end
  
  def test_dns_ban
    # Socket.gethostbyname("67.49.159.95")
    # => ["cpe-67-49-159-95.hawaii.res.rr.com", [], 2, "C1\237_"]
    wf, sv_client = @wf, @sv_client

    tstamp = wf.gen_ban_timestamp
    reason_ann = "__quadz__#{tstamp}"
    sendstr( %{12:34:00 quadz: wf ban\r\n} +
	     %{12:34:00 quadz: wf ban cpe\r\n} +
	     %{12:34:00 quadz: wf ban cpe-( whooops\r\n} +
	     %{12:34:00 quadz: wf ban cpe-.*hawaii.res.rr.com,name!=dr\\.death\\(dxm\\) damien the dest\r\n} +
	     %{22:45:16 CONNECT:     [12] "l33t_]<w4k3r_d00d"      67.49.159.95:60768 (aka: pwsnskle, , Damien The Dest, I.Crash.Servers)\r\n} +
	     %{22:45:17 CONNECT:     [13] "near IP, different ISP"      67.49.218.97:60769\r\n} +
	     %{22:45:18 CONNECT:     [12] "dr.death(dxm)"      67.49.159.95:60770\r\n} +
	     %{22:45:19 NAME_CHANGE: [12] "pwsnskle"           67.49.159.95:60770 was: dr.death(dxm)\r\n} +
	     %{22:45:20 NAME_CHANGE: [12] "dr.death(dxm)"      67.49.159.95:60770 was: pwsnskle\r\n} +
	     %{22:45:19 NAME_CHANGE: [12] "oops"               67.49.159.95:60770 was: dr.death(dxm)\r\n} +
	     %{12:34:00 quadz: wf ban\r\n} +
	     %{12:34:00 quadz: wf unban\r\n} +
	     %{12:34:00 quadz: wf unban whoops\r\n} +
	     %{12:34:00 quadz: wf unban cpe-.*hawaii.res.rr.com,name!=dr\\.death\\(dxm\\)\r\n} +
	     %{12:34:01 quadz: wf ban bumttx\\.swbell\\.net bigd_hacking_jump_admin\r\n} +
	     %{11:25:01 CONNECT:     [7]  "x]EM[xBigd"         65.70.249.98:53248\r\n} +
	     %{11:25:01 ENTER_GAME:  [7]  "x]EM[xBigd"         65.70.249.98:53248\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( "No bans in database.\r", sv_client )
    expect( /Please specify additional info/, sv_client )
    expect( /Failed to compile ban/, sv_client )
    expect( "Ban added.\r", sv_client )
    expect( %{^9BAN: "l33t_]<w4k3r_d00d" 67.49.159.95 (cpe-67-49-159-95.hawaii.res.rr.com) [RULE: cpe-.*hawaii.res.rr.com,name!=dr\\.death\\(dxm\\) REASON: "damien_the_dest#{reason_ann}"]\r}, sv_client )
    expect( %r{rcon sv !ban IP 67.49.159.95 MSG .*BANNED.* TIME \d+}, sv_client )
  # expect( %r{rcon addhole 67.49.159.95/32 MESSAGE BANNED SUBNET}, sv_client )
    expect( "rcon kick 12\r", sv_client )
    expect( /BAN PARTIAL MATCH/, sv_client )
    expect( /BAN PARTIAL MATCH/, sv_client )
    expect( %{^9BAN: "oops" 67.49.159.95 (cpe-67-49-159-95.hawaii.res.rr.com) [RULE: cpe-.*hawaii.res.rr.com,name!=dr\\.death\\(dxm\\) REASON: "damien_the_dest#{reason_ann}"]\r}, sv_client )
  # NOTE: no addhole for simple name violation of an already connected player
  # expect( %r{rcon addhole 67.49.159.95/32 MESSAGE BANNED SUBNET}, sv_client )
    expect( "rcon kick 12\r", sv_client )
    expect( %{BAN RULE: cpe-.*hawaii.res.rr.com,name!=dr\\.death\\(dxm\\) REASON: "damien_the_dest#{reason_ann}"\r}, sv_client )
    expect( %{Please specify which ban rule to remove.\r}, sv_client )
    expect( %{Can't unban, RULE "whoops" not found.\r}, sv_client )
    expect( %{BAN RULE: cpe-.*hawaii.res.rr.com,name!=dr\\.death\\(dxm\\) ("damien_the_dest#{reason_ann}") removed.\r}, sv_client )
    expect( "Ban added.\r", sv_client )
    expect( %{^9BAN: "x]EM[xBigd" 65.70.249.98 (adsl-65-70-249-98.dsl.bumttx.swbell.net) [RULE: bumttx\\.swbell\\.net REASON: "bigd_hacking_jump_admin#{reason_ann}"]\r}, sv_client )
    expect( %r{rcon sv !ban IP 65.70.249.98 MSG .*BANNED.* TIME \d+}, sv_client )
  # expect( %r{rcon addhole 65.70.249.98/32 MESSAGE BANNED SUBNET}, sv_client )
    expect( "rcon kick 7\r", sv_client )
    expect( %{^9BAN: "x]EM[xBigd" 65.70.249.98 (adsl-65-70-249-98.dsl.bumttx.swbell.net) [RULE: bumttx\\.swbell\\.net REASON: "bigd_hacking_jump_admin#{reason_ann}"]\r}, sv_client )
    expect( %r{rcon sv !ban IP 65.70.249.98 MSG .*BANNED.* TIME \d+}, sv_client )
  # expect( %r{rcon addhole 65.70.249.98/32 MESSAGE BANNED SUBNET}, sv_client )
    expect( "rcon kick 7\r", sv_client )
    expect( %{cyas!\r}, sv_client )
  end

  def test_dns_mute
    # Socket.gethostbyname("67.49.159.95")
    # => ["cpe-67-49-159-95.hawaii.res.rr.com", [], 2, "C1\237_"]
    wf, sv_client = @wf, @sv_client

    tstamp = wf.gen_ban_timestamp
    reason_ann = "__quadz__#{tstamp}"
    sendstr( 
	     %{12:34:00 quadz: wf mute cpe-.*hawaii.res.rr.com,name!=dr\\.death\\(dxm\\) damien the dest\r\n} +
	     %{22:45:16 CONNECT:     [12] "l33t_]<w4k3r_d00d"      67.49.159.95:60768 (aka: pwsnskle, , Damien The Dest, I.Crash.Servers)\r\n} +
	     %{22:45:16 ENTER_GAME:  [12] "l33t_]<w4k3r_d00d"      67.49.159.95:60768\r\n} +
	     %{22:45:17 CONNECT:     [13] "near IP, different ISP"      67.49.218.97:60769\r\n} +
	     %{22:45:17 ENTER_GAME:  [13] "near IP, different ISP"      67.49.218.97:60769\r\n} +
	     %{22:45:16 CONNECT:     [14] "dr.death(dxm)"      67.49.159.95:60770\r\n} +
	     %{22:45:16 ENTER_GAME:  [14] "dr.death(dxm)"      67.49.159.95:60770\r\n} +
	     %{12:34:00 quadz: wf mute\r\n} +
	     %{12:34:00 * dr.death(dxm): i am excluded from the mute by playername            [14|67.49.159.95]\r\n} +
	     %{12:34:00 * l33t_]<w4k3r_d00d: i should be muted but q2admin botched it            [12|67.49.159.95]\r\n} +
	     %{22:45:16 CONNECT:     [15] ":colon-name"      67.49.159.95:60768 (aka: pwsnskle, , Damien The Dest, I.Crash.Servers)\r\n} +
	     %{22:45:16 ENTER_GAME:  [15] ":colon-name"      67.49.159.95:60768\r\n} +
	     %{12:34:00 quadz: wf unmute cpe-.*hawaii.res.rr.com,name!=dr\\.death\\(dxm\\)\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( "Mute added.\r", sv_client )
    expect( %{^dMUTE: "l33t_]<w4k3r_d00d" 67.49.159.95 (cpe-67-49-159-95.hawaii.res.rr.com) [RULE: cpe-.*hawaii.res.rr.com,name!=dr\\.death\\(dxm\\) REASON: "damien_the_dest#{reason_ann} -mute 0"]\r}, sv_client )
    expect( "rcon sv !mute CL 12 PERM\r", sv_client )
    expect( "rcon sv !mute CL 12 PERM\r", sv_client )
    expect( "rcon sv !mute CL 12 PERM\r", sv_client )
    expect( "rcon sv !mute CL 12 PERM\r", sv_client )
    expect( "rcon sv !mute CL 12 PERM\r", sv_client )
    expect( "rcon sv !mute CL 12 PERM\r", sv_client )
    expect( /MUTE PARTIAL MATCH/, sv_client )
    expect( /MUTE PARTIAL MATCH/, sv_client )
    expect( %{MUTE RULE: cpe-.*hawaii.res.rr.com,name!=dr\\.death\\(dxm\\) REASON: "damien_the_dest#{reason_ann} -mute 0"\r}, sv_client )
#   expect( "rcon sv !mute CL 12 PERM\r", sv_client )
    expect( /TEMP-BANNING MUTE AVOIDER.*67.49.159.95/, sv_client )
    expect( /rcon sv !ban IP 67.49.159.95 .*BAN_FOR_MUTE_AVOIDANCE/, sv_client )
    expect( "rcon kick 12\r", sv_client )
    expect( /rcon sv !ban IP 67.49.159.95 MSG .*muted_playername_must_not_contain_colon.* TIME \d+/, sv_client )
    expect( "rcon kick 15\r", sv_client )
    expect( /rcon sv !ban IP 67.49.159.95 MSG .*muted_playername_must_not_contain_colon.* TIME \d+/, sv_client )
    expect( "rcon kick 15\r", sv_client )
    expect( %{MUTE RULE: cpe-.*hawaii.res.rr.com,name!=dr\\.death\\(dxm\\) ("damien_the_dest#{reason_ann} -mute 0") removed.\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end

  def test_stifle
    wf, sv_client = @wf, @sv_client

    stifle_interval = "60"
    wf.cmd_set("default/stifle", stifle_interval)

    tstamp = wf.gen_ban_timestamp
    reason_ann = "__quadz__#{tstamp}"
    sendstr( 
	     %{12:34:00 quadz: wf stifle cpe-.*hawaii.res.rr.com damien the dest\r\n} +
	     %{12:34:00 CONNECT:     [12] "l33t_]<w4k3r_d00d"      67.49.159.95:60768 (aka: pwsnskle, , Damien The Dest, I.Crash.Servers)\r\n} +
	     %{12:34:00 ENTER_GAME:  [12] "l33t_]<w4k3r_d00d"      67.49.159.95:60768\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: spam, spam, spam, eggs, and spam            [12|67.49.159.95]\r\n} +
	     %{12:34:01 * l33t_]<w4k3r_d00d: spam, spam, spam, eggs, and spam            [12|67.49.159.95]\r\n} +
	     %{12:34:09 quadz: wf mute\r\n} +
	     %{12:34:09 quadz: wf unmute cpe-.*hawaii.res.rr.com\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{"default/stifle" => 60\r}, sv_client )
    expect( "Mute added.\r", sv_client )
    expect( %{rcon sv !mute CL 12 60\r}, sv_client )
    expect( %{rcon sv !mute CL 12 60\r}, sv_client )
    expect( %{MUTE RULE: cpe-.*hawaii.res.rr.com REASON: "damien_the_dest#{reason_ann} -mute 60"\r}, sv_client )
    expect( %{MUTE RULE: cpe-.*hawaii.res.rr.com ("damien_the_dest#{reason_ann} -mute 60") removed.\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end

  def test_per_map_dmflags
    wf, sv_client = @wf, @sv_client

    defflags_str = "+fd -pu"
    mapflags_str = "+pu +qd"
    
    sendstr( 
	     %{12:34:00 quadz: wf defflags #{defflags_str}\r\n} +
	     %{12:34:00 quadz: wf set maps/q2dm1/dmflags #{mapflags_str}\r\n} +
	     %{12:34:00 quadz: wf nextmap q2dm1(+fd +pu)\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{defflags => #{defflags_str}\r}, sv_client )
    expect( %{"maps/q2dm1/dmflags" => #{mapflags_str}\r}, sv_client )
    expect( %{nextmap => q2dm1(+fd +pu)\r}, sv_client )
    expect( DMFLAGS_CMD_STR + %{#{defflags_str} #{mapflags_str} +fd +pu\r}, sv_client )
#     expect( "rcon set tune_spawn_quad weapon_railgun\r", sv_client )
#     expect( "rcon set tune_spawn_invulnerability item_pack\r", sv_client )
    expect( FASTMAP_CMD_STR + %{q2dm1\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end

  def test_per_map_fraglimit_timelimit
    wf, sv_client = @wf, @sv_client

    sendstr( 
	     %{12:34:00 quadz: wf nextmap q2dm1 q2dm2 q2dm3\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:00 quadz: wf set default/fraglimit 30\r\n} +
	     %{12:34:00 quadz: wf set default/timelimit 20\r\n} +
	     %{12:34:00 quadz: wf set maps/q2dm3/fraglimit 50\r\n} +
	     %{12:34:00 quadz: wf set maps/q2dm3/timelimit 15\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     %{12:34:02 * Fraglimit hit.\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{nextmap => q2dm1 q2dm2 q2dm3\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{q2dm1\r}, sv_client )
    expect( %{"default/fraglimit" => 30\r}, sv_client )
    expect( %{"default/timelimit" => 20\r}, sv_client )
    expect( %{"maps/q2dm3/fraglimit" => 50\r}, sv_client )
    expect( %{"maps/q2dm3/timelimit" => 15\r}, sv_client )
    expect( %{rcon fraglimit 30\r}, sv_client )
    expect( %{rcon timelimit 20\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{q2dm2\r}, sv_client )
    expect( %{rcon fraglimit 50\r}, sv_client )
    expect( %{rcon timelimit 15\r}, sv_client )
    expect( FASTMAP_CMD_STR + %{q2dm3\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end

  def test_bindspam_triggers
    wf, sv_client = @wf, @sv_client

    sendstr( %{12:34:00 quadz: wf set bindspam_chatban/enable yes\r\n} +
	     %{12:34:00 quadz: wf set bindspam_chatban/min_text_length 10\r\n} +
	     %{12:34:00 quadz: wf set bindspam_chatban/short_text_mute_enable yes\r\n} +
	     %{12:34:00 quadz: wf set bindspam_chatban/short_text_mute_secs 120\r\n} +
	     %{12:34:00 quadz: wf set bindspam_chatban/trigger_at_num 3\r\n} +
	     %{12:34:00 quadz: wf set bindspam_chatban/trigger_memory_seconds 60\r\n} +
	     %{12:34:00 quadz: wf set bindspam_chatban/trigger_window_seconds 10\r\n} +
	     %{12:34:00 quadz: wf set bindspam_chatban/trigger_window_seconds_short 5\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    8.times{ expect( /bindspam_chatban/, sv_client ) }
    expect( %{cyas!\r}, sv_client )

    sendstr( %{12:34:01 * some spammer: foo            [12|123.45.67.89]\r\n} +
	     %{12:34:01 * some spammer: foo            [12|123.45.67.89]\r\n} +
	     %<12:34:01 * some huanker: gaga gaga goo goo gagagagaga !*[]{}()?+$^ass           [6|123.45.67.89]\r\n> +
	     %{12:34:01 * some spammer: foo            [12|123.45.67.89]\r\n} +
	     %<12:34:01 * some huanker: gaga gaga goo goo gagagagaga !*[]{}()?+$^ass           [6|123.45.67.89]\r\n> +
	     %<12:34:01 * some huanker: gaga gaga goo goo gagagagaga !*[]{}()?+$^ass           [6|123.45.67.89]\r\n> +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{rcon sv !mute CL 12 120\r}, sv_client )
    expect( %{rcon sv !chatbanning_enable yes\r}, sv_client )
    expect( %{rcon sv !chatban RE gaga.gaga.goo.goo.gagagagaga.!...........ass\r}, sv_client )
    expect( %{cyas!\r}, sv_client )

    $wf_cur_time += (5+1)  # pass up the short window time
    sendstr( %{12:34:01 * some spammer: foo            [12|123.45.67.89]\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{cyas!\r}, sv_client )
  end

  def test_goto
    wf, sv_client = @wf, @sv_client

    sendstr( %{12:34:01 * fubar: goto mutant            [12|123.45.67.89]\r\n} +
             %{12:34:02 * shazam: goto coop ggs dudez            [13|123.45.67.89]\r\n} +
             %{12:34:02 * (t*$+|ng): goto vanilla            [14|123.45.67.89]\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{rcon say teleporting fubar >> ::MUTANT:: << custom maps zone !\r}, sv_client )
    expect( %{rcon sv !stuff CL 12 connect 74.54.186.226\r}, sv_client )
    expect( %{rcon say teleporting shazam >> ::COOP:: << co-op strogg-infested mayhem !\r}, sv_client )
    expect( %{rcon sv !stuff CL 13 connect 74.54.186.236:27932\r}, sv_client )
    expect( %{rcon say teleporting t*++|ng >> ::VANILLA:: << single player maps !\r}, sv_client )
    expect( %{rcon sv !stuff CL 14 connect 74.54.186.226:27912\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end

  def test_goto_name_change_exploit
    wf, sv_client = @wf, @sv_client

    sendstr( %{12:34:01 * fubar: goto mutant            [12|123.45.67.89]\r\n} +
             %{12:34:01 * douch1l1l1l1ll1 changed name to bizkit\r\n} +
             %{12:34:01 * bizkit: goto hell            [11|99.88.77.66]\r\n} +
             %{12:34:02 * bizkit changed name to bi$ki.\r\n} +
             %{12:34:01 * bi$ki.: goto hell            [11|99.88.77.66]\r\n} +
             %{12:34:02 * bizkit changed name to douch1l1l1l1ll1\r\n} +
             %{12:34:02 * shazam: goto coop            [3|11.22.33.44]\r\n} +
	     WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{rcon say teleporting fubar >> ::MUTANT:: << custom maps zone !\r}, sv_client )
    expect( %{rcon sv !stuff CL 12 connect 74.54.186.226\r}, sv_client )
    expect( %{rcon say Sorry, GOTO is offline for a few moments. Try again in 6 seconds...\r}, sv_client )
    expect( %{rcon say Sorry, GOTO is offline for a few moments. Try again in 6 seconds...\r}, sv_client )
    expect( %{rcon say teleporting shazam >> ::COOP:: << co-op strogg-infested mayhem !\r}, sv_client )
    expect( %{rcon sv !stuff CL 3 connect 74.54.186.236:27932\r}, sv_client )
    expect( %{cyas!\r}, sv_client )

    $wf_cur_time += (6-1)  # just before window expires
    sendstr( %{12:34:01 * bi$ki.: goto hell            [11|99.88.77.66]\r\n} +
             WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{rcon say Sorry, GOTO is offline for a few moments. Try again in 2 seconds...\r}, sv_client )
    expect( %{cyas!\r}, sv_client )

    $wf_cur_time += (1)  # exactly at window expire
    sendstr( %{12:34:01 * bi$ki.: goto coop            [11|99.88.77.66]\r\n} +
             WF_LOGOUT_STR, sv_client)
    wf.run
    expect( %{rcon say teleporting bi+ki. >> ::COOP:: << co-op strogg-infested mayhem !\r}, sv_client )
    expect( %{rcon sv !stuff CL 11 connect 74.54.186.236:27932\r}, sv_client )
    expect( %{cyas!\r}, sv_client )
  end

end # TestWallflyFunctional


