#!/bin/bash
# Fix-up: upgrade the cloudflared copies that RUNNING processes actually use,
# then restart their owning systemd services and verify by /proc/<pid>/exe.
set -u
TARGET="2026.10.2"
echo "=== cloudflared in-use upgrade to $TARGET on $(hostname) ==="

# 1) Get a verified copy of the target binary
case "$(uname -m)" in
  x86_64|amd64) ASSET="cloudflared-linux-amd64" ;;
  aarch64|arm64) ASSET="cloudflared-linux-arm64" ;;
  *) echo "FAIL: unsupported arch $(uname -m)"; exit 1 ;;
esac
TMP="/tmp/cloudflared-$TARGET"
ver_of() { "$1" --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -n1; }
if [ "$(ver_of "$TMP")" != "$TARGET" ]; then
  if ! curl -L --fail --max-time 180 -o "$TMP" "https://github.com/cloudflare/cloudflared/releases/download/$TARGET/$ASSET"; then
    echo "FAIL: download failed"; exit 1
  fi
  chmod +x "$TMP"
fi
if [ "$(ver_of "$TMP")" != "$TARGET" ]; then echo "FAIL: temp binary is not $TARGET"; exit 1; fi
echo "verified source binary: $TARGET"

# 2) Discover running cloudflared processes: exe path + systemd unit
PIDS="$(pgrep -f cloudflared)"
if [ -z "$PIDS" ]; then echo "FAIL: no cloudflared process running"; exit 1; fi
declare -A DONE_PATH DONE_UNIT
for PID in $PIDS; do
  EXE="$(readlink /proc/$PID/exe 2>/dev/null | sed 's/ (deleted)$//')"
  UNIT="$(grep -oE '[^/]+\.service' /proc/$PID/cgroup 2>/dev/null | head -n1)"
  echo "pid $PID exe=$EXE unit=${UNIT:-none}"
  if [ -n "$EXE" ] && [ -z "${DONE_PATH[$EXE]:-}" ]; then
    DONE_PATH[$EXE]=1
    VER="$(ver_of "$EXE")"
    if [ "$VER" = "$TARGET" ]; then
      echo "  $EXE already at $TARGET"
    else
      if [ ! -f "$EXE.bak-pre-$TARGET" ]; then cp -a "$EXE" "$EXE.bak-pre-$TARGET"; fi
      cp -f "$TMP" "$EXE"; chmod +x "$EXE"
      echo "  $EXE upgraded: ${VER:-unknown} -> $TARGET"
    fi
  fi
  case "$UNIT" in
    ""|cron.service|user@*.service|session-*.scope) [ -n "$UNIT" ] && echo "  note: not restarting $UNIT (not a dedicated service)" ;;
    *) DONE_UNIT[$UNIT]=1 ;;
  esac
done

# 3) Restart the owning services
for U in "${!DONE_UNIT[@]}"; do
  echo "restarting $U"
  systemctl restart "$U" || echo "WARN: restart of $U failed"
done
sleep 5

# 4) Verify every running cloudflared now executes the target version
FAIL=0
for PID in $(pgrep -f cloudflared); do
  EXE="$(readlink /proc/$PID/exe 2>/dev/null)"
  case "$EXE" in
    *" (deleted)") echo "pid $PID still running a deleted old binary: $EXE"; FAIL=1; continue ;;
  esac
  VER="$(ver_of "$EXE")"
  echo "pid $PID running $EXE version ${VER:-unknown}"
  if [ "$VER" != "$TARGET" ]; then FAIL=1; fi
done
if [ "$FAIL" = 0 ]; then echo "PASS: all running cloudflared processes are on $TARGET"; else echo "FAIL: see lines above"; fi
echo "=== done on $(hostname) ==="
