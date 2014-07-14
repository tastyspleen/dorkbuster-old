
require 'thread'
require 'fastthread'
require 'timeout'
require 'dbcore/recursive-mutex'
require 'dbcore/global-signal'
require 'dbcore/term-keys'
require 'dbcore/windowed-term'
require 'dbcore/line-edit'
require 'dbcore/login-session'


class DBFullscreenConsole

  include TermKeys

  def initialize(term)
    @term = term
    @prompt = ""
    @echo = true
    @input_buf = []
    @line_buf = ""
    @last_disp_prompt = ""
    @outbuf = ""
    @need_redraw = true
  end

  def close
  end

  # Read line from client (returns nil if full line not received yet.)
  def readln
    maybe_redraw
    # NOTE: push/shift memory leak not an issue here, because += is re-creating @input_buf every time anyway
    @input_buf += @term.recv_nonblock.split(//)
    got_line = false
    while (char = @input_buf.shift)
      case char[0]
        when KEY_BACKSPACE, KEY_DEL then handle_backspace
        when KEY_ENTER              then got_line = true; break
        when (0..31), (128..255)    then nil  # gobble nonprintable chars
        else accept_char(char)
      end
    end
    line = nil
    if got_line
      line = @line_buf
      @line_buf = ""
      @term.print("\r")
      @term.erase_eol
      @need_redraw = true
    end
    line
  end

  def eof
    @term.eof
  end

  def set_prompt(str_or_proc)
    @prompt = str_or_proc
  end

  def set_echo(flag)
    @echo = flag
  end

  def redraw
    @term.print("\r")
    @term.erase_eol
    if ! @outbuf.empty?
      @term.print @outbuf
      @outbuf = ""
    end
    str = (@last_disp_prompt = prompt_str)
    str << @line_buf if @echo
    @term.print(str)
    @need_redraw = false
  end

  def puts(str)
    @outbuf << str + "\n"
    redraw if @line_buf.empty?
  end

  private

  def maybe_redraw
    redraw if @need_redraw  ||  (@line_buf.empty?  && 
                                   (@last_disp_prompt != prompt_str  ||
                                      ! @outbuf.empty?) )
  end
  
  def accept_char(char)
    @line_buf << char
    @term.print(char) if @echo
  end

  def handle_backspace
    sliced = @line_buf.slice!(-1)
    @term.backspace_rubout if sliced && @echo
    maybe_redraw
  end

  def prompt_str
    if @prompt.respond_to? :call
      @prompt.call
    else
      @prompt
    end
  end

end

# 16:01:59 pretz: Just like at the Linux prompt: Contrl A = Home and Control E = End
# 16:03:03 pretz: Control U = Backline, Control W = Backword, Control H = Backspace.
# 16:03:51 pretz: Control P = Last command, Control N = Next command.
# 16:04:16 pretz: Control L = Screen refresh (like @win on if @win is already on).

class DBWindowedConsole

  include TermKeys

  MAX_HIST_LINES = 50

  def initialize(input_term, edit_rgn)
    @term = input_term
    @edit_rgn = edit_rgn
    @line_edit = LineEdit.new(edit_rgn)
    @prompt = ""
    @hist = []
    @hist_idx = 0
    @edited_line = ""
    @input_buf = ""
    @key_hooks = {}
  end

  def close
  end

  # Read line from client (returns nil if full line not received yet.)
  def readln
    @line_edit.set_prompt(prompt_str)
    @input_buf << @term.recv_nonblock
    got_line = false
    cnt = 0
    @input_buf.each_byte do |char|
      cnt += 1
      handle_suspend(char)
      if ! hook_handler(char)
        case char
          when KEY_UPARROW   then hist_prev
          when KEY_DOWNARROW then hist_next
          when KEY_ENTER     then got_line = true; break
          else @line_edit.accept(char)
        end
      end
    end
    @input_buf.slice!(0, cnt)
    if got_line
      hist_add(line = peekln)
      @line_edit.set_line_data("")
      line
    else
      nil
    end
  end

  def peekln
    @line_edit.line_buf
  end

  def history_len
    @hist.length
  end

  def eof
    @term.eof
  end

  def set_prompt(str_or_proc)
    @prompt = str_or_proc
    @line_edit.set_prompt(prompt_str)
  end

  def set_echo(flag)
    @line_edit.set_echo(flag)
  end

  def redraw
    @line_edit.redraw
  end

  def key_hook(keychar, &hook_proc)
    @key_hooks[keychar] = hook_proc
  end
  
  private

  def prompt_str
    if @prompt.respond_to? :call
      @prompt.call
    else
      @prompt
    end
  end

  def hist_prev
    if @hist.length > 0
      @edited_line = peekln if @hist_idx == @hist.length
      if @hist_idx > 0
        @hist_idx -= 1
        @line_edit.set_line_data(@hist[@hist_idx])
      end
    end
  end

  def hist_next
    if @hist_idx < @hist.length
      @hist_idx += 1
      ln = (@hist_idx == @hist.length) ? @edited_line : @hist[@hist_idx]
      @line_edit.set_line_data(ln)
    end
  end

  # TODO: array push/shift memory leak (change to unshift/pop)

  def hist_add(ln)
    @hist.push(ln) unless @hist[-1] == ln
    @hist.shift while @hist.length > MAX_HIST_LINES
    @hist_idx = @hist.length
  end
  
  def handle_suspend(char)
    if char == ?\C-s  &&  ! @term.output_suspend?
      @edit_rgn.clear
      @edit_rgn.home_cursor
      @edit_rgn.print "<SUSPENDED>"
      @term.flush(0.5)
      @term.suspend_output(true)
    else
      if @term.output_suspend?
        @term.suspend_output(false)
        @line_edit.redraw
      end
    end
  end
  
  def hook_handler(char)
    if (hook_proc = @key_hooks[char])
      hook_proc.call(char)
    end
    hook_proc
  end
end


class Backscroller
  MAX_LINES = 1000
  
  def initialize(rgn)
    @rgn = rgn
    @lines = []
    @anchor = -1
  end
  
  def set_buffer(lines, do_redraw=true)
    @lines = []
    @anchor = -1
    accept_lines(lines, false)
    redraw if do_redraw
  end

  def pgup
    return unless @lines.length > @rgn.term_rows
    orig = @anchor
    @anchor = (@lines.length - @rgn.term_rows) if @anchor == -1
    @anchor = [0, @anchor - scroll_rows].max
    redraw if @anchor != orig
  end
  
  def pgdn
    if @anchor != -1
      @anchor += scroll_rows
      @anchor = -1 if @anchor >= (@lines.length - @rgn.term_rows)
      redraw
    end
  end
  
  def puts(str)
    accept_lines( str.split(/\n/), true )
  end

  def redraw
    ofst = (@anchor == -1)? [0, @lines.length - @rgn.term_rows].max : @anchor
    @rgn.each_row do |row|
      line = @lines[ofst + (row - 1)].to_s
      if @anchor != -1  &&  row == @rgn.term_rows
        line = " v" * (@rgn.term_cols / 2)
      end
      @rgn.print_erased_clipped(line)
    end
    last_row = [@lines.length - ofst, @rgn.term_rows].min
    @rgn.set_cursor_pos(last_row, @rgn.term_cols)
  end

  private
  
  def scroll_rows
    (@rgn.term_rows * (2.0/3.0)).round
  end

  def accept_lines(rawlines, do_draw)
    cliplines = []
  # rawlines.each {|line| cliplines += line.scan(/.{1,#{@rgn.term_cols}}/) }
    rawlines.each {|line| cliplines.push( *ANSI.strbreak(line, @rgn.term_cols) ) }
    cliplines.each {|line| accept(line, do_draw) }
  end

  # TODO: array push/shift memory leak (change to unshift/pop)
  def accept(line, do_draw)
    @lines << line
    if do_draw && @anchor == -1
      @rgn.cr unless @rgn.cursor_row == 1  &&  @rgn.cursor_col == 1
      @rgn.print(line)
    end
    while @lines.length > MAX_LINES
      @lines.shift
      @anchor = [0, @anchor - 1].max if @anchor != -1
    end
    redraw if do_draw && @anchor == 0 && @lines.length == MAX_LINES
  end
end



class DBClient
  include RconLoginSession

  MIN_ROWS_LOG = 4
  MIN_ROWS_INFO = 1
  MIN_ROWS_DYN = 18 # was :20
  MIN_ROWS_CHAT = 4
  MIN_ROWS_INPUT = 1
  MIN_ROWS_TOTAL = MIN_ROWS_LOG + MIN_ROWS_INFO + MIN_ROWS_DYN + MIN_ROWS_CHAT + MIN_ROWS_INPUT

  attr_reader :console, :windowed, :stream_enabled, :log_rgn, :info_rgn, :dyn_rgn, :chat_rgn, :input_rgn

  def initialize(rcon_server, logger, client_sock, global_signal)
    @windowed = false
    @stream_enabled = false
    @logger = logger
    @bufio = BufferedIO.new(client_sock, global_signal)
    @termio = ANSITermIO.new(@bufio)
    @term = WindowedTerminal.new(@termio)
    @log_rgn = OutputRegion.new(@term)
    @info_rgn = OutputRegion.new(@term)
    @dyn_rgn = OutputRegion.new(@term)
    @chat_rgn = OutputRegion.new(@term)
    @input_rgn = OutputRegion.new(@term)
    @chatscroller = Backscroller.new(@chat_rgn)
    @fullscreen_console = DBFullscreenConsole.new(@termio)
    @windowed_console = DBWindowedConsole.new(@term, @input_rgn)
    # ctrl A/E  home/end
    # ctrl U  clear input line
    # ctrl... ?  return to bottom of chatscroller
    # ctrl L - refresh whole screen (@win on)
    # ctrl W - back-word in line edit
    @windowed_console.key_hook(TermKeys::KEY_PGUP) { @chatscroller.pgup; @input_rgn.focus }
    @windowed_console.key_hook(TermKeys::KEY_PGDN) { @chatscroller.pgdn; @input_rgn.focus }
    @windowed_console.key_hook(?\C-y) { @chatscroller.pgup; @input_rgn.focus }
    @windowed_console.key_hook(?\C-v) { @chatscroller.pgdn; @input_rgn.focus }
    @console = @fullscreen_console
    @prompt = ""

    @termio.set_scroll_fullscreen
    @term.set_color(ANSI::Reset)
    @termio.erase_screen
    # attempt to force telnet client into unbuffered character mode
    will_echo = "\xff\xfb\x01"
    do_sga = "\xff\xfd\x02"
    do_linemode = "\xff\xfd\x22"
    @bufio.send_nonblock(will_echo + do_sga + do_linemode)
    # ULTRA-KLUDGE!  Since we don't have a parser to handle telnet
    # response codes from the client's terminal... We'll cheesily
    # wait 1/2 sec and gobble them... :(
    sleep(0.5)
    @bufio.recv_nonblock  # gobble response!
    @termio.erase_screen
    @termio.set_cursor_pos(1, 1)

    set_windowed_mode(false)
    self.session_init(self, rcon_server, logger)
  end

  def close
    @windowed_console.close
    @fullscreen_console.close
    @term.close
    @termio.close
    @bufio.close
  end
  
  def eof
    @term.eof
  end

  def peeraddr
    @term.peeraddr
  end

  def output_suspend?; @term.output_suspend? end

  def set_prompt(str_or_proc)
    @prompt = str_or_proc
    str_or_proc = "" if @stream_enabled
    @console.set_prompt(str_or_proc)
  end

  def set_echo(flag)
    flag = false if @stream_enabled
    @console.set_echo(flag)
  end  

  def con_puts(str)
    if @windowed
      @log_rgn.cr
      @log_rgn.print(str)
      @input_rgn.focus
    else
      @console.puts(str)
    end
  end

  def chat_puts(str)
    if @windowed
      # @chat_rgn.cr
      # @chat_rgn.print(str)
      @chatscroller.puts(str)
      @input_rgn.focus
    else
      @console.puts(str)
    end
  end

  def log_puts(str)
    con_puts(str)
  end

  def set_windowed_mode(mode)
    if mode == :stream
      @stream_enabled = true
      fullscreen_mode_on if @windowed
      @console.set_prompt("")
      @console.set_echo(false)
    else
      if mode 
        windowed_mode_on
      else
        fullscreen_mode_on
      end
      @stream_enabled = false
    end
  end

  private
  
  def windowed_mode_on
    @windowed = false
    
    begin
      @term.ask_term_size
    rescue Timeout::Error
      log_puts(ANSI.dbwarn("Dork Buster: Your terminal wouldn't tell me its size.  Windowed mode failed.  "+
                           "Sometimes this can happen if your terminal emulator is in line-buffered "+
                           "mode instead of character mode."))
      return
    end

    if @term.term_rows < MIN_ROWS_TOTAL
      log_puts(ANSI.dbwarn("Dork Buster: Your terminal reported its size as #{@term.term_rows} rows, but a minimum of #{MIN_ROWS_TOTAL} rows are needed for windowed mode."))
      return
    end      

    @console = @windowed_console

    rows_left = @term.term_rows
    dyn_height = MIN_ROWS_DYN
    rows_left -= dyn_height
    info_height = MIN_ROWS_INFO
    rows_left -= info_height
    log_height = MIN_ROWS_LOG
    rows_left -= log_height
    input_height = MIN_ROWS_INPUT
    rows_left -= input_height
    chat_height = rows_left
    if chat_height > MIN_ROWS_CHAT
      chat_extra = chat_height - MIN_ROWS_CHAT
      to_log = (chat_extra * 0.33).round
# print "term rows=", @term.term_rows, " sh=", dyn_height, " lh=", log_height, " ch=", chat_height, " rl=", rows_left, " ce=", chat_extra, " tol=", to_log, "\n"
      log_height += to_log
      chat_height -= to_log
    end
# print "term rows=", @term.term_rows, " sh=", dyn_height, " lh=", log_height, " ch=", chat_height, " rl=", rows_left, "\n"

    at_row = 1
    @log_rgn.set_scroll_region(at_row, at_row + (log_height - 1))
    at_row += log_height
    @info_rgn.set_scroll_region(at_row, at_row + (info_height - 1))
    at_row += info_height
    @dyn_rgn.set_scroll_region(at_row, at_row + (dyn_height - 1))
    at_row += dyn_height
    @chat_rgn.set_scroll_region(at_row, at_row + (chat_height - 1))
    at_row += chat_height
    @input_rgn.set_scroll_region(at_row, at_row + (input_height - 1))

    @log_rgn.set_color(ANSI::Reset)
    @log_rgn.clear
  # @info_rgn.set_color(ANSI::Bright, ANSI::Blue, ANSI::BGWhite)
  # @info_rgn.set_color(ANSI::Bright, ANSI::Blue, ANSI::BGRed)
  # @info_rgn.set_color(ANSI::Bright, ANSI::Cyan, ANSI::BGRed)
  # @info_rgn.set_color(ANSI::Bright, ANSI::Red, ANSI::BGCyan)
    @info_rgn.set_color(ANSI::Bright, ANSI::White, ANSI::BGCyan)
    @info_rgn.clear
    @dyn_rgn.set_color(ANSI::Reset, ANSI::BGYellow)
    @dyn_rgn.clear
  # @chat_rgn.set_color(ANSI::Reset, ANSI::Green, ANSI::BGWhite)
  # @chat_rgn.set_color(ANSI::Reset, ANSI::Green, ANSI::BGCyan)
  # @chat_rgn.set_color(ANSI::Bright, ANSI::Green, ANSI::BGCyan)
  # @chat_rgn.set_color(ANSI::Reset, ANSI::Green, ANSI::BGBlue)
  # @chat_rgn.set_color(ANSI::Reset, ANSI::Green)
    @chat_rgn.set_color(ANSI::Reset)
    @chat_rgn.clear
    @input_rgn.set_color(ANSI::Bright, ANSI::Yellow, ANSI::BGBlue)
    @input_rgn.clear

    @log_rgn.home_cursor
    @info_rgn.home_cursor
    @dyn_rgn.home_cursor
    @chat_rgn.home_cursor
    @input_rgn.home_cursor

    @windowed = true
    self.session_show_recent_log_hist(@log_rgn.term_rows)
    backfill_chatscroller
    @console.set_prompt(@prompt)
    @console.redraw
  end

  def fullscreen_mode_on
    @console = @fullscreen_console

    @log_rgn.set_scroll_fullscreen
    @info_rgn.set_scroll_fullscreen
    @dyn_rgn.set_scroll_fullscreen
    @chat_rgn.set_scroll_fullscreen
    @input_rgn.set_scroll_fullscreen
    
    @termio.set_scroll_fullscreen
    @term.set_cursor_pos(255, 1)
    @term.set_color(ANSI::Reset)
    @term.puts
    @windowed = false

    @console.set_prompt(@prompt)
  end

  def backfill_chatscroller
    rawlines = @logger.recent_log_hist(1000)
    chatlines = []
    rawlines.each do |line|
      # kludge: look for green text
      # line="05:01:11 \e[32mquadz: hi\e[0m"
      chatlines << line if line =~ /\A\d\d:\d\d:\d\d \e\[32m\w+:/
    end
    @chatscroller.set_buffer(chatlines)
  end
  
end




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

  class MockOutputRegion
    attr_accessor :buf, :term_rows, :term_cols
    def initialize(rows, cols)
      @term_rows, @term_cols = rows, cols
      @buf = ""
    end
    def method_missing(id, *args)
      @buf << "{#{id}(#{args.join(',')})}"
    end
  end

  class MockInputTerminal
    attr_accessor :buf
    def initialize
      @buf = ""
    end
    def recv_nonblock
      dat = @buf
      @buf = ""
      dat
    end
    def output_suspend?; false end
  end

  class TestDBWindowedConsole < Test::Unit::TestCase
  
    include TermKeys

    def test_readln
      input_term = MockInputTerminal.new
      # chat_rgn = MockOutputRegion.new(10, 80)
      edit_rgn = MockOutputRegion.new(1, 80)
      console = DBWindowedConsole.new(input_term, edit_rgn)

      assert_nil( console.readln )

      input_term.buf = "hi"
      edit_rgn.buf = ""
      assert_nil( console.readln )
      assert_equal( "", input_term.buf )
      assert_equal( "{print(h)}{print(i)}", edit_rgn.buf )

      input_term.buf = KEY_ENTER.chr + "!"
      edit_rgn.buf = ""
      assert_equal( "hi", console.readln )
      assert_equal( "", input_term.buf )
      assert_nil( console.readln )
      assert_equal( "{set_cursor_pos(1,1)}{erase_eol()}{set_cursor_pos(1,1)}{print(!)}", edit_rgn.buf )
    end  

    def test_history
      input_term = MockInputTerminal.new
      # chat_rgn = MockOutputRegion.new(10, 80)
      edit_rgn = MockOutputRegion.new(1, 80)
      console = DBWindowedConsole.new(input_term, edit_rgn)
      
      assert_equal( 0, console.history_len )
      input_term.buf = "line1" + KEY_ENTER.chr
      assert_equal( "line1", console.readln )
      assert_equal( 1, console.history_len )
      
      input_term.buf = "line2" + KEY_ENTER.chr
      assert_equal( "line2", console.readln )
      assert_equal( 2, console.history_len )
      
      input_term.buf = "line3"
      assert_equal( nil, console.readln )
      assert_equal( 2, console.history_len )
      assert_equal( "", input_term.buf )

      # verify line being edited is tossed when scrolling
      # back thru history and pressing enter
      assert_equal( "line3", console.peekln )
      input_term.buf = KEY_UPARROW.chr; console.readln
      assert_equal( "line2", console.peekln )
      input_term.buf = KEY_UPARROW.chr; console.readln
      assert_equal( "line1", console.peekln )
      input_term.buf = KEY_UPARROW.chr; console.readln
      assert_equal( "line1", console.peekln )
      input_term.buf = KEY_DOWNARROW.chr; console.readln
      assert_equal( "line2", console.peekln )
      input_term.buf = "a"; console.readln
      assert_equal( "line2a", console.peekln )
      assert_equal( 2, console.history_len )
      input_term.buf = KEY_ENTER.chr
      assert_equal( "line2a", console.readln )
      assert_equal( 3, console.history_len )
      assert_equal( "", console.peekln )

      # verify line being edited is remembered when
      # scrolling back thru history and then forward again
      input_term.buf = "line4"
      assert_equal( nil, console.readln )
      assert_equal( "line4", console.peekln )
      input_term.buf = KEY_UPARROW.chr; console.readln
      assert_equal( "line2a", console.peekln )
      input_term.buf = KEY_UPARROW.chr; console.readln
      assert_equal( "line2", console.peekln )
      input_term.buf = KEY_DOWNARROW.chr; console.readln
      assert_equal( "line2a", console.peekln )
      input_term.buf = KEY_DOWNARROW.chr; console.readln
      assert_equal( "line4", console.peekln )
      input_term.buf = KEY_ENTER.chr
      assert_equal( "line4", console.readln )
      assert_equal( 4, console.history_len )
      assert_equal( "", console.peekln )

      # verify same line entered repeatedly is not duplicated in history
      assert_equal( 4, console.history_len )
      input_term.buf = "line4" + KEY_ENTER.chr
      assert_equal( "line4", console.readln )
      assert_equal( 4, console.history_len )

      # verify history limited to MAX      
      DBWindowedConsole::MAX_HIST_LINES.times do |i| 
        input_term.buf = "line#{4+i}" + KEY_ENTER.chr
        assert_equal( "line#{4+i}", console.readln )
      end
      assert_equal( DBWindowedConsole::MAX_HIST_LINES, console.history_len )
      
    end
    
  end

end




# agents should have their own x.y addressble, color display
# in DYN_DISP 


