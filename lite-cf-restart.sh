#!/bin/bash
# Restart the agsbx-lite cloudflared process in place, reusing its exact
# original command line read from /proc/<pid>/cmdline. Use after its binary
# was upgraded on disk while the old process kept running the deleted copy.
set -u
PID="$(pgrep -f 'agsbx-lite/cloudflared' | head -n1)"
if [ -z "$PID" ]; then echo "FAIL: no agsbx-lite cloudflared process running"; exit 1; fi
EXE="$(readlink /proc/$PID/exe 2>/dev/null | sed 's/ (deleted)$//')"
echo "found lite cloudflared pid=$PID exe=$EXE"
echo "on-disk version now: $("$EXE" --version 2>/dev/null)"
mapfile -d '' ARGS < /proc/$PID/cmdline
if [ "${#ARGS[@]}" -lt 2 ]; then echo "FAIL: could not read cmdline of pid $PID"; exit 1; fi
echo "captured ${#ARGS[@]} arguments, restarting the process"
kill "$PID" 2>/dev/null
for i in $(seq 1 15); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
if kill -0 "$PID" 2>/dev/null; then echo "graceful exit too slow, forcing"; kill -9 "$PID"; sleep 1; fi
cd /
nohup "${ARGS[@]}" >> /root/agsbx-lite/cloudflared-restart.log 2>&1 &
sleep 5
NEWPID="$(pgrep -f 'agsbx-lite/cloudflared' | head -n1)"
if [ -z "$NEWPID" ]; then
  echo "FAIL: lite cloudflared did not come back; last log lines:"
  tail -5 /root/agsbx-lite/cloudflared-restart.log 2>/dev/null
  exit 1
fi
NEWEXE="$(readlink /proc/$NEWPID/exe 2>/dev/null)"
echo "new pid=$NEWPID exe=$NEWEXE"
case "$NEWEXE" in
  *" (deleted)") echo "FAIL: new process still on a deleted binary" ;;
  *) echo "new process version: $("$NEWEXE" --version 2>/dev/null)"; echo "PASS: lite cloudflared restarted on the on-disk binary" ;;
esac
