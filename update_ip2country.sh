#!/bin/sh

# warning, don't download this more a couple times
# an hour, or they auto-blacklist

mv ip2country.csv ip2country.csv.bak
wget "http://software77.net/geo-ip/?DL=1" -O ip2country.csv.gz
gunzip ip2country.csv.gz

