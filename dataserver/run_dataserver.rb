#!/usr/bin/env ruby

require 'eventmachine'
require 'update_server'
require 'query_server'


is_test = !! ARGV.delete("-test")
create_indices = !! ARGV.delete("--create-indices")
$run_update_server = ARGV.include? "update"
$run_query_server  = ARGV.include? "query"

abort("Usage: #$0 [-test] [--create-indices] [query / update]  # must specify at least query or update, may specify both") unless $run_update_server || $run_query_server


def init_db(testing, create_indices)
  if testing
    $DBG = true
    db_name = 'test-stats'
    destroy_flag = $run_update_server  # if only running query, leave existing db
  else
    db_name = 'q2stats'
    destroy_flag = false  # NEVER destroy in production
  end
  
  if PLATFORM =~ /linux/
    @db = Og.setup(
      :destroy => destroy_flag,
      :store => :postgresql,
      :name => db_name,
      :user => 'dorkbuster'
    )
  else
    @db = Og.setup(
      :destroy => destroy_flag,
      :store => :sqlite,
      :name => db_name
    )
  end

  PlayerIPStats.create_all_indices if create_indices

  if testing
    $DBG = false
  end
end

create_indices = true if is_test  # for now, just always create them if testing
init_db(is_test, create_indices)

EventMachine::run {
  if $run_update_server
    if is_test
      host, port = '127.0.0.1', 12345
    else
      host, port = Dataserver::UPDATE_SERVER_IP, Dataserver::UPDATE_SERVER_PORT
    end
    warn("Starting update server #{host}:#{port}...")
    Dataserver::start_update_server(host, port)
  end

  if $run_query_server
    if is_test
      host, port = '127.0.0.1', 12346
    else
      host, port = Dataserver::QUERY_SERVER_IP, Dataserver::QUERY_SERVER_PORT
    end
    warn("Starting query server #{host}:#{port}...")
    Dataserver::start_query_server(host, port)
  end
  
  if is_test
    $stdout.sync = true
    $stdout.puts "DATASERVER_READY"
  end
}


