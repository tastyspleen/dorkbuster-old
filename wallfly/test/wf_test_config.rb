
require 'wallfly' 
require 'test/unit'

Thread.abort_on_exception = true
$TESTING = true  # currently this just disables some sleep() timing to make tests go faster

$wf_cur_time = Time.now
class Wallfly
  def wait(secs) end
  def cur_time; $wf_cur_time end
  def exec_proxyban_cmd(ip, sv_nick, clnum)
    $stderr.puts "would exec proxyban: #{[ip, sv_nick, clnum].inspect}"
  end
  def self.load_servers_config
    begin
      old_verbose = $VERBOSE
      $VERBOSE = nil
      eval __servers_config_test_data__
    ensure
      $VERBOSE = old_verbose
    end
  end
  def self.invoke_server_status
    <<ENDTEXT
___________________________________________________________
__EMPTY_SERVERS____________________________________________
[TASTY ] COOP
___________________________________________________________
__ACTIVE_SERVERS___________________________________________
[TASTY ] VANILLA lab      ( 2/32) SILLYBILLY-CRU, Baron Cumholen
[TASTY ] MUTANT  marics35 ( 1/16) fubar
ENDTEXT
  end
  def self.__servers_config_test_data__
    <<ENDCODE
require 'autostruct'

module ServerInfo
  Z_TS    = "TASTY"
  Z_IND   = "INDEP."

  TASTYSPLEEN_NET       = "74.54.186.226"
  TX_TASTYSPLEEN_NET    = "74.54.186.236"

  class << self
    attr_reader :server_list, :server_info, :server_aliases
  end

  def self.mk_sv_struct(nick, zone, gameip, gameport, description, quiet_please=false, allow_invites=true)
    sv = AutoStruct.new
    sv.nick = nick
    sv.zone = zone
    sv.gameip = gameip
    sv.gameport = gameport
    sv.desc = description
    sv.quiet_please = quiet_please
    sv.allow_invites = allow_invites
    sv
  end

  @server_list = [
    mk_sv_struct("mutant",      Z_TS, TASTYSPLEEN_NET,      27910, "custom maps zone"),
    mk_sv_struct("vanilla",     Z_TS, TASTYSPLEEN_NET,      27912, "single player maps"),
    mk_sv_struct("coop",        Z_TS, TX_TASTYSPLEEN_NET,   27932, "co-op strogg-infested mayhem"),
    mk_sv_struct("hell",        Z_TS, TASTYSPLEEN_NET,      27666, "Abandon Hope, All Ye Who Enter Here"),
  ]

  @server_info = {}
  @server_list.each {|sv| @server_info[sv.nick] = sv}

  @server_aliases = {
    "strogg" => "coop",
  } 
end
ENDCODE
  end
end

module WallflyTestConfig
  TEST_HOST = 'localhost'
  TEST_PORT = 12345

  DB_USERNAME = "wallfly"
  DB_PASSWORD = "blahblahblah"

  STUPID_PASSWD_PROMPT = %{login:\b \b\b \b\b \b\b \b\b \b\b \bpasswd:\b \b\b \b\b \b\b \b\b \b\b \b\b \bpasswd:passwd:\b \b\b \b\b \b\b \b\b \b\b \b\b \b}
  STUPID_WELCOME_SEQUENCE = %{\b \b\b \b\b \b\b \b\b \b\b \b\b \b#{DB_USERNAME}@xquake/datower/15>\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\b \b\r\n\r\n} +
                            %{Welcome, #{DB_USERNAME}.\r\n\r\n}
  MAIN_PROMPT = %{#{DB_USERNAME}@xquake/datower/15>}

  # TODO: expect & sendstr are appearing in a lot of test code
  EXPECT_TIMEOUT_SECS = 5
  
  def expect(str, sock)
    line = ""
    timeout(EXPECT_TIMEOUT_SECS) {
      while ch = sock.recv(1)
        line << ch
        break if ch == "\r"
      end
    }
    line.sub!(/\A>log /, "")
    if str.kind_of?(Regexp)
      assert_match( str, line, caller[0] )
    else
      assert_equal( str, line, caller[0] )
    end
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
#  1000.times { Thread.pass }
    dbc.get_parse_new_data
#  $stderr.puts "\nsend_and_parse: sent(#{str}) dbc-parsebuf(#{dbc.parsebuf})"
  end
end

