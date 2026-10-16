#!/bin/bash
# 修正中转落地口：12438 是 RN 的 XHTTP 入站（协议不对），改为 VISION 入站 15207（参数同源订阅实测）
set -e
python3 - <<'PYEOF'
import json
p = '/etc/xray-relay/config.json'
cfg = json.load(open(p))
ob = cfg['outbounds'][0]
vx = ob['settings']['vnext'][0]
rs = ob['streamSettings']['realitySettings']
print("改前: %s:%s pbk=%s... sid=%s sni=%s" % (vx['address'], vx['port'], rs['publicKey'][:12], rs['shortId'], rs['serverName']))
assert rs['publicKey'] == 'CGMnKHAlqN1CeOBERPVFa-yzBvWdFM73Q4umIEKROVc', "出站公钥与预期不符，停手"
vx['port'] = 15207
json.dump(cfg, open(p, 'w'), indent=2)
print("改后: %s:%s（其余参数未动）" % (vx['address'], vx['port']))
PYEOF
/usr/local/bin/xray-relay run -test -c /etc/xray-relay/config.json && echo "配置校验通过"
systemctl restart xray-relay
sleep 2
systemctl is-active xray-relay
ss -tlnp | grep 24443 || echo "失败：24443 没在监听！"
echo "===== 回环全链自测（经中转 -> RN 落地出去） ====="
. /etc/xray-relay/keys.env
cat > /tmp/xray-test.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": 11080, "protocol": "socks", "settings": {"udp": true}}],
  "outbounds": [{"protocol": "vless",
    "settings": {"vnext": [{"address": "127.0.0.1", "port": 24443,
      "users": [{"id": "71bf3d9f-01d6-4490-9164-2dfbf6cc24be", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
    "streamSettings": {"network": "tcp", "security": "reality",
      "realitySettings": {"serverName": "apple.com", "fingerprint": "chrome",
        "publicKey": "$PUB", "shortId": "905ffdd2"}}}]
}
EOF
/usr/local/bin/xray-relay run -c /tmp/xray-test.json > /tmp/xray-test.log 2>&1 &
XT=$!
sleep 3
echo "--- 经中转出口 IP（期望 204.152.192.153）:"
curl -s -m 20 -x socks5h://127.0.0.1:11080 https://api.ipify.org || echo "(ipify 没通)"
echo
echo "--- 备用验证 cloudflare trace:"
curl -s -m 20 -x socks5h://127.0.0.1:11080 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc)=' || echo "(trace 没通)"
kill $XT 2>/dev/null || true
echo "===== 中转服务端日志尾部（找 accepted / tunneling） ====="
tail -15 /var/log/xray-relay/error.log
echo "===== 结束，把完整输出截图发我 ====="
