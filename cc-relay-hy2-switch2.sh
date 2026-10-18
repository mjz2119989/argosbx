#!/bin/bash
# cc-relay-hy2-switch2.sh — v2 桥接方案：让 CC 中转的最后一跳改走 Hy2
# 背景：xray 本身不认 hysteria2 传输层（v1 已验证并自动还原）。改走已实测可行的桥：
#   xray-relay 出站 -> 本地 socks(127.0.0.1:11099) -> sing-box 桥 -> Hy2 -> RN:35444
# 安全网同 v1：备份只生成一次；桥先单独验通才动 xray；xray 校验不过不重启；
# 重启后回环不通 -> 还原 xray 配置、停桥、复验恢复。
set -u
CFG=/etc/xray-relay/config.json
BAK=/etc/xray-relay/config.json.bak-pre-hy2switch
XRAY=/usr/local/bin/xray-relay
RN_IP=204.152.192.153
BR_DIR=/etc/relay-hy2
BR_CFG=$BR_DIR/bridge.json
BR_UNIT=relay-hy2-bridge
SB=""
for p in /root/agsbx-lite/sing-box /usr/local/bin/sing-box /usr/local/bin/sing-box-relay; do
  [ -x "$p" ] && SB="$p" && break
done
[ -z "$SB" ] && SB=$(command -v sing-box || true)

looptest() {
  local C=/tmp/relay-loop-sb.json L=/tmp/relay-loop-sb.log
  cat > "$C" <<'EOF'
{
  "log": { "level": "warn" },
  "inbounds": [ { "type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": 11098 } ],
  "outbounds": [
    {
      "type": "vless", "tag": "to-relay",
      "server": "127.0.0.1", "server_port": 24443,
      "uuid": "71bf3d9f-01d6-4490-9164-2dfbf6cc24be",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true, "server_name": "apple.com",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "bnoINAF8QJEa9njpdyuBQaaAVNmlj1s8JnPp4Q8-_F4", "short_id": "905ffdd2" }
      }
    }
  ],
  "route": { "final": "to-relay" }
}
EOF
  "$SB" run -c "$C" > "$L" 2>&1 &
  local P=$!
  sleep 3
  local IP
  IP=$(curl -s --max-time 20 --socks5-hostname 127.0.0.1:11098 https://api.ipify.org || true)
  kill $P 2>/dev/null; wait $P 2>/dev/null
  rm -f "$C"
  echo "回环出口 IP: ${IP:-（空）}"
  [ "$IP" = "$RN_IP" ]
}

full_rollback() {
  echo ">>> 自动回滚：还原 xray 出站并停桥"
  cp "$BAK" "$CFG"
  systemctl restart xray-relay
  sleep 2
  systemctl stop $BR_UNIT 2>/dev/null || true
  systemctl disable $BR_UNIT 2>/dev/null || true
  systemctl is-active xray-relay || true
}

echo "=== 1. 前置检查 ==="
systemctl is-active xray-relay || { echo "FAIL: xray-relay 不在运行，中止（未改动）"; exit 1; }
[ -n "$SB" ] || { echo "FAIL: 找不到 sing-box，中止（未改动）"; exit 1; }
grep -q '15207' "$CFG" && grep -q 'CGMnKHAlqN1CeOBERPVFa' "$CFG" || { echo "FAIL: 现行出站不是预期的 Reality 落地，中止（未改动）"; exit 1; }
echo "现行出站确认为 Reality -> RN:15207；sing-box: $SB"

echo "=== 2. 备份（只生成一次）==="
[ -f "$BAK" ] || cp "$CFG" "$BAK"
ls -l "$BAK"

echo "=== 3. 建 Hy2 桥并单独验通 ==="
mkdir -p "$BR_DIR"
cat > "$BR_CFG" <<'EOF'
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    { "type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": 11099 }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "to-rn-hy2",
      "server": "204.152.192.153",
      "server_port": 35444,
      "password": "50c4431f-8cf1-4ddf-9332-b0658d0a383b",
      "up_mbps": 100,
      "down_mbps": 100,
      "tls": { "enabled": true, "server_name": "www.bing.com", "alpn": ["h3"], "insecure": true }
    }
  ],
  "route": { "final": "to-rn-hy2" }
}
EOF
"$SB" check -c "$BR_CFG" || { echo "FAIL: 桥配置校验不过，中止（未动 xray）"; exit 1; }
cat > /etc/systemd/system/$BR_UNIT.service <<EOF
[Unit]
Description=Relay Hy2 bridge (CC -> RN via Hysteria2)
After=network.target

[Service]
Type=simple
ExecStart=$SB run -c $BR_CFG
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable $BR_UNIT >/dev/null 2>&1 || true
systemctl restart $BR_UNIT
sleep 3
systemctl is-active $BR_UNIT || { echo "FAIL: 桥没起来，中止（未动 xray）"; exit 1; }
BR_IP=$(curl -s --max-time 20 --socks5-hostname 127.0.0.1:11099 https://api.ipify.org || true)
echo "桥单独出口 IP: ${BR_IP:-（空）}"
[ "$BR_IP" = "$RN_IP" ] || { echo "FAIL: 桥单独验不通，中止（未动 xray），停桥"; systemctl stop $BR_UNIT; systemctl disable $BR_UNIT 2>/dev/null || true; exit 1; }
echo "桥验通"

echo "=== 4. xray 出站改指向本地桥 ==="
python3 - <<'EOF'
import json
p = "/etc/xray-relay/config.json"
c = json.load(open(p))
new_out = {
    "tag": "to-rn",
    "protocol": "socks",
    "settings": { "servers": [ { "address": "127.0.0.1", "port": 11099 } ] }
}
obs = c.get("outbounds", [])
done = False
for i, o in enumerate(obs):
    if o.get("tag") == "to-rn":
        obs[i] = new_out
        done = True
if not done:
    obs[0] = new_out
json.dump(c, open(p, "w"), indent=2)
print("出站已改写为 socks -> 127.0.0.1:11099（本地 Hy2 桥）")
EOF
if ! "$XRAY" run -test -config "$CFG" >/tmp/hy2switch2-test.log 2>&1; then
  echo "FAIL: xray 校验不过，错误尾部："
  tail -5 /tmp/hy2switch2-test.log
  cp "$BAK" "$CFG"
  systemctl stop $BR_UNIT; systemctl disable $BR_UNIT 2>/dev/null || true
  echo "已自动还原，服务未重启、未受影响"
  exit 1
fi
echo "校验 OK"

echo "=== 5. 重启 xray 并回环验证全链 ==="
systemctl restart xray-relay
sleep 2
systemctl is-active xray-relay || true
ss -lntp 2>/dev/null | grep 24443 || echo "(24443 未监听)"
if looptest; then
  echo "PASS: CC 中转最后一跳已改走 Hy2（经本地桥），手机路径回环出口 = $RN_IP"
  echo "现状：24443 入口不变；xray-relay -> 本地桥 relay-hy2-bridge -> Hy2 -> RN"
  systemctl is-active $BR_UNIT || true
else
  echo "FAIL: 全链回环没通，执行自动回滚"
  full_rollback
  if looptest; then
    echo "已回滚到 Reality 直落并复验通过，中转恢复原状"
  else
    echo "警告：回滚后回环仍未通，请立即报告（附 /var/log/xray-relay/error.log）"
  fi
  exit 1
fi
echo "=== 完成 ==="
