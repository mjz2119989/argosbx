#!/bin/bash
# CC 中转二次诊断（只读）：配置文件里的私钥配对 + apple.com 握手目标体检 + 回环尝试的服务端记录
. /etc/sing-box-relay/keys.env
echo "===== 1) 配置文件里的私钥 与 PUB 配对检查 ====="
CFGPRIV=$(grep -o '"private_key": "[^"]*"' /etc/sing-box-relay/config.json | head -1 | sed 's/.*: "//; s/"$//')
XR=$(ls /root/agsbx/xray 2>/dev/null || which xray 2>/dev/null || true)
if [ -n "$XR" ] && [ -n "$CFGPRIV" ]; then
  DERIVED=$("$XR" x25519 -i "$CFGPRIV" 2>/dev/null | grep -i public | awk '{print $NF}')
  if [ "$DERIVED" = "$PUB" ]; then echo "MATCH：配置里的私钥与 PUB 配对正确"; else echo "MISMATCH：配置里的私钥与 PUB 不配对！"; fi
else
  echo "跳过（缺 xray 或没读到配置私钥）"
fi
echo "===== 2) apple.com 握手目标体检（CC 出站） ====="
curl -s -o /dev/null -w 'apple.com https: code=%{http_code} time=%{time_total}s\n' -m 15 https://apple.com || echo "curl apple.com 失败！"
echo | openssl s_client -connect apple.com:443 -servername apple.com -alpn h2 2>/dev/null | grep -E 'Protocol *:|ALPN protocol|Verify return code' || echo "openssl 握手失败！"
echo "===== 3) 服务端日志里本机回环（127.0.0.1）的记录 ====="
journalctl -u sing-box-relay --no-pager -n 60 | grep '127.0.0.1' | tail -8
echo "===== 结束，把完整输出截图发我 ====="
