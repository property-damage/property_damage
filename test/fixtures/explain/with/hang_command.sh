#!/bin/sh
# A stand-in for a command that never finishes. It reads all of standard
# input, starts a child that sleeps, records the child's pid and its own in
# $PD_DIR/pids (one pid per line, appended), and sleeps itself.
cat > /dev/null
sleep 300 &
echo "$!" >> "$PD_DIR/pids"
echo "$$" >> "$PD_DIR/pids"
sleep 300
