
require 'socket'
require 'thread'
require 'fastthread'
require 'dbcore/buffered-io'
require 'dbcore/global-signal'
require 'dbcore/ansi'
require 'dbcore/obj-encode'


class String
  def set_ch_at(idx, ch)
    raise IndexError if idx < 0
    if idx >= self.size
      self << (" " * (idx - self.size + 1))
    end
    self[idx] = ch
    self
  end
end


class ANSIParse
  attr_accessor :preserve_color_codes

  def initialize
    @preserve_color_codes = false
    reset
  end

  def reset(new_parseout_contents="")
    @parseout = new_parseout_contents
    @state = nil
    @idx = @parseout.length
  end

  def accept_ch(ch)
    case @state
    when nil
      if ch == ?\b
        @idx = [0, @idx - 1].max
        ch = nil
      else
        if ch == ?\e
          @esc_idx = @idx
          @state = :esc_want_bracket
        end
      end
    when :esc_want_bracket
      if ch == ?[
        @state = :bracket_want_endseq
      else
        @state = nil
      end
    when :bracket_want_endseq
      if ch.between?(?A, ?Z) || ch.between?(?a, ?z)
        is_color_code = (ch == ?m)
        del_seq = !is_color_code  ||  (is_color_code  &&  ! @preserve_color_codes)
        if del_seq
          @idx = @esc_idx
          ch = nil
        end
        @state = nil
      elsif !(ch == ?; || ch.between?(?0, ?9))
        @state = nil
      end
    end

    if ch
      @parseout.set_ch_at(@idx, ch)
      @idx += 1
    end
  end

  def accept(str)
# puts "ANSIParse.accept: #{str.inspect}"
# puts "ANSIParse before: #{self.inspect}"
    str.each_byte {|ch| accept_ch(ch)}
# puts "ANSIParse after : #{self.inspect}"
  end

  def parseout
    @parseout[0...@idx]
  end

  def parsebuf_raw   # for test code
    @parseout
  end
end



class DBLine
  include ObjEncodePrintable

  KIND_UNKNOWN = :unknown
  KIND_FRAGLIMIT_HIT = :fraglimit
  KIND_TIMELIMIT_HIT = :timelimit
  KIND_WALLFLY_CLIENT = :wallfly
  KIND_DB_USER = :user
  KIND_DB_USER_PM = :user_pm
  KIND_CONNECT = :connect
  KIND_DISCONNECT = :disconnect
  KIND_ENTER_GAME = :entergame
  KIND_MAP_CHANGE = :mapchange
  KIND_NAME_CHANGE = :namechange
  KIND_ENCODED_OBJ = :encobj

  attr_reader :raw_line, :kind, :time, :speaker, :cmd
  attr_reader :obj, :obj_label

  def initialize(line_str)
    @raw_line = line_str
    parse(line_str)
  end
  
  def is_map_over?
    @kind == KIND_FRAGLIMIT_HIT || @kind == KIND_TIMELIMIT_HIT
  end
  
  def is_db_user?
    @kind == KIND_DB_USER
  end

  def is_db_user_pm?
    @kind == KIND_DB_USER_PM
  end

  def is_map_change?
    @kind == KIND_MAP_CHANGE
  end

  def is_name_change?
    @kind == KIND_NAME_CHANGE
  end

  def is_player_chat?
    @kind == KIND_WALLFLY_CLIENT
  end

  def is_connect?
    @kind == KIND_CONNECT
  end

  def is_disconnect?
    @kind == KIND_DISCONNECT
  end
  
  def is_enter_game?
    @kind == KIND_ENTER_GAME
  end

  def is_obj?
    @kind == KIND_ENCODED_OBJ
  end
  
  protected
  
  def parse(line)
# $stderr.puts "dbline.parse: #{line.inspect}"
    line = ANSI.strip(line)
    if line =~ /\A(\d\d:\d\d:\d\d)\s+(?:(\w+):|(\*))\s+(.*)\z/
      @time = $1
      @speaker = $2.to_s + $3.to_s
      @cmd = $4
      @obj = nil
      @obj_label = ""
      case @speaker
        when "*"
          case @cmd
            # WARNING: without the \z, Fraglimit hit will be fooled by
            # 2=Fraglimit hit. changed name to blah
            when /\A(Fraglimit(?: of \d+)? hit|JailPoint Limit Hit)\.\z/ then @kind = KIND_FRAGLIMIT_HIT
            when /\ATimelimit(?: of \d+)? hit\.\z/ then @kind = KIND_TIMELIMIT_HIT
            else @kind = KIND_WALLFLY_CLIENT
          end
        when "CONNECT" then @kind = KIND_CONNECT
        when "DISCONNECT" then @kind = KIND_DISCONNECT
        when "ENTER_GAME" then @kind = KIND_ENTER_GAME
        when "MAP_CHANGE" then @kind = KIND_MAP_CHANGE
        when "NAME_CHANGE" then @kind = KIND_NAME_CHANGE
        else @kind = KIND_DB_USER
      end
    elsif line =~ /\A\((\w+)\sto\s\w+\):\s*(.*)\z/
      @kind = KIND_DB_USER_PM
      @time = ""
      @speaker = $1
      @cmd = $2
      @obj = nil
      @obj_label = ""
    elsif result = obj_decode_with_label(line)
      @kind = KIND_ENCODED_OBJ
      @time = @speaker = @cmd = ""
      @obj_label, @obj = *result
    else
      @kind = KIND_UNKNOWN
      @time = ""
      @speaker = ""
      @cmd = ""
      @obj = nil
      @obj_label = ""
    end
    # NOTE: a bit of a kludge... destroy dollar signs in any player/speaker name
    # It is considered too dangerous to leave them be.
    # Players are changing their names to "$rcon_password", leading to:
    # 02:33:01 * test$rcon_password: goto desktop
    # 02:33:01 HAL: rcon say teleporting test$rcon_password >> ::DESKTOP:: << Let's rearrange some icons
    # (Fortunately dorkbuster already sanitizes $rcon_password in its rcon
    # command strings, but still...)
    @speaker.tr!("$",".")
  end
  
end


class DorkBusterClient
  attr_reader :username

  def initialize(sock, username, password, global_signal=GlobalSignal.new)
    @username = username
    @password = password
  # @data_ready_mutex = Mutex.new
    @data_ready_signal = global_signal
    @dbio = BufferedIO.new(sock, @data_ready_signal)
    @ansi = ANSIParse.new 
  end

  def preserve_color_codes=(flag)
    @ansi.preserve_color_codes = flag
  end

  def close
    @dbio.close
  end

  def eof
    @dbio.eof
  end

  def login
# puts " log(A) "
    match = wait_resp("login:")
# puts " log(A2) "
    reset_parsebuf(match.post_match)
# puts " log(B) match(#{match.pre_match.inspect})(#{match.to_s.inspect})(#{match.post_match.inspect}) "
    speak(@username)
# puts " log(C) "
    match = wait_resp("passwd:")
    reset_parsebuf(match.post_match)
# puts " log(D) match(#{match.pre_match.inspect})(#{match.to_s.inspect})(#{match.post_match.inspect}) "
    speak(@password)
   # wait_re(/Welcome|bad username/)
# puts " log(E) "
    match = wait_resp("Welcome")
    reset_parsebuf(match.to_s + match.post_match)
# puts " log(F) match(#{match.pre_match.inspect})(#{match.to_s.inspect})(#{match.post_match.inspect}) "
    match = wait_prompt
    reset_parsebuf(match.post_match)
# puts " log(G) match(#{match.pre_match.inspect})(#{match.to_s.inspect})(#{match.post_match.inspect}) "
  end

  def find_resp(resp)
    parsebuf.match(resp)
  end

  def wait_resp(resp)
    wait_cond { find_resp(resp) }
  end

  def find_prompt
    # MAIN_PROMPT = %{#{DB_USERNAME}@xquake/datower/15>}
# puts "[find_prompt, buf(#{@ansi.parseout.inspect})]"
    parsebuf.match(%r{#{@username}@([^/]+)/([^/]*)/(\d+)>})
  end

  def wait_prompt
    wait_cond { find_prompt }
  end

  def wait_cond(&block)
    x = nil
    loop do
      get_parse_new_data
      break if x = yield
# puts "[wait_cond, buf(#{@ansi.parseout.inspect})]"
      wait_new_data
    end
    x
  end

  def speak(str)
    @dbio.send_nonblock(str + "\r")
  end

  def parsebuf
    @ansi.parseout
  end

  def reset_parsebuf(str="")
# puts "[reset_parsebuf(#{str.inspect})]"
    @ansi.reset(str)
  end

  def next_parsed_line
    # treat a lone \r (i.e. a \r not followed by a \n)
    # as a throwaway
    if parsebuf =~ /\A[^\r]*\r+([^\n\r])/
      reset_parsebuf($1 + $')
    end
    
    # see if we can split a complete (terminated) line
    # out of parsebuf from start of buffer (split()...)
    # if we get one, return a DBLine, else nil
    line, remainder = parsebuf.split(/\r\n/, 2)
    dbline = nil
    if remainder
      reset_parsebuf(remainder)
      dbline = DBLine.new(line)
    end
    dbline
  end

  RECV_TIMEOUT = 5.0
  
  def wait_new_data(timeout_secs=RECV_TIMEOUT)
    begin
      @dbio.wait_recv_ready(timeout_secs)
    rescue Timeout::Error
    end

    # @data_ready_mutex.synchronize {
    #   while ! @dbio.recv_ready?
    #     @data_ready_signal.wait(@data_ready_mutex)
    #   end
    # }
  end

  def get_parse_new_data
    @ansi.accept(@dbio.recv_nonblock)
  end
  
end


if $0 == __FILE__
# if ARGV[0] == "-test"
#  ARGV.clear  # so test/unit doesn't freak
  require 'test/unit'

  Thread.abort_on_exception = true

  TEST_HOST = 'localhost'
  TEST_PORT = 12345

  DB_USERNAME = "wallfly"
  DB_PASSWORD = "blahblahblah"

  STUPID_PASSWD_PROMPT = %{login:\b \b\b \b\b \b\b \b\b \b\b \bpasswd:\b \b\b \b\b \b\b \b\b \b\b \b\b \bpasswd:passwd:\b \b\b \b\b \b\b \b\b \b\b \b\b \b}
  STUPID_WELCOME_SEQUENCE = %{\b \b\b \b\b \b\b \b\b \b\b \b\b \b#{DB_USERNAME}@xquake/datower/15>\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\r\n\r\n} +
                            %{Welcome, #{DB_USERNAME}.\r\n\r\n}
  MAIN_PROMPT = %{#{DB_USERNAME}@xquake/datower/15>}

  # TODO: expect & sendstr are appearing in a lot of test code
  def expect(str, sock)
    got = ""
    got << sock.recv(1) while got.length < str.length
    assert_equal( str, got, caller[0] )
  end

  def sendstr(str, sock)
    while str.length > 0
      sent = sock.send(str, 0)
      str = str[sent..-1]
    end
  end

  def send_and_parse(str, sock, dbc)
    dbc.get_parse_new_data
    sendstr(str, sock)
    dbc.wait_new_data
    dbc.get_parse_new_data
#  $stderr.puts "\nsend_and_parse: sent(#{str}) dbc-parsebuf(#{dbc.parsebuf})"
  end

  class TestANSIParse < Test::Unit::TestCase
  
    STUPID_PROMPT_STR = %{login:\b \b\b \b\b \b\b \b\b \b\b \bpasswd:\b \b\b \b\b \b\b \b\b \b\b \b\b \bpasswd:passwd:\b \b\b \b\b \b\b \b\b \b\b \b\b \b}

    def test_set_ch_at
      x = "abc"
      assert_raises(IndexError) { x.set_ch_at(-1, ?z) }
      assert_equal( "zbc", x = x.set_ch_at(0, ?z) )
      assert_equal( "zyc", x = x.set_ch_at(1, ?y) )
      assert_equal( "zyx", x = x.set_ch_at(2, ?x) )
      assert_equal( "zyxw", x = x.set_ch_at(3, ?w) )
      assert_equal( "zyxw  v", x = x.set_ch_at(6, ?v) )
    end

    def test_backspace
      ap = ANSIParse.new
      assert_equal( "", ap.parsebuf_raw )
      assert_equal( "", ap.parseout )
      ap.accept "a"
      assert_equal( "a", ap.parsebuf_raw )
      assert_equal( "a", ap.parseout )
      ap.accept "\b"
      assert_equal( "a", ap.parsebuf_raw )
      assert_equal( "", ap.parseout )
      ap.accept "z"
      assert_equal( "z", ap.parsebuf_raw )
      assert_equal( "z", ap.parseout )

      ap.accept "012345\b\b\b9\b\b\b8"
      assert_equal( "z082945", ap.parsebuf_raw )
      assert_equal( "z08", ap.parseout )

      ap.reset
      assert_equal( "", ap.parsebuf_raw )
      assert_equal( "", ap.parseout )
      ap.accept STUPID_PROMPT_STR
      assert_equal( "passwd:       ", ap.parsebuf_raw )
      assert_equal( "passwd:", ap.parseout )
    end

    def test_elide_ansi_codes
      ap = ANSIParse.new
      ap.accept "hi \e[12;34mthere\e[m dude"
      assert_equal( "hi there dude", ap.parsebuf_raw )

      # test negative-parse cases where escape not gobbled      
      ap.reset; ap.accept "a\e"; assert_equal( "a\e", ap.parsebuf_raw )
      ap.reset; ap.accept "a\eb"; assert_equal( "a\eb", ap.parsebuf_raw )
      ap.reset; ap.accept "a\e["; assert_equal( "a\e[", ap.parsebuf_raw )
      ap.reset; ap.accept "a\e[b"; assert_equal( "a", ap.parseout )
      ap.reset; ap.accept "a\e[2;b"; assert_equal( "a", ap.parseout )
      ap.reset; ap.accept "a\e[!2;b"; assert_equal( "a\e[!2;b", ap.parseout )
      ap.reset; ap.accept "a\e[2;!b"; assert_equal( "a\e[2;!b", ap.parseout )
    end

    def test_preserve_color_codes
      ap = ANSIParse.new
      ap.preserve_color_codes = true
      ap.accept "hi \e[12;34mthere\e[m dude\b\b\b\b\e[Kbrah"
      assert_equal( "hi \e[12;34mthere\e[m brah", ap.parsebuf_raw )
    end

    def test_cr_esc_bracket_k_bug
      ap = ANSIParse.new
      ap.accept "foo"
      ap.accept ""
      ap.accept "\r\e[K"
      assert_equal( "foo\r", ap.parseout )
    end
  end


  class TestDBLine < Test::Unit::TestCase

    include ObjEncodePrintable

    def test_parse
      dbline = DBLine.new("")
      assert_equal( DBLine::KIND_UNKNOWN, dbline.kind )
      assert( ! dbline.is_map_over? )
      assert( ! dbline.is_db_user? )
    
      dbline = DBLine.new(%{12:34:56 * Fraglimit hit.})
      assert_equal( DBLine::KIND_FRAGLIMIT_HIT, dbline.kind )
      assert_equal( "12:34:56", dbline.time )
      assert_equal( "*", dbline.speaker )
      assert_equal( "Fraglimit hit.", dbline.cmd )
      assert( dbline.is_map_over? )      
      assert( ! dbline.is_db_user? )

      dbline = DBLine.new(%{12:34:56 * Timelimit hit.})
      assert_equal( DBLine::KIND_TIMELIMIT_HIT, dbline.kind )
      assert_equal( "12:34:56", dbline.time )
      assert_equal( "*", dbline.speaker )
      assert_equal( "Timelimit hit.", dbline.cmd )
      assert( dbline.is_map_over? )      
      assert( ! dbline.is_db_user? )

      dbline = DBLine.new(%{12:34:56 * super bozo: this map sux})
      assert_equal( DBLine::KIND_WALLFLY_CLIENT, dbline.kind )
      assert_equal( "12:34:56", dbline.time )
      assert_equal( "*", dbline.speaker )
      assert_equal( "super bozo: this map sux", dbline.cmd )
      assert( ! dbline.is_db_user? )

      dbline = DBLine.new(%{12:34:56 quest: off with their heads!})
      assert_equal( DBLine::KIND_DB_USER, dbline.kind )
      assert_equal( "12:34:56", dbline.time )
      assert_equal( "quest", dbline.speaker )
      assert_equal( "off with their heads!", dbline.cmd )
      assert( dbline.is_db_user? )

      dbline = DBLine.new(%{(quadz to applejacks): foo bar})
      assert_equal( DBLine::KIND_DB_USER_PM, dbline.kind )
      assert_equal( "", dbline.time )
      assert_equal( "quadz", dbline.speaker )
      assert_equal( "foo bar", dbline.cmd )
      assert( dbline.is_db_user_pm? )

      dbline = DBLine.new(%{12:34:56 CONNECT:     [7]  "Gambit"      123.45.67.89:27901 (aka: blah, dork azz, spink nut)})
      assert_equal( DBLine::KIND_CONNECT, dbline.kind )
      assert_equal( "12:34:56", dbline.time )
      assert_equal( "CONNECT", dbline.speaker )

      dbline = DBLine.new(%{12:34:56 ENTER_GAME:  [7]  "Gambit"      123.45.67.89:27901})
      assert_equal( DBLine::KIND_ENTER_GAME, dbline.kind )
      assert_equal( "12:34:56", dbline.time )
      assert_equal( "ENTER_GAME", dbline.speaker )

      dbline = DBLine.new(%{12:34:56 DISCONNECT:  [7]  "Gambit"      123.45.67.89:27901 score:9 ping:95})
      assert_equal( DBLine::KIND_DISCONNECT, dbline.kind )
      assert_equal( "12:34:56", dbline.time )
      assert_equal( "DISCONNECT", dbline.speaker )

      dbline = DBLine.new(%{12:34:56 MAP_CHANGE:  base3 (was:base2)})
      assert_equal( DBLine::KIND_MAP_CHANGE, dbline.kind )
      assert_equal( "12:34:56", dbline.time )
      assert_equal( "MAP_CHANGE", dbline.speaker )

      dbline = DBLine.new(%{12:34:56 NAME_CHANGE: [11] "rat"     123.45.67.89:27901 was: MaryBottins})
      assert_equal( DBLine::KIND_NAME_CHANGE, dbline.kind )
      assert_equal( "12:34:56", dbline.time )
      assert_equal( "NAME_CHANGE", dbline.speaker )

      # test parse with color codes
      dbline = DBLine.new(%{12:34:56 \e[6m* super bozo: this map sux})
      assert_equal( DBLine::KIND_WALLFLY_CLIENT, dbline.kind )
      assert_equal( "12:34:56", dbline.time )
      assert_equal( "*", dbline.speaker )
      assert_equal( "super bozo: this map sux", dbline.cmd )
      assert( ! dbline.is_db_user? )

      encoded_status_obj = 
        "%04%08%22%02%96%01tastyspleen.net%3A%3Avanilla2%3A+map%3Awaste3+%2F+dmflags" +
        "%3A16918+%2F+fraglimit%3A30+%2F+timelimit%3A20+%2F+cheats%3A0%0Anum+score+ping+name" +
        "++++++++++++lastmsg+ip+++++++++++++++port+akas%0A---+-----+----+---------------+-------" +
        "+---------------------+-----%0A%1B%5B33m++0%1B%5B0m+++++0++++2+%1B%5B33mWallFly%5BBZZZ%5D" +
        "++%1B%5B0m++++++78+70.87.101.66++++%1B%5B33m50349%1B%5B0m+%0A%1B%5B33m++1%1B%5B0m+++++0++180" +
        "+%1B%5B33mI++++++++++++++%1B%5B0m++++++13+213.199.198.226+%1B%5B33m+1660%1B%5B0m+%0A"
      status_obj = obj_decode_from_printable(encoded_status_obj)
      encoded_status_line = "OBJ/STATUS: #{encoded_status_obj}"
      dbline = DBLine.new(encoded_status_line)
      assert_equal( DBLine::KIND_ENCODED_OBJ, dbline.kind )
      assert( dbline.is_obj? )
      assert_equal( "", dbline.time )
      assert_equal( "", dbline.speaker )
      assert_equal( "", dbline.cmd )
      assert_equal( encoded_status_line, dbline.raw_line )
      assert_equal( "STATUS", dbline.obj_label )
      assert_equal( status_obj, dbline.obj )

      # try a messed up one
      dbline = DBLine.new("OBJ/STATUS: %04%08bogus")
      assert_equal( DBLine::KIND_ENCODED_OBJ, dbline.kind )
      assert( dbline.is_obj? )
      assert_equal( "", dbline.time )
      assert_equal( "", dbline.speaker )
      assert_equal( "", dbline.cmd )
      assert_equal( "EXCEPTION!STATUS", dbline.obj_label )
      assert( dbline.obj.kind_of?(Exception) )
    end

  end


  class TestDorkBusterClient < Test::Unit::TestCase

    def test_login
      mock_db_server = TCPServer.new(TEST_PORT)
      lo_client = TCPSocket.new(TEST_HOST, TEST_PORT)
      sv_client = mock_db_server.accept
 
      dbc = DorkBusterClient.new(lo_client, DB_USERNAME, DB_PASSWORD)
      assert_equal( DB_USERNAME, dbc.username )
      # test find_resp
      assert( ! dbc.find_resp("login:") )
      send_and_parse(%{Dork Buster RconServer v0.4.1\r\n\r\n}, sv_client, dbc)
      assert( ! dbc.find_resp("login:") )
      send_and_parse(%{login}, sv_client, dbc)
      assert( ! dbc.find_resp("login:") )
      send_and_parse(%{:}, sv_client, dbc)
      assert( dbc.find_resp("login:") )
      send_and_parse(%{blahblah\r\nblah\r\nblah}, sv_client, dbc)
      assert( dbc.find_resp("login:") )

      # test wait_resp
      dbc.reset_parsebuf
      th = Thread.new { dbc.wait_resp("login:") }
      1000.times { Thread.pass }
      sendstr(%{Dork Buster RconServer v0.4.1\r\n\r\n} +
              %{login:}, sv_client)
      th.join

      # test find_prompt
      dbc.reset_parsebuf
      assert( ! dbc.find_prompt )
      send_and_parse(MAIN_PROMPT[0..-2], sv_client, dbc)
      assert( ! dbc.find_prompt )
      send_and_parse(MAIN_PROMPT[-1..-1], sv_client, dbc)
      assert( dbc.find_prompt )

      # test wait_prompt
      dbc.reset_parsebuf
      th = Thread.new { dbc.wait_prompt }
      1000.times { Thread.pass }
      sendstr( "blahblhablha\r\n" + MAIN_PROMPT, sv_client )
      th.join

      # test next_parsed_line
      dbc.reset_parsebuf
      send_and_parse("abc", sv_client, dbc)
      assert( ! dbc.next_parsed_line )
      send_and_parse("\r\ndef\r\n\r\nghi\r\njkl", sv_client, dbc)
      dbline = dbc.next_parsed_line
      assert_equal( "abc", dbline.raw_line )
      dbline = dbc.next_parsed_line
      assert_equal( "def", dbline.raw_line )
      dbline = dbc.next_parsed_line
      assert_equal( "", dbline.raw_line )
      dbline = dbc.next_parsed_line
      assert_equal( "ghi", dbline.raw_line )
      assert( ! dbc.next_parsed_line )
      assert_equal( "jkl", dbc.parsebuf )      

      # test lone carriage return cancels line
      dbc.reset_parsebuf
      send_and_parse("abc>", sv_client, dbc)
      assert( ! dbc.next_parsed_line )
      send_and_parse("\r", sv_client, dbc)
      assert( ! dbc.next_parsed_line )
      send_and_parse("def", sv_client, dbc)
      assert( ! dbc.next_parsed_line )
      send_and_parse("\r\n", sv_client, dbc)
      dbline = dbc.next_parsed_line
      assert_equal( "def", dbline.raw_line )

      # test login
      dbc.reset_parsebuf
      th = Thread.new { dbc.login }
      sendstr( %{Dork Buster RconServer v0.4.1\r\n} +
               %{login:}, sv_client )
      expect( dbc.username + "\r", sv_client )
      sendstr( dbc.username, sv_client )  # we're echoing keys typed (maybe PERM_AI should have no echo)
      sendstr( STUPID_PASSWD_PROMPT, sv_client )
      expect( DB_PASSWORD + "\r", sv_client )
      sendstr( STUPID_WELCOME_SEQUENCE, sv_client )
      sendstr( MAIN_PROMPT, sv_client )
      # 1000.times { Thread.pass }
      th.join

      dbc.close
      sv_client.close
      mock_db_server.close
    end

  end

end



