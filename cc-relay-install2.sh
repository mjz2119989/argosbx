#!/bin/bash
# CC 中转门重装 v2（幂等）：全新 Reality 密钥在服务器本地生成 + info 日志 + 装完自检
# 入口 VLESS+Reality:24443 -> RN 落地 204.152.192.153:12438
set -e
mkdir -p /etc/sing-box-relay
if [ ! -x /usr/local/bin/sing-box-relay ]; then
  echo "下载 sing-box（自家镜像 Release）..."
  curl -sL --max-time 180 -o /usr/local/bin/sing-box-relay "https://github.com/mjz2119989/argosbx/releases/download/argosbx/sing-box-amd64"
  chmod +x /usr/local/bin/sing-box-relay
fi
if [ ! -f /etc/sing-box-relay/keys.env ]; then
  echo "生成全新 Reality 密钥（只在本机生成，私钥不出这台机器）..."
  KP=$(/usr/local/bin/sing-box-relay generate reality-keypair)
  PRIV=$(echo "$KP" | grep -i private | awk '{print $NF}')
  PUB=$(echo "$KP" | grep -i public | awk '{print $NF}')
  { echo "PRIV=$PRIV"; echo "PUB=$PUB"; } > /etc/sing-box-relay/keys.env
fi
. /etc/sing-box-relay/keys.env
if [ -z "$PRIV" ] || [ -z "$PUB" ]; then echo "密钥生成失败，把输出截图发我"; exit 1; fi
cat > /etc/sing-box-relay/config.json <<EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [{
    "type": "vless", "tag": "in", "listen": "::", "listen_port": 24443,
    "users": [{"uuid": "71bf3d9f-01d6-4490-9164-2dfbf6cc24be", "flow": "xtls-rprx-vision"}],
    "tls": {"enabled": true, "server_name": "apple.com",
      "reality": {"enabled": true,
        "handshake": {"server": "apple.com", "server_port": 443},
        "private_key": "$PRIV",
        "short_id": ["905ffdd2"]}}
  }],
  "outbounds": [{
    "type": "vless", "tag": "to-rn",
    "server": "204.152.192.153", "server_port": 12438,
    "uuid": "50c4431f-8cf1-4ddf-9332-b0658d0a383b", "flow": "xtls-rprx-vision",
    "tls": {"enabled": true, "server_name": "apple.com",
      "utls": {"enabled": true, "fingerprint": "chrome"},
      "reality": {"enabled": true,
        "public_key": "CGMnKHAlqN1CeOBERPVFa-yzBvWdFM73Q4umIEKROVc",
        "short_id": "fde901c9"}}
  }],
  "route": {"final": "to-rn"}
}
EOF
/usr/local/bin/sing-box-relay check -c /etc/sing-box-relay/config.json && echo "配置校验通过"
cat > /etc/systemd/system/sing-box-relay.service <<'EOF'
[Unit]
Description=RN Relay (entry -> RN exit)
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box-relay run -c /etc/sing-box-relay/config.json
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
iptables -I INPUT -p tcp --dport 24443 -j ACCEPT 2>/dev/null || true
ufw allow 24443/tcp 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now sing-box-relay
sleep 2
echo "===== 自检 ====="
systemctl is-active sing-box-relay
ss -tlnp | grep 24443 || echo "自检失败：24443 没在监听！"
echo "===== 新 RELAY 链接（整行截图发我，pbk 是新生成的） ====="
echo "vless://71bf3d9f-01d6-4490-9164-2dfbf6cc24be@66.154.101.212:24443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=apple.com&fp=chrome&pbk=${PUB}&sid=905ffdd2&type=tcp#RELAY-CC-RN"
