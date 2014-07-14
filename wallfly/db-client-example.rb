
require 'thread'
require 'fastthread'
require 'timeout'
require 'dorkbuster-client'

class DbClientExample

  def initialize(sock, db_username, db_password)
    @myname = db_username
    @db = DorkBusterClient.new(sock, db_username, db_password)
    @done = false
  end

  def close
    @db.close
  end

  def login
    @db.login
  end

  def reply(str)
    @db.speak(str)
  end

  def run
    while not @done
      @db.get_parse_new_data
      while dbline = @db.next_parsed_line
        puts "db_event: [#{dbline.kind}] time=#{dbline.time} speaker=#{dbline.speaker} cmd=#{dbline.cmd}"
      end
      @db.wait_new_data unless @done
    end
  end

end


dbsock = TCPSocket.new("db.bwk.homeip.net", "27999")
ex = DbClientExample.new(dbsock, "fluff", "testAI")
ex.login
ex.run



