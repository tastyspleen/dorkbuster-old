
require 'socket'
require 'timeout'
require 'dataserver_config'  # just for the host/port constants

# NOTE:
# We're not using eventmachine for the client, here,
# since dorkbuster is currently not eventmachine-based.


class QueryClient

  TOTAL = "__total__"

  def initialize(logger, host=Dataserver::QUERY_SERVER_IP, port=Dataserver::QUERY_SERVER_PORT)
    @logger = logger
    @host, @port = host, port
    @query_sock = nil
  end

  def connect
    @query_sock = TCPSocket.new(@host, @port)
  end

  def close
    if sock = @query_sock
      begin
        timeout(1.0) { sock.puts "quit" rescue nil }
      rescue Timeout::Error
      end
      sock.close rescue nil
      @query_sock = nil
    end
  end

  def aliases_for_ip(ip, limit=100)
    line = ['aliases_for_ip', ip, limit].join("\t")
    rows = transact(line)
    rows.first
  end

  def playerseen_grep(search_str, limit=10)
    line = ['playerseen_grep', search_str, limit].join("\t")
    rows = transact(line)
  end

  def frag_total(dbname, inflictor, victim, method_str, servername, date)
    line = ['frag_total', dbname, inflictor, victim, method_str, servername, date.to_s].join("\t")
    rows = transact(line)
    rows.first[0].to_i
  end  

  def frag_list(dbname, inflictor, victim, method_str, servername, date, limit=10)
    line = ['frag_list', dbname, inflictor, victim, method_str, servername, date.to_s, limit].join("\t")
    rows = transact(line)
  end

  def suicide_total(dbname, victim, method_str, servername, date)
    line = ['suicide_total', dbname, victim, method_str, servername, date.to_s].join("\t")
    rows = transact(line)
    rows.first[0].to_i
  end  

  def suicide_list(dbname, victim, method_str, servername, date, limit=10)
    line = ['suicide_list', dbname, victim, method_str, servername, date.to_s, limit].join("\t")
    rows = transact(line)
  end

  protected

  # If query fails with an error code, just log it and return
  # an empty result set.
  # If we get an EOF or an exception, close the connection.
  # (We will attempt to re-open the connection on the next
  # transact.)
  def transact(line)
    rows = []
    begin
      connect unless @query_sock
      @query_sock.puts line
      rows = get_resp(@query_sock)
      if rows.empty?  # hit EOF, or error
        close
      else
        resp = rows.shift
        unless resp[0] =~ /\A200 /
          @logger.log("QueryClient: query #{line.inspect} failed with error #{resp.inspect}")
          rows = []
        end
      end
    rescue Exception => ex
      @logger.log("QueryClient: caught exception on query #{line.inspect} - #{ex.inspect}")
      close
    end
    rows
  end

  def get_resp(sock)
    rows = []
    begin
      line = sock.gets
      end_resp = line.nil? || line.empty? || line == "\n"
      rows << line.chop.split(/\t/) unless end_resp
    end until end_resp
    rows
  end

end


