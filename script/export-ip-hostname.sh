#!/bin/bash

TAB=$'\t'
DATE=`date "+%y%m%d"`
DB="q2stats"
PFLAGS="--quiet --tuples-only --no-align -U dorkbuster -d $DB"

psql --field-separator "$TAB" $PFLAGS -c "SELECT ip, hostname FROM ogplayeripstats_iphost ORDER BY ip"

