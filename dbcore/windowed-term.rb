
require 'dbcore/ansi-term'
require 'dbcore/recursive-mutex'


class ScrollRegion
  attr_reader :row_start, :row_end, :cursor_row, :cursor_col, :attrs

  def self.new_fullscreen
    inst = new(1, 255)
    inst.instance_eval { @fullscreen = true; @cursor_row = 255 }
    inst
  end
  
  def initialize(row_start, row_end)
    set_region(row_start, row_end)
    @cursor_row = @row_start
    @cursor_col = 1
    @attrs = []
    @fullscreen = false
  end

  def set_region(row_start, row_end)
    @row_start, @row_end = row_start, row_end
  end
  
  def fullscreen?; @fullscreen end

  def save_state(termio)
    @cursor_row = termio.cursor_row
    @cursor_col = termio.cursor_col
    @attrs = termio.attrs
  end
  
  def restore_state(termio)
    if @fullscreen
      termio.set_scroll_fullscreen
    else
      termio.set_scroll_region(@row_start, @row_end)
    end
    row = [ [@row_start, @cursor_row].max, @row_end].min
    termio.set_cursor_pos(row, @cursor_col)
    termio.set_color(ANSI::Reset, *@attrs)
  end

  def each_row
    @row_start.upto(@row_end) {|row| yield row }
  end

  def num_rows
    (@row_end - @row_start) + 1
  end
  
  def to_s
    "<#{@row_start},#{@row_end}:#{@cursor_row},#{@cursor_col},#{@attrs.inspect}>"
  end
end

SCROLL_REGION_FULLSCREEN = ScrollRegion.new_fullscreen


class WindowedTerminal
  def initialize(termio)
    @termio = termio
    @scroll_region = SCROLL_REGION_FULLSCREEN
    @serial_access_mutex = RecursiveMutex.new
  end

  def close
    # caller responsible for @termio.close
  end

  def send_nonblock(dat); @termio.send_nonblock(dat) end  
  def recv_nonblock; @termio.recv_nonblock end
  def eof; @termio.eof end
  def peeraddr; @termio.peeraddr end
  def flush(timeout_secs); @termio.flush(timeout_secs) end
  
  def suspend_output(flag); @termio.suspend_output(flag) end
  def output_suspend?; @termio.output_suspend? end

  def term_rows; @termio.term_rows end
  def term_cols; @termio.term_cols end
  def cursor_row; @termio.cursor_row end
  def cursor_col; @termio.cursor_col end

  def set_cursor_pos(row, col); @termio.set_cursor_pos(row,col) end
  def get_cursor_pos; [cursor_row, cursor_col] end

  # the ask_ methods actually query the remote terminal (slow)
  def ask_term_size; @termio.ask_term_size end
  def ask_cursor_pos; @termio.ask_cursor_pos end

  def set_color(*attrs); @termio.set_color(*attrs) end

  def cursor_left(cnt=1);  @termio.cursor_left(cnt) end
  def cursor_right(cnt=1); @termio.cursor_right(cnt) end
  def cursor_up(cnt=1);    @termio.cursor_up(cnt) end
  def cursor_down(cnt=1);  @termio.cursor_down(cnt) end
  
  def backspace_rubout(cnt=1); @termio.backspace_rubout(cnt) end

  def erase_line; @termio.erase_line end
  def erase_eol; @termio.erase_eol end

  def print(*args); @termio.print(*args) end
  def puts(*args); @termio.puts(*args) end


  # set scrolling region, SCROLL_REGION_FULLSCREEN for fullscreen
  def set_scroll_region(rgn)
    @serial_access_mutex.synchronize {
      if rgn.object_id != @scroll_region.object_id
        @scroll_region.save_state(@termio)
        rgn.restore_state(@termio)
        @scroll_region = rgn
      end
      yield self if block_given?
    }
  end

end


class OutputRegion
  def initialize(windowed_term)
    @term = windowed_term
    set_scroll_fullscreen
  end

  def set_scroll_region(row_start, row_end)
    if @rgn.nil?  ||  @rgn.object_id == SCROLL_REGION_FULLSCREEN.object_id
      @rgn = ScrollRegion.new(row_start, row_end)
    else
      @rgn.set_region(row_start, row_end)
    end
  end

  def set_scroll_fullscreen
    @rgn = SCROLL_REGION_FULLSCREEN
  end

  def term_cols; @term.term_cols end
  def term_rows; @rgn.num_rows end

  def row_start; @rgn.row_start end
  def row_end; @rgn.row_end end

  def cursor_row
    @term.set_scroll_region(@rgn) {|io|
      (io.cursor_row - @rgn.row_start) + 1
    }
  end
  def cursor_col; @term.set_scroll_region(@rgn) {|io| io.cursor_col } end

  def set_color(*attrs); @term.set_scroll_region(@rgn) {|io| io.set_color(*attrs) } end

  def focus; @term.set_scroll_region(@rgn) {|io| } end
  def print(*args); @term.set_scroll_region(@rgn) {|io| io.print(*args) } end
  def puts(*args); @term.set_scroll_region(@rgn) {|io| io.puts(*args) } end

  def erase_line; @term.set_scroll_region(@rgn) {|io| io.erase_line } end
  def erase_eol; @term.set_scroll_region(@rgn) {|io| io.erase_eol } end

  def clear(row_start=@rgn.row_start, row_end=@rgn.row_end)
    @term.set_scroll_region(@rgn) do |io|
      oldpos = io.get_cursor_pos
      row_start.upto(row_end) do |row|
        io.set_cursor_pos(row, 1)
        # io.erase_line
        # hmmmm.... it seems some emulators (OS X) won't erase with
        # color unless a character has been printed
        io.print " "
        io.erase_eol
      end
      io.set_cursor_pos(*oldpos)
    end
  end

  def clear_down
    @term.set_scroll_region(@rgn) do |io|
      io.print " " if io.cursor_col < io.term_cols
      io.erase_eol
      clear(io.cursor_row + 1, @rgn.row_end)
    end
  end
  
  def home_cursor
    @term.set_scroll_region(@rgn) {|io| io.set_cursor_pos(@rgn.row_start, 1) }
  end

  def set_cursor_pos(row, col)
    @term.set_scroll_region(@rgn) {|io| io.set_cursor_pos(@rgn.row_start + (row - 1), col) }
  end

  def cursor_left(cnt=1);  @term.set_scroll_region(@rgn) {|io| io.cursor_left(cnt) } end
  def cursor_right(cnt=1); @term.set_scroll_region(@rgn) {|io| io.cursor_right(cnt) } end
  def cursor_up(cnt=1);    @term.set_scroll_region(@rgn) {|io| io.cursor_up(cnt) } end
  def cursor_down(cnt=1);  @term.set_scroll_region(@rgn) {|io| io.cursor_down(cnt) } end

  def backspace_rubout(cnt=1); @term.set_scroll_region(@rgn) {|io| io.backspace_rubout(cnt) } end

  def print_clipped(line)
    cols_to_end = (@term.term_cols - @term.cursor_col) + 1
    print(ANSI.strclip(line, cols_to_end))
  end

  def print_erased_clipped(line)
    print_clipped(line)
    erase_eol if @term.cursor_col < @term.term_cols
  end
    
  def cr
    puts
  end

  def each_row
    @term.set_scroll_region(@rgn) do |io|
      @rgn.each_row do |absrow|
        io.set_cursor_pos(absrow, 1)
        row = (absrow - @rgn.row_start) + 1
        yield row if block_given?
      end
    end
  end

  # def batch
  #   @term.set_scroll_region(@rgn) {|io| yield self if block_given? }
  # end

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

  class MockANSITermIO
    attr_accessor :buf
    def initialize(rows, cols)
      @emu = ANSIEmu.new(rows, cols)
      @buf = ""
    end
    
    def term_rows; @emu.term_rows end
    def term_cols; @emu.term_cols end
    def cursor_row; @emu.cursor_row end
    def cursor_col; @emu.cursor_col end
    def attrs; @emu.attrs end

    def _set_scroll_fullscreen; @emu.parse(ANSI.set_scroll_fullscreen) end
    def _set_scroll_region(row_start, row_end); @emu.parse(ANSI.set_scroll_region(row_start, row_end)) end
    def _set_color(*color_attrs); @emu.parse(ANSI.color(*color_attrs)) end
    def _set_cursor_pos(row, col); @emu.parse(ANSI.set_cursor_pos(row, col)) end

    def method_missing(id, *args)
      @buf << "{#{id}(#{args.join(',')})}"
      shunt = ("_" + id.to_s).intern
      send(shunt, *args) if respond_to? shunt
    end
  end

  class TestWindowedTerm < Test::Unit::TestCase

    def test_set_scroll_region
      termio = MockANSITermIO.new(10, 50)
      term = WindowedTerminal.new(termio)

      assert_equal( "", termio.buf )
      
      # fullscreen is the default, so setting it here should generate no termio calls
      term.set_scroll_region(SCROLL_REGION_FULLSCREEN)
      assert_equal( "", termio.buf )
      term.set_cursor_pos(2, 3)
      term.set_color(ANSI::Bright, ANSI::Yellow, ANSI::BGBlue)
      
      rgn1 = ScrollRegion.new(2, 4)
      termio.buf = ""
      term.set_scroll_region(rgn1)
      assert_equal( "{set_scroll_region(2,4)}{set_cursor_pos(2,1)}{set_color(0)}", termio.buf )
      term.set_cursor_pos(3, 2)
      term.set_color(ANSI::Green, ANSI::BGRed)

      termio.buf = ""
      term.set_scroll_region(SCROLL_REGION_FULLSCREEN)
      assert_equal( "{set_scroll_fullscreen()}{set_cursor_pos(2,3)}{set_color(0,1,33,44)}", termio.buf )
    end

  end
end



