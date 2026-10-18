#!/bin/bash
# cc-relay-hy2-switch.sh — 把 CC 中转（xray-relay）出站从 Reality:15207 正式切到 Hy2:35444
# 安全网：备份只生成一次；新配置校验不过 -> 不重启、自动还原；重启后回环不通 -> 自动回滚并复验
set -u
CFG=/etc/xray-relay/config.json
BAK=/etc/xray-relay/config.json.bak-pre-hy2switch
XRAY=/usr/local/bin/xray-relay
RN_IP=204.152.192.153
SB=""
for p in /root/agsbx-lite/sing-box /usr/local/bin/sing-box /usr/local/bin/sing-box-relay; do
  [ -x "$p" ] && SB="$p" && break
done
[ -z "$SB" ] && SB=$(command -v sing-box || true)

rollback() {
  echo ">>> 触发自动回滚：还原 Reality 出站配置"
  cp "$BAK" "$CFG"
  systemctl restart xray-relay
  sleep 2
  systemctl is-active xray-relay || true
}

looptest() {
  # 用订阅同款参数（CC 中转入站凭证）回环：手机怎么连，咱就怎么验
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

echo "=== 1. 前置检查 ==="
systemctl is-active xray-relay || { echo "FAIL: xray-relay 不在运行，中止（未改动）"; exit 1; }
[ -n "$SB" ] || { echo "FAIL: 找不到 sing-box 回环客户端，中止（未改动）"; exit 1; }
grep -q '15207' "$CFG" && grep -q 'CGMnKHAlqN1CeOBERPVFa' "$CFG" || { echo "FAIL: 现行配置不是预期的 Reality 落地，中止（未改动）"; exit 1; }
echo "现行出站确认为 Reality -> RN:15207"

echo "=== 2. 备份（只生成一次）==="
[ -f "$BAK" ] || cp "$CFG" "$BAK"
ls -l "$BAK"

echo "=== 3. 改写出站为 Hy2 ==="
python3 - <<'EOF'
import json
p = "/etc/xray-relay/config.json"
c = json.load(open(p))
new_out = {
    "tag": "to-rn",
    "protocol": "hysteria2",
    "settings": {
        "version": 2,
        "address": "204.152.192.153",
        "port": 35444,
        "password": "50c4431f-8cf1-4ddf-9332-b0658d0a383b"
    },
    "streamSettings": {
        "network": "hysteria2",
        "security": "tls",
        "tlsSettings": {
            "serverName": "www.bing.com",
            "alpn": ["h3"],
            "pinnedPeerCertificateSha256": "36e18addb52cc9bf99357e59616f268d05f55c4fe837336d1b8df6ee34471694"
        },
        "hysteria2Settings": { "version": 2, "up": "100 mbps", "down": "100 mbps" }
    }
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
print("出站已改写为 hysteria2 -> 204.152.192.153:35444")
EOF

echo "=== 4. 新配置校验（不过则不重启、自动还原）==="
if ! "$XRAY" run -test -config "$CFG" >/tmp/hy2switch-test.log 2>&1; then
  echo "FAIL: xray 校验不过，错误尾部："
  tail -5 /tmp/hy2switch-test.log
  cp "$BAK" "$CFG"
  echo "已自动还原原配置，现行服务未重启、未受影响"
  systemctl is-active xray-relay || true
  exit 1
fi
echo "校验 OK"

echo "=== 5. 重启并回环验证 ==="
systemctl restart xray-relay
sleep 2
systemctl is-active xray-relay || true
ss -lntp 2>/dev/null | grep 24443 || echo "(24443 未监听)"
if looptest; then
  echo "PASS: CC 中转已正式切到 Hy2 落地，手机路径回环出口 = $RN_IP"
  echo "现状：VL-RELAY-CC-RN 入口不变（24443/Reality），最后一跳改走 Hy2"
else
  echo "FAIL: 回环没通，执行自动回滚"
  rollback
  if looptest; then
    echo "已回滚到 Reality 落地并复验通过，中转恢复原状"
  else
    echo "警告：回滚后回环仍未通，请立即报告（附 /var/log/xray-relay/error.log）"
  fi
  exit 1
fi
echo "=== 完成 ==="
