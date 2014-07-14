
require 'socket'
require 'thread'
require 'fastthread'
require 'dbcore/buffered-io'
require 'dbcore/global-signal'
require 'dbcore/recursive-mutex'
require 'dbcore/term-keys'
require 'dbcore/ansi'


# Parses ANSI sequences for the purpose of
# maintaining the current cursor position
# and attributes, so that we don't have to
# query the remote terminal for this information.
class ANSIEmu

  attr_reader :term_rows, :term_cols, :cursor_row, :cursor_col, :attrs
  
  def initialize(rows, cols)
    @term_rows, @term_cols = rows, cols
    @rgn_start_row = 1
    @rgn_end_row = @term_rows
    @cursor_row, @cursor_col = 1, 1
    @cursor_row_save, @cursor_col_save = 1, 1
    @parse_state = [:root_parse]
    @attrs = []
    @numbers = []
    @deferred_wrap = false
  end

  def set_term_size(rows, cols)
    @term_rows = rows
    @term_cols = cols
  end
    
  def parse(str)
    str.each_byte {|char| accept(char) }
  end

  private

  def accept(char)
    send(@parse_state[-1], char)
  end

  def root_parse(char)
    case char
      when ?\e then @numbers = []; @parse_state << :parse_bracket
      when ?\b then handle_backspace
      when ?\n then handle_linefeed
      when ?\r then handle_cr
      else handle_plain_char(char)
    end
  end

  def parse_bracket(char)
    if char == ?[
      @parse_state[-1] = :parse_esc_seq
    else
      @parse_state.pop
      accept(char)
    end
  end

  def parse_esc_seq(char)
# $stderr.puts "pesc: " + char.chr
    esc_done = true
    case char
      when ?0..?9 then esc_done = false; begin_parse_number(char)
      when ?;     then esc_done = false; @numbers << nil unless @numbers[-1]
      when ?\e    then esc_done = false; @numbers = []
      when ?m     then handle_set_attrs
      when ?r     then handle_set_scroll
      when ?H     then handle_set_cursor_pos
      when ?s     then handle_save_cursor_pos
      when ?u     then handle_restore_cursor_pos
      when ?D     then handle_cursor_left
      when ?C     then handle_cursor_right
      when ?A     then handle_cursor_up
      when ?B     then handle_cursor_down
      when ?K     then handle_erase_line
      when ?J     then handle_erase_screen
    end
    @parse_state.pop if esc_done
  end

  def begin_parse_number(char)
    @numbers << char.chr
    @parse_state << :parse_number
  end

  def parse_number(char)
    if char.between?(?0, ?9)
      @numbers[-1] << char.chr
    else
      @parse_state.pop
      accept(char)
    end
  end

  def inc_row
    max_row = (@cursor_row <= @rgn_end_row)? @rgn_end_row : @term_rows
    @cursor_row = [@cursor_row + 1, max_row].min
  end

  def handle_plain_char(char)
# $stderr.print "hpc(#{@cursor_col}): #{char.chr.inspect}"
    if @cursor_col >= @term_cols
      if @deferred_wrap
        @cursor_col = 2
        inc_row
      else
        @deferred_wrap = true
      end
    else
      @cursor_col += 1
    end
# $stderr.puts " :(#{@cursor_col})"
  end

  def handle_linefeed
    @deferred_wrap = false
    inc_row
  end

  def handle_backspace
    @deferred_wrap = false
    @cursor_col -= 1 if @cursor_col > 1
  end

  def handle_cr
    @deferred_wrap = false
    @cursor_col = 1
  end

  def handle_set_attrs
    @numbers << ANSI::Reset if @numbers.empty?
    @numbers.each do |attr|
      if attr == ANSI::Reset
        @attrs = []
      elsif attr == ANSI::Bright
        @attrs << attr unless @attrs.include? ANSI::Bright
      elsif ANSI.attr_is_fgcolor? attr
        @attrs.delete_if {|a| ANSI.attr_is_fgcolor? a }
        @attrs << attr
      elsif ANSI.attr_is_bgcolor? attr
        @attrs.delete_if {|a| ANSI.attr_is_bgcolor? a }
        @attrs << attr
      end
    end
  end

  def handle_set_scroll
    @rgn_start_row = [[1, @numbers[0].to_i].max, @term_rows].min
    @rgn_end_row =   [[1, @numbers[1].to_i].max, @term_rows].min
  end

  def handle_set_cursor_pos
    @cursor_row = [[1, @numbers[0].to_i].max, @term_rows].min
    @cursor_col = [[1, @numbers[1].to_i].max, @term_cols].min
  end

  def handle_save_cursor_pos
    @cursor_row_save, @cursor_col_save = @cursor_row, @cursor_col
  end

  def handle_restore_cursor_pos
    @cursor_row, @cursor_col = @cursor_row_save, @cursor_col_save
  end
  
  def handle_cursor_left
    @deferred_wrap = false
    @cursor_col = [1, @cursor_col - [1, @numbers[0].to_i].max].max
  end
  
  def handle_cursor_right
    @deferred_wrap = false
    @cursor_col = [@cursor_col + [1, @numbers[0].to_i].max, @term_cols].min
  end
  
  def handle_cursor_up
    @deferred_wrap = false
    @cursor_row = [1, @cursor_row - [1, @numbers[0].to_i].max].max
  end
  
  def handle_cursor_down
    @deferred_wrap = false
    @cursor_row = [@cursor_row + [1, @numbers[0].to_i].max, @term_rows].min
  end
  
  def handle_erase_line
    # doesn't move cursor, nothing to do
  end

  def handle_erase_screen
    # full screen clear (2J) homes the cursor
    if @numbers[0].to_i == 2
      @cursor_row, @cursor_col = 1, 1
    end
  end
end





class ANSITermIO

  CURSOR_REPORT_TIMEOUT = 3.0

  def initialize(buffered_io)
    @io = buffered_io
    @serial_access_mutex = RecursiveMutex.new
    @expect_cursor_pos = false
    @parsing_esc_seq = false
    @cursor_row_latch = 1
    @cursor_col_latch = 1
    @recvbuf = ""
    @parsebuf = ""
    @last_parse_ch = -1
    @emu = ANSIEmu.new(25, 80)
  end

  def close
  end

  def eof
    @io.eof
  end

  def peeraddr
    @io.peeraddr
  end

  def wait_data_ready(timeout_secs=nil)  # raises: Timeout::Error
    rdy = @serial_access_mutex.synchronize { !@recvbuf.empty?  ||  @io.recv_ready? }
    @io.wait_recv_ready(timeout_secs) unless rdy
  end

  def send_nonblock(dat)
    send_with_emu(dat)
  end

  def recv_nonblock
    @serial_access_mutex.synchronize {
      process_available_data
      dat = @recvbuf
      @recvbuf = ""
      dat
    }
  end

  def flush(timeout_secs); @io.flush(timeout_secs) end
  
  def suspend_output(flag); @io.suspend_output(flag) end
  def output_suspend?; @io.output_suspend? end

  # Bypass the emulator and query the remote device
  def ask_cursor_pos  # raises: Timeout::Error
    @serial_access_mutex.synchronize {
      process_available_data
      @expect_cursor_pos = true
      @io.send_nonblock("\e[6n")
      while @expect_cursor_pos
        @io.wait_recv_ready(CURSOR_REPORT_TIMEOUT)
        process_available_data
      end
      [@cursor_row_latch, @cursor_col_latch]
    }
  end

  # Bypass the emulator and query the remote device
  def ask_term_size   # raises: Timeout::Error
    @serial_access_mutex.synchronize {
      save_cursor_pos
      set_cursor_pos(255, 255)
      begin
        rows, cols = ask_cursor_pos
      ensure
        restore_cursor_pos
      end
      @emu.set_term_size(rows, cols)
      [rows, cols]
    }
  end

  def term_rows; @emu.term_rows end
  def term_cols; @emu.term_cols end
  def cursor_row; @emu.cursor_row end
  def cursor_col; @emu.cursor_col end
  def attrs; @emu.attrs end

  def set_scroll_fullscreen; send_with_emu(ANSI.set_scroll_fullscreen) end
  
  def set_scroll_region(row_start, row_end)
    send_with_emu(ANSI.set_scroll_region(row_start, row_end))
  end

  def set_color(*color_attrs); send_with_emu(ANSI.color(*color_attrs)) end

  def set_cursor_pos(row, col); send_with_emu(ANSI.set_cursor_pos(row, col)) end

  def cursor_left(cnt=1);  send_with_emu(ANSI.cursor_left(cnt)) end
  def cursor_right(cnt=1); send_with_emu(ANSI.cursor_right(cnt)) end
  def cursor_up(cnt=1);    send_with_emu(ANSI.cursor_up(cnt)) end
  def cursor_down(cnt=1);  send_with_emu(ANSI.cursor_down(cnt)) end

  def backspace_rubout(cnt=1); send_with_emu(ANSI.backspace_rubout(cnt)) end

  def erase_line; send_with_emu(ANSI.erase_line) end
  def erase_eol; send_with_emu(ANSI.erase_eol) end
  def erase_screen; send_with_emu(ANSI.erase_screen) end

  def print(*args)
    str = args.join('')
    send_nonblock(str.gsub(/\n/, "\r\n"))
  end

  def puts(*args)
    print(args.join("\n") + "\n")
  end

  ############################################################################
  ############################################################################
  protected
  ############################################################################
  ############################################################################

  def send_with_emu(str)
    @emu.parse(str)
    @io.send_nonblock(str)
  end

  def save_cursor_pos; send_with_emu(ANSI.save_cursor_pos) end
  def restore_cursor_pos; send_with_emu(ANSI.restore_cursor_pos) end

  ############################################################################
	# Report          Query     Response
	# -----------------------------------------
	# Cursor position <ESC>[6n  <ESC>[{ROW};{COLUMN}R
	# Status report   <ESC>[c   <ESC>[?1;{STATUS}c      or 'what are you'
	# Status report   <ESC>[0c  <ESC>[?1;{STATUS}c
  ############################################################################
  
# UNPARSABLE_ESC_SEQ = /\A([^\e]|\e[^\[]|\e\[\D|\e\[\d+[^;\d]|\e\[\d+;\D|\e\[\d+;\d+[^R\d])/
  
  UNPARSABLE_ESC_SEQ = %r{ \A(?: [^\e] |
                                 \e[^\[] | 
                                 \e\[[^\dABCD] |
                                 \e\[\d+[^;~\d] |
                                 \e\[\d+;\D |
                                 \e\[\d+;\d+[^R\d]
                              )}x

  def process_available_data
    # CALLER SHOULD OWN MUTEX
    dat = prefilter_input( @io.recv_nonblock )

    while not dat.empty?
      if not @parsing_esc_seq
        # if escape char in input, split there, and start parsing
        if dat =~ /\e/
          @recvbuf << $`
          @parsebuf = ""
          dat = $& + $'
          @parsing_esc_seq = true
        else
          @recvbuf << dat
          dat = ""
        end
      end

      # $stderr.puts "dat(#{dat}) parsebuf(#{@parsebuf}) recvbuf(#{@recvbuf}) pes=#{@parsing_esc_seq}"

      if @parsing_esc_seq
        @parsebuf << dat
        dat = ""
        # if fails to parse, pass the unparsable data right along
        if @parsebuf =~ UNPARSABLE_ESC_SEQ
          @parsing_esc_seq = false
          @recvbuf << $` + $&
          dat = $'
          @parsebuf = ""
        elsif @parsebuf =~ /\A\e\[(\d+);(\d+)R/  # cursor report response
          @parsing_esc_seq = false
          @expect_cursor_pos = false
          dat = $'
          @parsebuf = ""
          @cursor_row_latch = $1.to_i
          @cursor_col_latch = $2.to_i
        elsif @parsebuf =~ /\A\e\[([ABCD])/  # arrow keys
          @parsing_esc_seq = false
          dat = $'
          @parsebuf = ""
          case $1
            when "A" then @recvbuf << TermKeys::KEY_UPARROW.chr
            when "B" then @recvbuf << TermKeys::KEY_DOWNARROW.chr
            when "C" then @recvbuf << TermKeys::KEY_RIGHTARROW.chr
            when "D" then @recvbuf << TermKeys::KEY_LEFTARROW.chr
          end
        elsif @parsebuf =~ /\A\e\[(\d+)~/  # home, end, function keys, etc.
          @parsing_esc_seq = false
          dat = $'
          @parsebuf = ""
          case $1
            when "1" then @recvbuf << TermKeys::KEY_INSERT.chr
            when "2" then @recvbuf << TermKeys::KEY_HOME.chr
            when "5" then @recvbuf << TermKeys::KEY_END.chr
            when "3" then @recvbuf << TermKeys::KEY_PGUP.chr
            when "6" then @recvbuf << TermKeys::KEY_PGDN.chr
            when "11" then @recvbuf << TermKeys::KEY_F1.chr
            when "12" then @recvbuf << TermKeys::KEY_F2.chr
            when "13" then @recvbuf << TermKeys::KEY_F3.chr
            when "14" then @recvbuf << TermKeys::KEY_F4.chr
            when "15" then @recvbuf << TermKeys::KEY_F5.chr
            when "17" then @recvbuf << TermKeys::KEY_F6.chr
            when "18" then @recvbuf << TermKeys::KEY_F7.chr
            when "19" then @recvbuf << TermKeys::KEY_F8.chr
            when "20" then @recvbuf << TermKeys::KEY_F9.chr
            when "21" then @recvbuf << TermKeys::KEY_F10.chr
            when "23" then @recvbuf << TermKeys::KEY_F11.chr
            when "24" then @recvbuf << TermKeys::KEY_F12.chr
          end
        end
      end
    end
  end

  def prefilter_input(str)
    out = ""
    str.each_byte do |ch|
      if ch == 0
        # strip nulls
      elsif ch == ?\n
        if @last_parse_ch != ?\r
          out << TermKeys::KEY_ENTER.chr
        end
      else
        out << ch.chr
      end
      @last_parse_ch = ch
    end
    out
  end

end


# UPARROW     "\e[A"
# DOWNARROW   "\e[B"
# RIGHTARROW  "\e[C"
# LEFTARROW   "\e[D"
# HOME        "\e[2~"
# END         "\e[5~"
# PGUP        "\e[3~"
# PGDN        "\e[6~"
# INSERT      "\e[1~"
# DELETE      "\177"
# F1          "\e[11~"
# ...
# F5          "\e[15~"
# F6          "\e[17~"
# ...
# F10         "\e[21~"
# F11         "\e[23~"
# F12         "\e[24~"


if $0 == __FILE__
  require 'test/unit'

  TEST_HOST = 'localhost'
  TEST_PORT = 12345

  ROWS = 50
  COLS = 132

  def expect(str, sock)
    got = ""
    got << sock.recv(1) while got.length < str.length
    assert_equal( str, got )
  end

  def sendstr(str, sock)
    while str.length > 0
      sent = sock.send(str, 0)
      str = str[sent..-1]
    end
  end

  class TestANSITerm < Test::Unit::TestCase

    include TermKeys

  # def test_aaa
  #   set_trace_func proc {|event, file, line, id, binding, classname|
  #     printf "%8s %s:%-2d %10s %8s\n", event, file, line, id, classname
  #   }
  # end

    def test_report_term_size
      server = TCPServer.new(TEST_PORT)
      client = TCPSocket.new(TEST_HOST, TEST_PORT)
      sv_client = server.accept

      global_signal = GlobalSignal.new

      bufio = BufferedIO.new(client, global_signal)
      wterm = ANSITermIO.new(bufio)
      assert( ! wterm.eof )

      $c_row = 12
      $c_col = 34

      # basic ask_cursor_pos
      assert_equal( "", wterm.recv_nonblock )
      th = Thread.new { wterm.ask_cursor_pos }
      expect( "\e[6n", sv_client )
      sendstr( "\e[#{$c_row};#{$c_col}R", sv_client )
      row, col = th.value
      assert_equal( $c_row, row )
      assert_equal( $c_col, col )
      assert_equal( "", wterm.recv_nonblock )

      # ask_cursor_pos with ill-formed cases
      assert_equal( "", wterm.recv_nonblock )
      th = Thread.new { wterm.ask_cursor_pos }
      expect( "\e[6n", sv_client )
      sendstr( "abc\edef\e[ghi\e[2jkl\e[23mno\e[23;pqr\e[23;45Qstu\e[#{$c_row};#{$c_col}Rvwx", sv_client )
      row, col = th.value
      assert_equal( $c_row, row )
      assert_equal( $c_col, col )
      wterm.wait_data_ready
      assert_equal( "abc\edef\e[ghi\e[2jkl\e[23mno\e[23;pqr\e[23;45Qstuvwx", wterm.recv_nonblock )

      # test ask_term_size
      assert_equal( "", wterm.recv_nonblock )
      th = Thread.new { wterm.ask_term_size }
      expect( "\e[s", sv_client )
      expect( "\e[255;255H", sv_client )
      expect( "\e[6n", sv_client )
      sendstr( "\e[#{ROWS};#{COLS}R", sv_client )
      expect( "\e[u", sv_client )
      rows, cols = th.value
      assert_equal( ROWS, rows )
      assert_equal( COLS, cols )

      # shutdown
      wterm.close
      bufio.close
      assert( wterm.eof )
      
      sv_client.close
      server.close
    end

    def test_termkeys
      server = TCPServer.new(TEST_PORT)
      client = TCPSocket.new(TEST_HOST, TEST_PORT)
      sv_client = server.accept

      global_signal = GlobalSignal.new

      bufio = BufferedIO.new(client, global_signal)
      wterm = ANSITermIO.new(bufio)
      
      th = Thread.new { sv_client.print "up\e[Adown\e[Bright\e[Cleft\e[Deot" }
      wterm.wait_data_ready
      assert_equal( "up#{KEY_UPARROW.chr}down#{KEY_DOWNARROW.chr}right#{KEY_RIGHTARROW.chr}left#{KEY_LEFTARROW.chr}eot", wterm.recv_nonblock )
      th.join

      th = Thread.new { sv_client.print "ins\e[1~home\e[2~end\e[5~pgup\e[3~pgdn\e[6~eot" }
      wterm.wait_data_ready
      assert_equal( "ins#{KEY_INSERT.chr}home#{KEY_HOME.chr}end#{KEY_END.chr}pgup#{KEY_PGUP.chr}pgdn#{KEY_PGDN.chr}eot", wterm.recv_nonblock )
      th.join

      th = Thread.new { sv_client.print "f1\e[11~f2\e[12~f3\e[13~f4\e[14~f5\e[15~f6\e[17~f7\e[18~f8\e[19~f9\e[20~f10\e[21~f11\e[23~f12\e[24~eot" }
      wterm.wait_data_ready
      assert_equal( "f1#{KEY_F1.chr}f2#{KEY_F2.chr}f3#{KEY_F3.chr}f4#{KEY_F4.chr}f5#{KEY_F5.chr}f6#{KEY_F6.chr}f7#{KEY_F7.chr}f8#{KEY_F8.chr}f9#{KEY_F9.chr}f10#{KEY_F10.chr}f11#{KEY_F11.chr}f12#{KEY_F12.chr}eot", wterm.recv_nonblock )
      th.join

      # CR or LF or CRLF should map to KEY_ENTER
      th = Thread.new { sv_client.print "a\nb\rc\r\nd\n\re\n\nf\r\rg\r\n\r\nh" }
      wterm.wait_data_ready
      assert_equal( "a#{KEY_ENTER.chr}b#{KEY_ENTER.chr}c#{KEY_ENTER.chr}d#{KEY_ENTER.chr}#{KEY_ENTER.chr}e#{KEY_ENTER.chr}#{KEY_ENTER.chr}f#{KEY_ENTER.chr}#{KEY_ENTER.chr}g#{KEY_ENTER.chr}#{KEY_ENTER.chr}h", wterm.recv_nonblock )
      th.join

      # delete should map to KEY_DEL, and nulls should be stripped
      th = Thread.new { sv_client.print "a\177b\177\177c\r\000d" }
      wterm.wait_data_ready
      assert_equal( "a#{KEY_DEL.chr}b#{KEY_DEL.chr}#{KEY_DEL.chr}c#{KEY_ENTER.chr}d", wterm.recv_nonblock )
      th.join

      # shutdown
      wterm.close
      bufio.close
      assert( wterm.eof )
      sv_client.close
      server.close
    end

    def test_misc
      server = TCPServer.new(TEST_PORT)
      client = TCPSocket.new(TEST_HOST, TEST_PORT)
      sv_client = server.accept

      global_signal = GlobalSignal.new

      bufio = BufferedIO.new(client, global_signal)
      wterm = ANSITermIO.new(bufio)

      # make sure send_nonblock wired up properly to underlying io
      wterm.send_nonblock("a\nb\nc")
      expect( "a\nb\nc", sv_client )

      # shutdown
      wterm.close
      bufio.close
      assert( wterm.eof )
      sv_client.close
      server.close
    end

    def test_unparsable
      assert( "\e" !~ ANSITermIO::UNPARSABLE_ESC_SEQ )
      assert( "\e[" !~ ANSITermIO::UNPARSABLE_ESC_SEQ )
      assert( "\e[123" !~ ANSITermIO::UNPARSABLE_ESC_SEQ )
      assert( "\e[123;" !~ ANSITermIO::UNPARSABLE_ESC_SEQ )
      assert( "\e[123;456" !~ ANSITermIO::UNPARSABLE_ESC_SEQ )
      assert( "\e[123;456R" !~ ANSITermIO::UNPARSABLE_ESC_SEQ )

      assert( "\e[A" !~ ANSITermIO::UNPARSABLE_ESC_SEQ )
      assert( "\e[B" !~ ANSITermIO::UNPARSABLE_ESC_SEQ )
      assert( "\e[C" !~ ANSITermIO::UNPARSABLE_ESC_SEQ )
      assert( "\e[D" !~ ANSITermIO::UNPARSABLE_ESC_SEQ )

      assert( "\e[123~" !~ ANSITermIO::UNPARSABLE_ESC_SEQ )

      assert( "#" =~ ANSITermIO::UNPARSABLE_ESC_SEQ )
      assert( "\e#" =~ ANSITermIO::UNPARSABLE_ESC_SEQ )
      assert( "\e[#" =~ ANSITermIO::UNPARSABLE_ESC_SEQ )
      assert( "\e[123#" =~ ANSITermIO::UNPARSABLE_ESC_SEQ )
      assert( "\e[123;456#" =~ ANSITermIO::UNPARSABLE_ESC_SEQ )
    end
  end
  
  class TestANSIEmu < Test::Unit::TestCase
  
    def test_cursor_tracking
      term_rows = 3
      term_cols = 5
      emu = ANSIEmu.new(term_rows, term_cols)
      
      assert_equal( 1, emu.cursor_row )
      assert_equal( 1, emu.cursor_col )

      emu.parse(ANSI.set_cursor_pos(0, 0))
      assert_equal( 1, emu.cursor_row )
      assert_equal( 1, emu.cursor_col )

      emu.parse(ANSI.set_cursor_pos(2, 5))
      assert_equal( 2, emu.cursor_row )
      assert_equal( 5, emu.cursor_col )

      # cursor should "hang" at end of current row
      emu.parse("a")
      assert_equal( 2, emu.cursor_row )
      assert_equal( 5, emu.cursor_col )

      # cursor should "unhang" and be in next row, 2nd col!
      emu.parse("b")
      assert_equal( 3, emu.cursor_row )
      assert_equal( 2, emu.cursor_col )

      # clip
      emu.parse(ANSI.set_cursor_pos(100, 100))
      assert_equal( term_rows, emu.cursor_row )
      assert_equal( term_cols, emu.cursor_col )

      # cursor left/right/up/down
      assert_equal( 3, emu.cursor_row )
      assert_equal( 5, emu.cursor_col )
      emu.parse(ANSI.cursor_left(1))
      assert_equal( 3, emu.cursor_row )
      assert_equal( 4, emu.cursor_col )
      emu.parse(ANSI.cursor_left(3))
      assert_equal( 3, emu.cursor_row )
      assert_equal( 1, emu.cursor_col )
      emu.parse(ANSI.cursor_up(2))
      assert_equal( 1, emu.cursor_row )
      assert_equal( 1, emu.cursor_col )
      emu.parse(ANSI.cursor_right(100))
      assert_equal( 1, emu.cursor_row )
      assert_equal( 5, emu.cursor_col )
      emu.parse(ANSI.cursor_down(1))
      assert_equal( 2, emu.cursor_row )
      assert_equal( 5, emu.cursor_col )

      # verify deferred wrap is "cleared" by cursor movment
      emu.parse("a")
      assert_equal( 2, emu.cursor_row )
      assert_equal( 5, emu.cursor_col )
      emu.parse(ANSI.cursor_right)
      assert_equal( 2, emu.cursor_row )
      assert_equal( 5, emu.cursor_col )
      emu.parse("b")
      assert_equal( 2, emu.cursor_row )
      assert_equal( 5, emu.cursor_col )
      emu.parse("c")
      assert_equal( 3, emu.cursor_row )
      assert_equal( 2, emu.cursor_col )
    end

    def test_cursor_save_restore
      term_rows = 3
      term_cols = 5
      emu = ANSIEmu.new(term_rows, term_cols)

      emu.parse("hi")
      assert_equal( 1, emu.cursor_row )
      assert_equal( 3, emu.cursor_col )
      
      emu.parse(ANSI.save_cursor_pos)
      assert_equal( 1, emu.cursor_row )
      assert_equal( 3, emu.cursor_col )
      emu.parse(ANSI.set_cursor_pos(3, 5))
      assert_equal( 3, emu.cursor_row )
      assert_equal( 5, emu.cursor_col )

      emu.parse(ANSI.restore_cursor_pos)
      assert_equal( 1, emu.cursor_row )
      assert_equal( 3, emu.cursor_col )
    end
    
    def test_cr_lf_backspace
      term_rows = 3
      term_cols = 5
      emu = ANSIEmu.new(term_rows, term_cols)
      
      assert_equal( 1, emu.cursor_row )
      assert_equal( 1, emu.cursor_col )
      
      emu.parse("aa\n")
      assert_equal( 2, emu.cursor_row )
      assert_equal( 3, emu.cursor_col )
      
      emu.parse("\r")
      assert_equal( 2, emu.cursor_row )
      assert_equal( 1, emu.cursor_col )

      emu.parse("\b")
      assert_equal( 2, emu.cursor_row )
      assert_equal( 1, emu.cursor_col )
      emu.parse("abc\b\bd\bef\b\b")
      assert_equal( 2, emu.cursor_row )
      assert_equal( 2, emu.cursor_col )
    end

    def test_scroll_region
      term_rows = 5
      term_cols = 10
      emu = ANSIEmu.new(term_rows, term_cols)

      # even if starts above top of rgn, linefeeds
      # should halt us at bottom of region once we get there
      assert_equal( 1, emu.cursor_row )
      emu.parse(ANSI.set_scroll_region(2, 3))
      assert_equal( 1, emu.cursor_row )
      emu.parse("\n")
      assert_equal( 2, emu.cursor_row )
      emu.parse("\n")
      assert_equal( 3, emu.cursor_row )
      emu.parse("\n")
      assert_equal( 3, emu.cursor_row )
      
      # if cursor below region, region is ignored
      emu.parse(ANSI.set_cursor_pos(4, 1))
      assert_equal( 4, emu.cursor_row )
      emu.parse("\n")
      assert_equal( 5, emu.cursor_row )
    end
    
    def test_attrs
      term_rows = 5
      term_cols = 10
      emu = ANSIEmu.new(term_rows, term_cols)
      
      assert_equal( [], emu.attrs )
      
      emu.parse(ANSI.color(ANSI::Yellow, ANSI::BGBlue, ANSI::Bright))
      assert_equal( [ANSI::Yellow, ANSI::BGBlue, ANSI::Bright], emu.attrs )

      emu.parse(ANSI.color(ANSI::Red))
      assert_equal( [ANSI::BGBlue, ANSI::Bright, ANSI::Red], emu.attrs )

      emu.parse(ANSI.color(ANSI::BGGreen))
      assert_equal( [ANSI::Bright, ANSI::Red, ANSI::BGGreen], emu.attrs )

      # should just ignore the new bright since we already have one
      emu.parse(ANSI.color(ANSI::Bright))
      assert_equal( [ANSI::Bright, ANSI::Red, ANSI::BGGreen], emu.attrs )

      # try something whacky with a reset in the middle of a sequence
      emu.parse(ANSI.color(ANSI::Yellow, ANSI::BGBlue, ANSI::Bright,
                           ANSI::Reset, ANSI::Green, ANSI::BGRed))
      assert_equal( [ANSI::Green, ANSI::BGRed], emu.attrs )
    end

  end

end


