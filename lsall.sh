#!/bin/sh

echo -n "dorkbuster: " && ps aux --cols 9999 | grep -v grep | grep "ruby dorkbuster.rb" | wc -l
echo -n "hal.rb:     " && ps aux --cols 9999 | grep -v grep | grep "hal.rb" | wc -l
echo -n "wallfly.rb: " && ps aux --cols 9999 | grep -v grep | grep "wallfly.rb" | wc -l
echo -n "q2wallfly:  " && ps aux --cols 9999 | grep -v grep | grep "q2wallfly" | wc -l

