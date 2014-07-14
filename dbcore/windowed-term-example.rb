#
# Example telnet server showing use of windowed terminal
# classes.
#
# Copyright (c) 2006 Bill Kelly. All Rights Reserved.
# This code may be modified and distributed under either Ruby's
# license or the Library GNU Public License (LGPL).
#
# The copyright holder makes no representations about the
# suitability of this software for any purpose. It is provided
# "as is" without express or implied warranty.
#
# THE COPYRIGHT HOLDERS DISCLAIM ALL WARRANTIES WITH REGARD TO
# THIS SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS, IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR
# ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
# AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
# OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

require 'thread'
require 'fastthread'
require 'timeout'
require 'dbcore/recursive-mutex'
require 'dbcore/global-signal'
require 'dbcore/term-keys'
require 'dbcore/windowed-term'
require 'dbcore/line-edit'
require 'dbcore/dbclient'


class WindowedClientHandler

  MIN_ROWS = 12

  attr_reader :console, :window_init_ok

  def initialize(client_sock, global_signal)
    @windowed = false
    @bufio = BufferedIO.new(client_sock, global_signal)
    @termio = ANSITermIO.new(@bufio)
    @term = WindowedTerminal.new(@termio)
    @dyn_rgn = OutputRegion.new(@term)
    @chat_rgn = OutputRegion.new(@term)
    @input_rgn = OutputRegion.new(@term)
    @chatscroller = Backscroller.new(@chat_rgn)
    @console = DBWindowedConsole.new(@term, @input_rgn)
    @console.key_hook(TermKeys::KEY_PGUP) { @chatscroller.pgup; @input_rgn.focus }
    @console.key_hook(TermKeys::KEY_PGDN) { @chatscroller.pgdn; @input_rgn.focus }
    @console.key_hook(?\C-y) { @chatscroller.pgup; @input_rgn.focus }
    @console.key_hook(?\C-v) { @chatscroller.pgdn; @input_rgn.focus }
    @prompt = ""
    @window_init_ok = init_window_regions
  end

  def close
    @console.close
    @term.close
    @termio.close
    @bufio.close
  end

  def eof
    @term.eof
  end

  def set_prompt(str_or_proc)
    @console.set_prompt(@prompt = str_or_proc)
  end
  
  def set_echo(flag)
    @console.set_echo(flag)
  end  

  def dyn_puts(str)
    @dyn_rgn.cr
    @dyn_rgn.print(str)
    @input_rgn.focus
  end

  def chat_puts(str)
    @chatscroller.puts(str)
    @input_rgn.focus
  end

  def init_window_regions
    begin
      @term.ask_term_size
    rescue Timeout::Error
      @term.puts(ANSI.red(
        "Your terminal wouldn't tell me its size. "+
        "You may need to put your terminal into "+
        "character mode (mode ch) manually, and "+
        "try again."))
      return false
    end

    if @term.term_rows < MIN_ROWS
      @term.puts(ANSI.red(
        "Your terminal reported its size as #{@term.term_rows} rows, "+
        "but a minimum of #{MIN_ROWS} are required. "+
        "You might try resizing your window and reconnecting."))
      return false
    end

    input_height = 1
    avail_rows = @term.term_rows - input_height
    dyn_height = avail_rows / 2
    chat_height = avail_rows - dyn_height

    at_row = 1
    @dyn_rgn.set_scroll_region(at_row, at_row + (dyn_height - 1))
    at_row += dyn_height
    @chat_rgn.set_scroll_region(at_row, at_row + (chat_height - 1))
    at_row += chat_height
    @input_rgn.set_scroll_region(at_row, at_row + (input_height - 1))

    @dyn_rgn.set_color(ANSI::Reset, ANSI::BGYellow)
    @dyn_rgn.clear
    @chat_rgn.set_color(ANSI::Reset, ANSI::BGGreen)
    @chat_rgn.clear
    @input_rgn.set_color(ANSI::Bright, ANSI::Yellow, ANSI::BGBlue)
    @input_rgn.clear
    
    @dyn_rgn.home_cursor
    @chat_rgn.home_cursor
    @input_rgn.home_cursor
    
    true
  end

end



class WindowedTelnetServer

  def initialize(listen_port)
    @listen_port = listen_port
    @global_signal = GlobalSignal.new
    @clients = []
    @moribund_clients = []
    @incoming_tcp_clients = Queue.new
  end

  def run
    @tcp_server = TCPServer.new(@listen_port)
    @background_accept_th = Thread.new { background_accept_clients }
    loop do
      begin
        # The timeout is to allow us to send something
        # dynamic to the clients on a periodic basis
        @global_signal.timed_wait(1.0)
      rescue Timeout::Error
      end
      induct_new_clients
      process_client_input
      delete_moribund_clients
      send_something_dynamic_to_clients
    end
  end

  private

  def induct_new_clients
    until @incoming_tcp_clients.empty?
      cl_sock = @incoming_tcp_clients.pop
      cl = WindowedClientHandler.new(cl_sock, @global_signal)
      if cl.window_init_ok
        cl.set_prompt "sample prompt>"
        send_hello_msg(cl)
        @clients << cl
      else
        sleep 5  # kludge: give user time to read error message in case his window closes
        cl.close
      end
    end
  end

  def delete_moribund_clients
    @moribund_clients.each do |cl|
      @clients.delete cl
      cl.close
    end
    @moribund_clients.clear
  end
  
  def process_client_input
    @clients.each do |cl|
      if cl.eof
        @moribund_clients << cl
      else
        while (line = cl.console.readln)
          do_something_with_client_input(cl, line)
        end
      end
    end
  end

  def do_something_with_client_input(cl, line)
    # let's just echo what the client typed, to all clients
    @clients.each do |cl|
      cl.chat_puts line
    end
  end

  def send_something_dynamic_to_clients
    @clients.each do |cl|
      cl.dyn_puts Time.now.to_s
    end
  end

  def background_accept_clients
    loop do
      begin
        accept_client
      rescue Exception => ex
        log("accept_client exception #{ex.inspect}")
      end
    end
  end
  
  def accept_client
    cl_sock = @tcp_server.accept
    if cl_sock
      begin
        cl_sock.setsockopt(Socket::SOL_TCP, Socket::TCP_NODELAY, 1) if defined? Socket::SOL_TCP
      rescue IOError, SystemCallError, SocketError
        cl_sock.close
      else
        @incoming_tcp_clients.push cl_sock
        @global_signal.signal
      end
    end
  end

  def send_hello_msg(cl)
    cl.chat_puts(ANSI.color(ANSI::Magenta, ANSI::BGGreen) + "Hello!")
    cl.chat_puts(ANSI.color(ANSI::Blue, ANSI::BGGreen) +
      "In this window, chat text entered is echoed to all "+
      "connected clients.  PgUp/PgDn should work here, "+
      "but if not, try Ctrl-Y/Ctrl-V.  Arrow keys and "+
      "insert/delete should work for line-editing while "+
      "entering text, and up/down arrow should scroll "+
      "through history of lines typed.  Ctrl-U should "+
      "clear the current line of text being entered.  "+
      "If various keys don't work, then my key mapping "+
      "table probably doesn't cover your particular "+
      "terminal.")
    cl.chat_puts(ANSI.color(ANSI::White, ANSI::BGGreen))
  end

  def log(msg)
    $stderr.puts msg
  end
end


port = 12345
puts "Listening on port #{port}..."
sv = WindowedTelnetServer.new(port)
sv.run


