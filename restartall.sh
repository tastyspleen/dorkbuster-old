#!/bin/sh

for x in `cat dblist.txt`; do ./dbcast.rb -$x "^9restarting all dbs..." 'shutdown_db!' ; sleep 5 ; ./rundb.rb $x ; done

