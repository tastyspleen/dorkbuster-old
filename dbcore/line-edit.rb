
require 'dbcore/term-keys'


class LineEdit
  include TermKeys

  LINE_EDIT_ROW = 1  # which row number of our display region we occupy
  EDGE_REPOS_THRESH = 5  # num chars cursor from edge of screen when repos happens
  REPOS_SHIFT_FACTOR = (2.0/3.0)

  attr_reader :line_buf, :cursor_pos, :disp_ofst

  def initialize(display_rgn)
    @disp_rgn = display_rgn
    @prompt = ""
    @line_buf = ""
    @cursor_pos = 0
    @disp_ofst = 0
    @echo = true
  end

  def set_prompt(str)
    if @prompt != str
      @prompt = str
      handle_repos_right
      handle_repos_left
      redraw
    end
  end

  def set_line_data(str)
    if @line_buf != str
      @line_buf = str.dup
      @cursor_pos = @line_buf.length
      @disp_ofst = 0
      handle_repos_right
      redraw
    end
  end

  def set_echo(flag)
    if flag != @echo
      @echo = flag
      @disp_ofst = 0
      redraw
    end
  end

  def redraw
    return echo_off_redraw unless @echo
    @disp_rgn.set_cursor_pos(LINE_EDIT_ROW, 1)
    whole_line = @prompt + @line_buf
    to_screen = whole_line[@disp_ofst, @disp_rgn.term_cols].to_s
    @disp_rgn.print to_screen unless to_screen.empty?
    @disp_rgn.erase_eol
    @disp_rgn.set_cursor_pos(LINE_EDIT_ROW, disp_cursor_col)
  end

  def accept(char)
    case char
      when KEY_BACKSPACE then backspace
      when KEY_DEL, ?\C-d then del
      when KEY_LEFTARROW then move_left
      when KEY_RIGHTARROW then move_right
      when KEY_END, ?\C-e then move_end
      when KEY_HOME, ?\C-a then move_home
      when ?\C-u then clear_all
      when (0..31), (128..255) then nil  # gobble nonprintable chars
      else insert(char)
    end
  end
  
  private
  
  def echo_off_redraw
    @disp_rgn.set_cursor_pos(LINE_EDIT_ROW, 1)
    @disp_rgn.print @prompt unless @prompt.empty?
    @disp_rgn.erase_eol
    @disp_rgn.set_cursor_pos(LINE_EDIT_ROW, @prompt.length + 1)
  end

  def redraw_from(linebuf_ofst)
    return echo_off_redraw unless @echo
    whole_line = @prompt + @line_buf
    whole_line_ofst = @prompt.length + linebuf_ofst
    to_screen_col = (whole_line_ofst - @disp_ofst) + 1
    to_screen_str = whole_line[whole_line_ofst, @disp_rgn.term_cols - (to_screen_col - 1)].to_s
    @disp_rgn.set_cursor_pos(LINE_EDIT_ROW, to_screen_col)
    @disp_rgn.print to_screen_str unless to_screen_str.empty?
    @disp_rgn.erase_eol
    @disp_rgn.set_cursor_pos(LINE_EDIT_ROW, disp_cursor_col)
  end

  def disp_cursor_col
    (1 + @prompt.length + @cursor_pos) - @disp_ofst
  end

  def clear_all
    set_line_data("")
  end

  def backspace
    if @cursor_pos > 0
      @cursor_pos -= 1
      @line_buf.slice!(@cursor_pos)
      if not handle_repos_left      
        if @cursor_pos < @line_buf.length
          redraw_from(@cursor_pos)
        else
          @disp_rgn.backspace_rubout if @echo
        end
      end
    end
  end

  def del
    if @cursor_pos < @line_buf.length
      @line_buf.slice!(@cursor_pos)
      redraw_from(@cursor_pos)
    end
  end

  def move_left
    if @cursor_pos > 0
      @cursor_pos -= 1
      if not handle_repos_left
        @disp_rgn.cursor_left if @echo
      end
    end
  end

  def move_right
    if @cursor_pos < @line_buf.length
      @cursor_pos += 1
      if not handle_repos_right
        @disp_rgn.cursor_right if @echo
      end
    end
  end

  def move_end
    if @cursor_pos != @line_buf.length
      @cursor_pos = @line_buf.length
      if not handle_repos_right
        redraw
      end
    end
  end

  def move_home
    if @cursor_pos != 0
      @cursor_pos = 0
      if not handle_repos_left
        redraw
      end
    end
  end

  def clip_cursor_pos(pos = @cursor_pos)
    @cursor_pos = [[0, pos].max, @line_buf.length].min
  end

  def insert(char)
    inserting = (@cursor_pos < @line_buf.length)
    @line_buf.insert(@cursor_pos, char.chr)
    @cursor_pos += 1
    if not handle_repos_right
      if inserting
        redraw_from(@cursor_pos - 1)
      else
        @disp_rgn.print(char.chr) if @echo
      end
    end
  end

  def repos_col_left
    (@disp_rgn.term_cols - (REPOS_SHIFT_FACTOR * @disp_rgn.term_cols)).round
  end

  def repos_col_right
    (REPOS_SHIFT_FACTOR * @disp_rgn.term_cols).round + 1
  end

  def handle_repos_right
    dcc = disp_cursor_col
    return false unless dcc >= (@disp_rgn.term_cols - (EDGE_REPOS_THRESH - 1))
    whole_line_len = @prompt.length + @line_buf.length
    max_disp_ofst = [0, whole_line_len - EDGE_REPOS_THRESH].max
    @disp_ofst = [max_disp_ofst, @disp_ofst + (dcc - repos_col_left)].min
    redraw
    true
  end
  
  def handle_repos_left
    dcc = disp_cursor_col
    special_zero_repos_show_prompt = (@cursor_pos == 0  &&  @disp_ofst != 0)
    return false unless dcc <= EDGE_REPOS_THRESH  ||  special_zero_repos_show_prompt
    @disp_ofst = [0, @disp_ofst - [0, repos_col_right - dcc].max ].max
    redraw
    true
  end

end



if $0 == __FILE__
  require 'test/unit'

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

  class TestLineEdit < Test::Unit::TestCase
    include TermKeys

    def test_basic_insert
      mock_rgn = MockOutputRegion.new(1, 20)
      le = LineEdit.new(mock_rgn)
      assert_equal( "", mock_rgn.buf )
      
      # setting prompt should cause a redraw
      mock_rgn.buf = ""
      le.set_prompt("012345678>")
      assert_equal( "{set_cursor_pos(1,1)}{print(012345678>)}{erase_eol()}{set_cursor_pos(1,11)}", mock_rgn.buf )
      assert_equal( 0, le.cursor_pos )
      
      # typing an "a" should merely print the "a"
      mock_rgn.buf = ""
      le.accept(?a)
      assert_equal( "a", le.line_buf )
      assert_equal( "{print(a)}", mock_rgn.buf )
      assert_equal( 1, le.cursor_pos )
      
      mock_rgn.buf = ""
      le.accept(KEY_LEFTARROW)
      assert_equal( "{cursor_left()}", mock_rgn.buf )
      assert_equal( 0, le.cursor_pos )

      # a second leftarrow should do nothing since we're at leftmost already
      mock_rgn.buf = ""
      le.accept(KEY_LEFTARROW)
      assert_equal( "", mock_rgn.buf )
      assert_equal( 0, le.cursor_pos )

      # typing a character here should cause an insert, and partial redraw      
      mock_rgn.buf = ""
      le.accept(?b)
      assert_equal( "ba", le.line_buf )
      assert_equal( "{set_cursor_pos(1,11)}{print(ba)}{erase_eol()}{set_cursor_pos(1,12)}", mock_rgn.buf )
      assert_equal( 1, le.cursor_pos )

      mock_rgn.buf = ""
      le.accept(KEY_RIGHTARROW)
      assert_equal( "{cursor_right()}", mock_rgn.buf )
      assert_equal( 2, le.cursor_pos )

      mock_rgn.buf = ""
      le.accept(KEY_RIGHTARROW)
      assert_equal( "", mock_rgn.buf )
      assert_equal( 2, le.cursor_pos )

      # make sure setting shorter line data clips cursor pos
      mock_rgn.buf = ""
      le.set_line_data("a")
      assert_equal( 1, le.cursor_pos )  # ok to be one past end of non-empty string
      le.set_line_data("")
      assert_equal( 0, le.cursor_pos )  # empty string can only be at pos 0
    end

    def test_edge_reposition
      term_cols = 20
      prompt_str = "012345678>"
      line_data = "a123456789b123456789c123456789"
      whole_line = prompt_str + line_data
      repos_thresh = LineEdit::EDGE_REPOS_THRESH

      mock_rgn = MockOutputRegion.new(1, term_cols)
      le = LineEdit.new(mock_rgn)
      le.set_prompt(prompt_str)
      le.set_line_data(line_data)
    
      assert_equal( line_data.length, le.cursor_pos )
      le.accept(KEY_HOME)
      assert_equal( 0, le.cursor_pos )

      repos_col_left = le.send(:repos_col_left)
      repos_col_right = le.send(:repos_col_right)

      assert_equal( 7, repos_col_left )
      assert_equal( 14, repos_col_right )

      # move left as far as we can without a repos
      mock_rgn.buf = ""
      (repos_thresh - 1).times { le.accept(KEY_RIGHTARROW) }
      assert_equal( "{cursor_right()}" * (repos_thresh - 1), mock_rgn.buf )
      assert_equal( (repos_thresh - 1), le.cursor_pos )
      assert_equal( 0, le.disp_ofst )

      # move left again, triggering repos
      # assuming repos_thresh == 5, repos_col_left = 7, repos_col_right = 14 for diagram
      #[    > v      v <    ]
      # 012345678>a123456789b123456789c123456789
      #[    >          <    ]
      # >a123456789b123456789c123456789
      #       ^--------/
      mock_rgn.buf = ""
      prev_cursor_col = le.send(:disp_cursor_col)
      assert_equal( 15, prev_cursor_col )
      le.accept(KEY_RIGHTARROW)
      assert_equal( 5, le.cursor_pos )
      assert_equal( (prev_cursor_col + 1) - repos_col_left, le.disp_ofst)
      assert_equal( repos_col_left, le.send(:disp_cursor_col) )
      disp_line = whole_line.slice(le.disp_ofst, term_cols)
      disp_cursor_col = ((prompt_str.length + le.cursor_pos) - le.disp_ofst) + 1
      assert_equal( "{set_cursor_pos(1,1)}{print(#{disp_line})}{erase_eol()}{set_cursor_pos(1,#{disp_cursor_col})}", mock_rgn.buf )

      # while we're shifted, try an insert (exercizes redraw_from)
      #[    > v      v <    ]
      # >a123456789b123456789c123456789
      #[      ^             ]
      # >a1234x56789b123456789c123456789
      #        ^
      mock_rgn.buf = ""
      assert_equal( 5, le.cursor_pos )
      line_data.insert(le.cursor_pos, "x")
      whole_line = prompt_str + line_data
      le.accept(?x)
      assert_equal( 6, le.cursor_pos )
      assert_equal( repos_col_left + 1, le.send(:disp_cursor_col) )
      disp_cursor_col = ((prompt_str.length + le.cursor_pos) - le.disp_ofst) + 1
      disp_line = line_data.slice(le.cursor_pos - 1, term_cols - ((disp_cursor_col - 1) - 1))
      assert_equal( "{set_cursor_pos(1,#{disp_cursor_col - 1})}{print(#{disp_line})}{erase_eol()}{set_cursor_pos(1,#{disp_cursor_col})}", mock_rgn.buf )

      # try KEY_END
      #[    > v      v <    ]
      # >a1234x56789b123456789c123456789
      #        ^
      #[    > v      v <    ]
      # 456789
      #       ^
      mock_rgn.buf = ""
      assert_equal( 6, le.cursor_pos )
      le.accept(KEY_END)
      assert_equal( line_data.length, le.cursor_pos )
      assert_equal( repos_col_left, le.send(:disp_cursor_col) )
      disp_line = whole_line.slice(le.disp_ofst, term_cols)
      disp_cursor_col = ((prompt_str.length + le.cursor_pos) - le.disp_ofst) + 1
      assert_equal( "{set_cursor_pos(1,1)}{print(#{disp_line})}{erase_eol()}{set_cursor_pos(1,#{disp_cursor_col})}", mock_rgn.buf )

      # move left as far as we can without a repos      
      #[    > v      v <    ]
      # 456789
      #       ^
      #      ^
      mock_rgn.buf = ""
      assert_equal( line_data.length, le.cursor_pos )
      le.accept(KEY_LEFTARROW)
      assert_equal( "{cursor_left()}", mock_rgn.buf )
      assert_equal( repos_thresh + 1, le.send(:disp_cursor_col) )

      # one more leftarrow should cause a repos
      #[    > v      v <    ]
      # 456789
      #      ^
      #[    > v      v <    ]
      # 56789c123456789
      #     \________^
      mock_rgn.buf = ""
      prev_cursor_col = le.send(:disp_cursor_col)
      assert_equal( 6, prev_cursor_col )
      assert_equal( line_data.length - 1, le.cursor_pos )
      le.accept(KEY_LEFTARROW)
      assert_equal( line_data.length - 2, le.cursor_pos )
      assert_equal( whole_line.length - 15, le.disp_ofst)
      assert_equal( repos_col_right, le.send(:disp_cursor_col) )
      disp_line = whole_line.slice(le.disp_ofst, term_cols)
      disp_cursor_col = ((prompt_str.length + le.cursor_pos) - le.disp_ofst) + 1
      assert_equal( "{set_cursor_pos(1,1)}{print(#{disp_line})}{erase_eol()}{set_cursor_pos(1,#{disp_cursor_col})}", mock_rgn.buf )

      # try KEY_HOME
      #[    > v      v <    ]
      # 56789c123456789
      #              ^
      #[    > v      v <    ]
      # 012345678>a1234x56789b123456789c123456789
      #           ^
      mock_rgn.buf = ""
      le.accept(KEY_HOME)
      assert_equal( 0, le.cursor_pos )
      assert_equal( 0, le.disp_ofst)
      assert_equal( prompt_str.length + 1, le.send(:disp_cursor_col) )
      disp_line = whole_line.slice(le.disp_ofst, term_cols)
      disp_cursor_col = ((prompt_str.length + le.cursor_pos) - le.disp_ofst) + 1
      assert_equal( "{set_cursor_pos(1,1)}{print(#{disp_line})}{erase_eol()}{set_cursor_pos(1,#{disp_cursor_col})}", mock_rgn.buf )
      
      # special case: when cursor_pos goes to zero, force a repos
      #               if necessary to make sure the whole prompt
      #               is visible
      # first, set up conditions were the cursor going to zero
      # would not need to do a repos, without the special case in place
      le.instance_eval { @cursor_pos = 1 }
      le.instance_eval { @disp_ofst = 1 }
      #[    > v      v <    ]
      # 12345678>a1234x56789b123456789c123456789
      #           ^
      mock_rgn.buf = ""
      le.redraw
      assert_equal( 1, le.cursor_pos )
      assert_equal( 1, le.disp_ofst)
      disp_line = whole_line.slice(le.disp_ofst, term_cols)
      disp_cursor_col = ((prompt_str.length + le.cursor_pos) - le.disp_ofst) + 1
      assert_equal( "{set_cursor_pos(1,1)}{print(#{disp_line})}{erase_eol()}{set_cursor_pos(1,#{disp_cursor_col})}", mock_rgn.buf )
      # now, a leftarrow should force a repos to disp_ofst zero
      #[    > v      v <    ]
      # 012345678>a1234x56789b123456789c123456789
      #           ^
      mock_rgn.buf = ""
      le.accept(KEY_LEFTARROW)
      assert_equal( 0, le.cursor_pos )
      assert_equal( 0, le.disp_ofst)
      disp_line = whole_line.slice(le.disp_ofst, term_cols)
      disp_cursor_col = ((prompt_str.length + le.cursor_pos) - le.disp_ofst) + 1
      assert_equal( "{set_cursor_pos(1,1)}{print(#{disp_line})}{erase_eol()}{set_cursor_pos(1,#{disp_cursor_col})}", mock_rgn.buf )      
    end

    def test_delete_backspace
      term_cols = 20
      prompt_str = "012345678>"

      mock_rgn = MockOutputRegion.new(1, term_cols)
      le = LineEdit.new(mock_rgn)
      le.set_prompt(prompt_str)

      assert_equal( 0, le.cursor_pos )
      assert_equal( "", le.line_buf )

      # test backspace at leftmost does nothing
      mock_rgn.buf = ""
      le.accept(KEY_BACKSPACE)
      assert_equal( 0, le.cursor_pos )
      assert_equal( "", le.line_buf )
      assert_equal( "", le.line_buf )

      "abcde".each_byte {|ch| le.accept(ch) }      

      assert_equal( 5, le.cursor_pos )
      assert_equal( "abcde", le.line_buf )

      # test simple backspace from end of line (rubout)
      mock_rgn.buf = ""
      le.accept(KEY_BACKSPACE)
      assert_equal( 4, le.cursor_pos )
      assert_equal( "abcd", le.line_buf )
      assert_equal( "{backspace_rubout()}", mock_rgn.buf )

      # test backspace dragging text
      le.accept(KEY_LEFTARROW)
      assert_equal( 3, le.cursor_pos )
      assert_equal( "abcd", le.line_buf )
      #[    > v      v <    ]
      # 012345678>abcd
      #              ^
      mock_rgn.buf = ""
      le.accept(KEY_BACKSPACE)
      assert_equal( 2, le.cursor_pos )
      assert_equal( "abd", le.line_buf )
      assert_equal( "{set_cursor_pos(1,13)}{print(d)}{erase_eol()}{set_cursor_pos(1,13)}", mock_rgn.buf )
      
      # test KEY_DEL dragging text
      le.accept(KEY_LEFTARROW)
      #[    > v      v <    ]
      # 012345678>abd
      #            ^
      assert_equal( 1, le.cursor_pos )
      assert_equal( "abd", le.line_buf )
      mock_rgn.buf = ""
      le.accept(KEY_DEL)
      assert_equal( 1, le.cursor_pos )
      assert_equal( "ad", le.line_buf )
      assert_equal( "{set_cursor_pos(1,12)}{print(d)}{erase_eol()}{set_cursor_pos(1,12)}", mock_rgn.buf )
      
      # test KEY_DEL at end of line (still drag case, not bothering with rubout here)
      #[    > v      v <    ]
      # 012345678>ad
      #            ^
      mock_rgn.buf = ""
      le.accept(KEY_DEL)
      assert_equal( 1, le.cursor_pos )
      assert_equal( "a", le.line_buf )
      assert_equal( "{set_cursor_pos(1,12)}{erase_eol()}{set_cursor_pos(1,12)}", mock_rgn.buf )

      # test KEY_DEL past end of line (does nothing)
      #[    > v      v <    ]
      # 012345678>a
      #            ^
      mock_rgn.buf = ""
      le.accept(KEY_DEL)
      assert_equal( 1, le.cursor_pos )
      assert_equal( "a", le.line_buf )
      assert_equal( "", mock_rgn.buf )
    end

    def test_echo_off
      term_cols = 20
      prompt_str = "foo>"
      line_data = "bar"

      mock_rgn = MockOutputRegion.new(1, term_cols)
      le = LineEdit.new(mock_rgn)
      le.set_prompt(prompt_str)
      le.set_line_data(line_data)

      le.set_echo(false)
      mock_rgn.buf = ""
      le.redraw
      assert_equal( "{set_cursor_pos(1,1)}{print(foo>)}{erase_eol()}{set_cursor_pos(1,5)}", mock_rgn.buf )
    
      mock_rgn.buf = ""
      le.accept(?b)
      le.accept(?a)
      le.accept(?z)
      assert_equal( "barbaz", le.line_buf )
      assert_equal( "", mock_rgn.buf )
    end

  end
end



