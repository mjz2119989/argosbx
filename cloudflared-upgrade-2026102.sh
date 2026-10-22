#!/bin/bash
# cloudflared security upgrade to 2026.10.2 (eMudhra incident fix)
# Works on RN / HD / CC. Idempotent. Verifies the downloaded binary BEFORE installing.
set -u
TARGET="2026.10.2"
echo "=== cloudflared upgrade to $TARGET ==="
echo "host: $(hostname)  ip: $(curl -s --max-time 8 https://api.ipify.org || echo unknown)  arch: $(uname -m)"

# 1) Locate the cloudflared binary
BIN=""
for p in "$(command -v cloudflared 2>/dev/null)" /root/agsbx/cloudflared /usr/local/bin/cloudflared /usr/bin/cloudflared; do
  if [ -n "$p" ] && [ -x "$p" ]; then BIN="$p"; break; fi
done
if [ -z "$BIN" ]; then
  FOUND="$(find /root /usr/local /opt -maxdepth 4 -name cloudflared -type f 2>/dev/null | head -n1)"
  if [ -n "$FOUND" ]; then BIN="$FOUND"; fi
fi
if [ -z "$BIN" ]; then echo "FAIL: cloudflared binary not found on this machine"; exit 1; fi
echo "binary: $BIN"

# 2) Current version
CUR="$("$BIN" --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -n1)"
echo "current version: ${CUR:-unknown}"
if [ "$CUR" = "$TARGET" ]; then echo "PASS: already at $TARGET, nothing to do"; exit 0; fi

# 3) Download the target build and verify it BEFORE installing
case "$(uname -m)" in
  x86_64|amd64) ASSET="cloudflared-linux-amd64" ;;
  aarch64|arm64) ASSET="cloudflared-linux-arm64" ;;
  *) echo "FAIL: unsupported arch $(uname -m)"; exit 1 ;;
esac
TMP="/tmp/cloudflared-$TARGET"
if ! curl -L --fail --max-time 180 -o "$TMP" "https://github.com/cloudflare/cloudflared/releases/download/$TARGET/$ASSET"; then
  echo "FAIL: download failed"; exit 1
fi
chmod +x "$TMP"
NEWVER="$("$TMP" --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -n1)"
if [ "$NEWVER" != "$TARGET" ]; then
  echo "FAIL: downloaded binary reports version ${NEWVER:-none}, expected $TARGET - NOT installing"
  exit 1
fi
echo "downloaded binary verified: $NEWVER"

# 4) Back up once, then install
if [ ! -f "$BIN.bak-pre-$TARGET" ]; then cp -a "$BIN" "$BIN.bak-pre-$TARGET"; fi
cp -f "$TMP" "$BIN"
chmod +x "$BIN"
echo "installed, now reports: $("$BIN" --version 2>/dev/null)"

# 5) Restart the tunnel service
UNIT=""
for u in argo cloudflared cloudflared-tunnel; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^$u\.service"; then UNIT="$u"; break; fi
done
if [ -z "$UNIT" ]; then
  UNIT="$(systemctl list-units --type=service --all 2>/dev/null | grep -iE 'argo|cloudflared' | awk '{print $1}' | head -n1 | sed 's/\.service$//')"
fi
if [ -n "$UNIT" ]; then
  systemctl restart "$UNIT" && sleep 3
  if systemctl is-active --quiet "$UNIT"; then
    echo "service $UNIT restarted and active"
  else
    echo "WARN: service $UNIT not active after restart - check: systemctl status $UNIT"
  fi
else
  echo "WARN: no systemd unit found for cloudflared - binary upgraded, tunnel process needs a manual restart"
fi
echo "=== done: ${CUR:-unknown} -> $TARGET on $(hostname) ==="
