#!/usr/local/bin/ruby -w
#
# author: Bill Kelly <billk@cts.com> 16 Nov 02

raise "terminal.rb is going away... who is including me?"

require 'socket'
require 'thread'
require 'fastthread'

module InteractiveBufferedTerminalIO

  # Intended to extend a TCPSocket, i.e.
  # sock.extend(InteractiveBufferedTerminalIO)
  #
  # The extended socket is still well-behaved with respect
  # to select().

  Backspace = "\b"
  CarriageReturn = "\r"
  Del = "\177"
  Erase = "\b \b"
  Linefeed = "\n"
  Null = "\000"
  Space = " "
  Tab = "\t"

  # Call after extending socket, before invoking other
  # terminal funcs...
  # Prompt may be a string, or a proc that returns a string.
  def terminal_init(prompt_str_or_proc = ">", echo = true)
    @term_mutex = Mutex.new
    @term_write_signal = ConditionVariable.new
    @term_write_sock = self.dup
    @term_prompt = prompt_str_or_proc
    @term_prompted = nil
    @term_echo = echo
    @term_line_buf = ""
    @term_read_buf = ""
    @term_write_buf = ""
    @term_prev_ch = Null
    @term_eof = false
    @term_bkgnd_write_queue = ""
    @term_bkgnd_write_th = Thread.new { terminal_bkgnd_write_task }
    @term_init = true
    terminal_output_prompt
  end

  def terminal_final
    @term_mutex.synchronize {
      @term_eof = true
      @term_write_signal.signal
    }
    done = @term_bkgnd_write_th.join(1.0)
    if !done
      Thread.kill(@term_bkgnd_write_th)
    end
    @term_write_sock.close
  end

  # Read line from client (returns nil if full line not received yet.)
  # Handles echo of client characters back to client, including
  # backspace handling.
  def terminal_readln
    terminal_buffered_read
    until @term_read_buf.empty?
      ch = @term_read_buf.slice!(0..0)
      ignore = (ch == Linefeed  &&  @term_prev_ch == CarriageReturn)
      @term_prev_ch = ch
      unless ignore
        ch = Linefeed if ch == CarriageReturn  # i hate carriage returns!! :)
        ch = Space if ch == Tab
        ch = Backspace if ch == Del
        terminal_process_input_ch(ch)
        if ch == Linefeed
          terminal_flush_write
          terminal_output_prompt
          line = @term_line_buf
          @term_line_buf = ""
          return line
        end
      end
    end
    terminal_write("")  # umprompt/flush/prompt if no chars in line_buf
    nil
  end

  # Buffered write to client.  Handles erasure and redraw of prompt
  # as needed.  Buffers writes if user has begun typing a line,
  # until user hits enter, or backspaces the line out.
  def terminal_write(dat)
    @term_write_buf << dat
    if @term_line_buf.empty?
      terminal_unprompt
      terminal_flush_write
      terminal_output_prompt
    end
  end

  def terminal_puts(str)
    terminal_write("#{str}\n")
  end

  # Returns true if client appears to have closed the connection on us.
  # (Implementation slightly cheesy, but perhaps adequate.)
  def terminal_eof?
    @term_eof
  end

  # Change prompt.  Redisplays instantly, unless user busy typing
  # a line. 
  def terminal_set_prompt(str_or_proc)
    if (@term_prompt != str_or_proc)
      terminal_unprompt if @term_line_buf.empty?
      @term_prompt = str_or_proc
      terminal_output_prompt if @term_line_buf.empty?
    end
  end

  def terminal_set_echo(flag)
    @term_echo = flag
  end

  private

  def terminal_process_input_ch(ch)
    case ch
      when Backspace
        unless @term_line_buf.empty?
          @term_line_buf.slice!(-1..-1)
          send_string(Erase) if @term_echo
        end
      when ("\000".."\011"), ("\013".."\037"), ("\200".."\377")
        # ignore...
      else
        send_string(ch) if @term_echo
        @term_line_buf << ch unless ch == Linefeed
    end
  end

  def terminal_buffered_read
    begin 
      if Kernel.select([self], nil, nil, 0)
        dat = self.recv(65536)
        if !dat || dat.empty?
          @term_eof = true
        else
          @term_read_buf << dat
        end
      end
    rescue IOError, SystemCallError
      @term_eof = true
    end
  end

  def terminal_output_prompt
    @term_prompted = terminal_prompt_str
    send_string(@term_prompted)
  end

  def terminal_unprompt
    if @term_prompted
      send_string(Erase * @term_prompted.length)
      @term_prompted = nil
    end
  end

  def terminal_prompt_str
    if @term_prompt.respond_to? :call
      @term_prompt.call
    else
      @term_prompt
    end
  end

  def terminal_flush_write
    unless @term_write_buf.empty?
      send_string(@term_write_buf)
      @term_write_buf = ""
    end
  end


# def send_string(str)
#   str = str.gsub(/\n/, "\r\n")
#   begin
#     while str.length > 0
#       sent = self.send(str, 0)
#       str = str[sent..-1]
#     end
#   rescue IOError, SystemCallError
#     @term_eof = true
#   end
# end


  def send_string(str)
    str = str.gsub(/\n/, "\r\n")
    @term_mutex.synchronize {
      @term_bkgnd_write_queue << str
      @term_write_signal.signal
    }
  end

  def terminal_bkgnd_write_task
    _eof = false
    while not _eof
      _str = ""
      @term_mutex.synchronize {
        _eof = @term_eof
        unless _eof
          @term_write_signal.wait(@term_mutex) if @term_bkgnd_write_queue.empty?
          _str << @term_bkgnd_write_queue
          @term_bkgnd_write_queue = ""
          _eof = @term_eof
        end
      }
      terminal_bkgnd_write_string(_str) unless _eof
    end
  end
  
  def terminal_bkgnd_write_string(str)
    begin
      while str.length > 0
        if Kernel.select(nil, [@term_write_sock], nil, nil)
          sent = @term_write_sock.send(str, 0)
          str = str[sent..-1]
        else
          @term_mutex.synchronize { @term_eof = true }
          return
        end
      end
    rescue IOError, SystemCallError
      @term_mutex.synchronize { @term_eof = true }
    end
  end

end



if $0 == __FILE__

  # testing...
  $tcp_server_port = 12345
  puts "Accepting test connection on localhost:#{$tcp_server_port}..."
  $tcp_server = TCPServer.new($tcp_server_port)
  if client = $tcp_server.accept
    client.extend(InteractiveBufferedTerminalIO)
    client.terminal_init("howdy>")
    puts "[before loop]"
    until client.terminal_eof?
     puts "[before select]"
      if select([client], nil, nil, 3)
       puts "[before readln]"
        line = client.terminal_readln
        if line
          client.terminal_write("Hi! got: #{line}")
        end
      end
      client.terminal_write(Time.now.strftime("%H:%M:%S some data...\n"))
    end
    client.terminal_final
    puts "[after eof]"
  end

end


