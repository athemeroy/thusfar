#!/bin/sh
# Manage a background AI-processing run for one book with a pid file.
#   scripts/bg.sh start data/books/<id> [extra args]   scripts/bg.sh stop data/books/<id>   scripts/bg.sh status data/books/<id>
# (Never pkill by pattern: the calling shell's own command line matches and gets killed.)
set -e
cd "$(dirname "$0")/.."
cmd=$1; root=$2; shift 2 || true
pidf="$root/work/run.pid"
mkdir -p "$root/work"
running() { [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; }
case "$cmd" in
  start)
    if running; then echo "already running: $(cat "$pidf")"; exit 0; fi
    nohup setsid python3 -u -m pipeline.run "$root" "$@" >> "$root/work/run.log" 2>&1 < /dev/null &
    echo $! > "$pidf"; echo "started $(cat "$pidf")" ;;
  stop)
    if running; then kill "$(cat "$pidf")"; echo stopped; else echo "not running"; fi; rm -f "$pidf" ;;
  status)
    if running; then echo "running $(cat "$pidf")"; else echo "not running"; fi; tail -3 "$root/work/run.log" ;;
esac
