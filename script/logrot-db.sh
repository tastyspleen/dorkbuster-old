#!/bin/bash

NICK=$1
DATE=`date '+%y%m%d'`
# DATE="121231"

if [ ! -d "sv/$NICK" ]; then
  echo "sv/$NICK not found" >&2
  exit 1
fi

./dbcast.rb -$NICK 'shutdown_db!'
rm -f sv/$NICK/*.pid

for logname in db.log wallfly.log ; do
  if [ -L "sv/$NICK/$logname" ]; then
    echo "SKIPPING symlinked logfile sv/$NICK/$logname"
  elif [ -f "sv/$NICK/$logname" ]; then
    if [ -f "sv/$NICK/$logname.$DATE" ]; then
      echo "SKIPPING sv/$NICK/$logname, won't overwrite existing sv/$NICK/$logname.$DATE" >&2
    else
      mv sv/$NICK/$logname sv/$NICK/$logname.$DATE
    fi
  fi
done

./rundb.rb $NICK

