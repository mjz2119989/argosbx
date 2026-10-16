#!/bin/bash
# CC 中转门换芯：停 sing-box 版，改用 xray 内核（与 RN/CC 直连节点同款 Reality 实现）
# 幂等：密钥存 /etc/xray-relay/keys.env 复用；装完自带回环全链自测
set -e
echo "== 停用 sing-box 版中转（文件保留，可回滚） =="
systemctl disable --now sing-box-relay 2>/dev/null || true
mkdir -p /etc/xray-relay /var/log/xray-relay
if [ ! -x /usr/local/bin/xray-relay ]; then
  echo "下载 xray（自家镜像 Release）..."
  curl -sL --max-time 180 -o /usr/local/bin/xray-relay "https://github.com/mjz2119989/argosbx/releases/download/argosbx/xray-amd64"
  chmod +x /usr/local/bin/xray-relay
fi
if [ ! -f /etc/xray-relay/keys.env ]; then
  echo "生成全新 Reality 密钥（本机生成）..."
  KP=$(/usr/local/bin/xray-relay x25519)
  PRIV=$(echo "$KP" | grep -i private | awk '{print $NF}')
  PUB=$(echo "$KP" | grep -i public | awk '{print $NF}')
  { echo "PRIV=$PRIV"; echo "PUB=$PUB"; } > /etc/xray-relay/keys.env
fi
. /etc/xray-relay/keys.env
if [ -z "$PRIV" ] || [ -z "$PUB" ]; then echo "密钥生成失败，把输出截图发我"; exit 1; fi
DERIVED=$(/usr/local/bin/xray-relay x25519 -i "$PRIV" 2>/dev/null | grep -i public | awk '{print $NF}')
if [ "$DERIVED" = "$PUB" ]; then echo "密钥配对自检: MATCH"; else echo "密钥配对自检: MISMATCH（把输出截图发我）"; exit 1; fi
cat > /etc/xray-relay/config.json <<EOF
{
  "log": {"loglevel": "info", "access": "/var/log/xray-relay/access.log", "error": "/var/log/xray-relay/error.log"},
  "inbounds": [{
    "tag": "in", "listen": "0.0.0.0", "port": 24443, "protocol": "vless",
    "settings": {"clients": [{"id": "71bf3d9f-01d6-4490-9164-2dfbf6cc24be", "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {"network": "tcp", "security": "reality",
      "realitySettings": {"show": false, "dest": "apple.com:443", "xver": 0,
        "serverNames": ["apple.com"], "privateKey": "$PRIV", "shortIds": ["905ffdd2"]}},
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [
    {"tag": "to-rn", "protocol": "vless",
     "settings": {"vnext": [{"address": "204.152.192.153", "port": 12438,
       "users": [{"id": "50c4431f-8cf1-4ddf-9332-b0658d0a383b", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
     "streamSettings": {"network": "tcp", "security": "reality",
       "realitySettings": {"show": false, "serverName": "apple.com", "fingerprint": "chrome",
         "publicKey": "CGMnKHAlqN1CeOBERPVFa-yzBvWdFM73Q4umIEKROVc", "shortId": "fde901c9"}}},
    {"tag": "direct", "protocol": "freedom"}
  ],
  "routing": {"domainStrategy": "AsIs", "rules": [{"type": "field", "inboundTag": ["in"], "outboundTag": "to-rn"}]}
}
EOF
/usr/local/bin/xray-relay run -test -c /etc/xray-relay/config.json && echo "配置校验通过"
cat > /etc/systemd/system/xray-relay.service <<'EOF'
[Unit]
Description=RN Relay xray (entry -> RN exit)
After=network.target
[Service]
ExecStart=/usr/local/bin/xray-relay run -c /etc/xray-relay/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
iptables -I INPUT -p tcp --dport 24443 -j ACCEPT 2>/dev/null || true
ufw allow 24443/tcp 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now xray-relay
sleep 2
echo "===== 服务自检 ====="
systemctl is-active xray-relay
ss -tlnp | grep 24443 || echo "自检失败：24443 没在监听！"
echo "===== 回环全链自测（xray 客户端经中转出去） ====="
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
echo "===== 新 RELAY 链接 ====="
echo "vless://71bf3d9f-01d6-4490-9164-2dfbf6cc24be@66.154.101.212:24443?encryption=none&security=reality&sni=apple.com&fp=chrome&pbk=${PUB}&sid=905ffdd2&type=tcp&flow=xtls-rprx-vision#RELAY-CC-RN"
echo "===== 新公钥十六进制（防读错，把这串也截图发我） ====="
echo "字符数（应为 43）: ${#PUB}"
printf %s "$PUB" | od -An -tx1 | tr -d ' \n'
echo
