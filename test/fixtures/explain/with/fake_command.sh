#!/bin/sh
# A stand-in for a model command. It reads all of standard input, keeps a copy
# in $PD_DIR/stdin.N for call number N, and prints $PD_DIR/answer.N for that
# call. It exits with $PD_STATUS (default 0) and writes $PD_NOISE to standard
# error when that is set.
n=$(cat "$PD_DIR/count" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$PD_DIR/count"
cat > "$PD_DIR/stdin.$n"
[ -n "$PD_NOISE" ] && echo "$PD_NOISE" >&2
cat "$PD_DIR/answer.$n" 2>/dev/null
exit "${PD_STATUS:-0}"
