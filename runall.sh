#!/bin/sh

for x in `cat dblist.txt`; do ./rundb.rb $x ; done

