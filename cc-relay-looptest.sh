#!/bin/bash
# CC 中转全链自测（服务器本地回环）：CC 自己当客户端连自己的中转，看能否经 RN 落地出去
# 顺带验：配置里的私钥推导出的公钥，是否与 keys.env 的 PUB 一致（只打印 MATCH/MISMATCH）
. /etc/sing-box-relay/keys.env
echo "===== A) 密钥配对检查 ====="
XR=$(ls /root/agsbx/xray 2>/dev/null || which xray 2>/dev/null || true)
if [ -n "$XR" ]; then
  DERIVED=$("$XR" x25519 -i "$PRIV" 2>/dev/null | grep -i public | awk '{print $NF}')
  if [ "$DERIVED" = "$PUB" ]; then echo "MATCH：私钥与公钥配对正确"; else echo "MISMATCH：私钥推导出的公钥与 PUB 不一致！"; fi
else
  echo "没找到 xray 二进制，跳过配对检查（不影响下面的回环测试）"
fi
echo "===== B) 回环测试：经中转访问 ipify ====="
cat > /tmp/relay-test.json <<EOF
{
  "log": {"level": "info"},
  "inbounds": [{"type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": 11080}],
  "outbounds": [{
    "type": "vless", "tag": "via-relay",
    "server": "127.0.0.1", "server_port": 24443,
    "uuid": "71bf3d9f-01d6-4490-9164-2dfbf6cc24be", "flow": "xtls-rprx-vision",
    "tls": {"enabled": true, "server_name": "apple.com",
      "utls": {"enabled": true, "fingerprint": "chrome"},
      "reality": {"enabled": true, "public_key": "$PUB", "short_id": "905ffdd2"}}
  }],
  "route": {"final": "via-relay"}
}
EOF
/usr/local/bin/sing-box-relay run -c /tmp/relay-test.json > /tmp/relay-test.log 2>&1 &
RT=$!
sleep 3
echo "--- 经中转的出口 IP（期望 204.152.192.153）:"
curl -s -m 20 -x socks5h://127.0.0.1:11080 https://api.ipify.org || echo "(ipify 没通)"
echo
echo "--- 备用验证 cloudflare trace:"
curl -s -m 20 -x socks5h://127.0.0.1:11080 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc)=' || echo "(trace 没通)"
kill $RT 2>/dev/null
echo "===== C) 测试客户端日志（看卡在哪一跳） ====="
tail -25 /tmp/relay-test.log
echo "===== 结束，把完整输出截图发我 ====="
