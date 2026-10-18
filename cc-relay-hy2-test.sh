#!/bin/bash
# cc-relay-hy2-test.sh — CC 试验田专用：旁路测试「CC -> RN 走 Hy2 落地」是否可行
# 不动现行 xray-relay（24443 中转照常），只临时起一个本地 socks 客户端验证出口
set -u
RN_IP=204.152.192.153
HY2_PORT=35444
HY2_PASS=50c4431f-8cf1-4ddf-9332-b0658d0a383b
HY2_SNI=www.bing.com
TEST_PORT=11099
CFG=/tmp/hy2test-sb.json
LOG=/tmp/hy2test-sb.log

echo "=== 1. 现行中转状态（测试前后应一致）==="
systemctl is-active xray-relay || true
ss -lntp 2>/dev/null | grep 24443 || echo "(24443 未监听？先报告再继续)"

echo "=== 2. 找 sing-box 客户端二进制 ==="
SB=""
for p in /root/agsbx-lite/sing-box /usr/local/bin/sing-box /usr/local/bin/sing-box-relay; do
  [ -x "$p" ] && SB="$p" && break
done
if [ -z "$SB" ]; then
  SB=$(command -v sing-box || true)
fi
if [ -z "$SB" ]; then
  echo "FAIL: 找不到 sing-box，测试中止（现行中转未动）"
  exit 1
fi
echo "sing-box: $SB"

echo "=== 3. 写测试配置（Hy2 出站 -> RN）==="
cat > "$CFG" <<EOF
{
  "log": { "level": "warn", "timestamp": false },
  "inbounds": [
    { "type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": $TEST_PORT }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "to-rn-hy2",
      "server": "$RN_IP",
      "server_port": $HY2_PORT,
      "password": "$HY2_PASS",
      "up_mbps": 100,
      "down_mbps": 100,
      "tls": { "enabled": true, "server_name": "$HY2_SNI", "alpn": ["h3"], "insecure": true }
    }
  ],
  "route": { "final": "to-rn-hy2" }
}
EOF
"$SB" check -c "$CFG" && echo "配置校验 OK" || { echo "FAIL: 配置校验不过"; exit 1; }

echo "=== 4. 起测试客户端，回环验证出口 ==="
"$SB" run -c "$CFG" > "$LOG" 2>&1 &
PID=$!
sleep 3
EXIT_IP=$(curl -s --max-time 20 --socks5-hostname 127.0.0.1:$TEST_PORT https://api.ipify.org || true)
echo "出口 IP: ${EXIT_IP:-（空，连不通）}"
if [ "$EXIT_IP" = "$RN_IP" ]; then
  echo "PASS: CC -> RN 走 Hy2 落地成功"
  echo "--- 粗测 3 次往返耗时（cloudflare trace）---"
  for i in 1 2 3; do
    curl -s -o /dev/null -w "第 $i 次: %{time_total}s\n" --max-time 20 --socks5-hostname 127.0.0.1:$TEST_PORT https://www.cloudflare.com/cdn-cgi/trace || echo "第 $i 次失败"
  done
else
  echo "FAIL: Hy2 落地没通，日志尾部："
  tail -5 "$LOG" || true
fi
kill $PID 2>/dev/null; wait $PID 2>/dev/null

echo "=== 5. 收尾确认：现行中转仍在岗 ==="
systemctl is-active xray-relay || true
ss -lntp 2>/dev/null | grep 24443 || echo "(24443 未监听，需报告)"
rm -f "$CFG"
echo "=== 测试结束（本脚本未改动任何现行配置）==="
