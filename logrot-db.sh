#!/bin/bash

NICK=$1
DATE=`date '+%y%m%d'`
DATE="121231"

if [ ! -d "sv/$NICK" ]; then
  echo "sv/$NICK not found" >&2
  exit 1
fi

./dbcast.rb -$NICK 'shutdown_db!'
rm -f sv/$NICK/*.pid
mv sv/$NICK/db.log sv/$NICK/db.log.$DATE 
mv sv/$NICK/wallfly.log sv/$NICK/wallfly.log.$DATE 
./rundb.rb $NICK

