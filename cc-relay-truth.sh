#!/bin/bash
# CC 中转深挖（只读为主）：xray 中转日志 + 现役节点参数对照 + IPv6/IPv4 对照 + CC 直连 RN 落地口实测
echo "===== 1) xray-relay 错误日志最近 40 行 ====="
tail -40 /var/log/xray-relay/error.log 2>/dev/null || echo "没有 error.log"
echo "===== 2) CC 现役能用的 Reality 入站参数（对照组） ====="
python3 - <<'PYEOF'
import json
try:
    cfg = json.load(open('/root/agsbx/xr.json'))
    for ib in cfg.get('inbounds', []):
        ss = ib.get('streamSettings', {})
        if ss.get('security') == 'reality':
            rs = ss.get('realitySettings', {})
            print("端口:", ib.get('port'), "| 协议:", ib.get('protocol'),
                  "| dest:", rs.get('dest'), "| serverNames:", rs.get('serverNames'),
                  "| shortIds:", rs.get('shortIds'), "| 私钥长度:", len(rs.get('privateKey', '')))
except Exception as e:
    print("读取 xr.json 失败:", e)
PYEOF
echo "===== 3) apple.com 的 IPv6 / IPv4 连通对照 ====="
echo "解析结果:"; getent ahosts apple.com | head -6
echo "IPv4: $(curl -4 -s -o /dev/null -w 'code=%{http_code} time=%{time_total}s' -m 10 https://apple.com || echo 失败)"
echo "IPv6: $(curl -6 -s -o /dev/null -w 'code=%{http_code} time=%{time_total}s' -m 10 https://apple.com || echo 失败)"
echo "===== 4) CC 直连 RN 落地口 12438 实测（绕过中转入站） ====="
cat > /tmp/direct-rn.json <<'EOF'
{
  "log": {"loglevel": "info"},
  "inbounds": [{"listen": "127.0.0.1", "port": 11081, "protocol": "socks", "settings": {"udp": true}}],
  "outbounds": [{"protocol": "vless",
    "settings": {"vnext": [{"address": "204.152.192.153", "port": 12438,
      "users": [{"id": "50c4431f-8cf1-4ddf-9332-b0658d0a383b", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
    "streamSettings": {"network": "tcp", "security": "reality",
      "realitySettings": {"serverName": "apple.com", "fingerprint": "chrome",
        "publicKey": "CGMnKHAlqN1CeOBERPVFa-yzBvWdFM73Q4umIEKROVc", "shortId": "fde901c9"}}}]
}
EOF
/usr/local/bin/xray-relay run -c /tmp/direct-rn.json > /tmp/direct-rn.log 2>&1 &
DT=$!
sleep 3
echo "直连 RN 的出口 IP（期望 204.152.192.153）: $(curl -s -m 20 -x socks5h://127.0.0.1:11081 https://api.ipify.org || echo 没通)"
kill $DT 2>/dev/null || true
echo "--- 直连测试客户端日志尾部:"
tail -12 /tmp/direct-rn.log
echo "===== 结束，把完整输出截图发我（太长就分两张） ====="
