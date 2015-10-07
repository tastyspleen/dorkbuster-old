#!/bin/sh

SV="$1"

./killdroid.rb $SV wallfly && ./dbcast.rb -$SV 'shutdown_db!' && ./rundb.rb $SV

