#!/bin/bash
# HD/CC 通用：装一个「入口中转门」，所有流量转 RN 落地（204.152.192.153）
set -e
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) BIN=sing-box-amd64 ;;
  aarch64) BIN=sing-box-arm64 ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac
mkdir -p /etc/sing-box-relay
curl -sL --max-time 120 -o /usr/local/bin/sing-box-relay "https://github.com/mjz2119989/argosbx/releases/download/argosbx/$BIN"
chmod +x /usr/local/bin/sing-box-relay
cat > /etc/sing-box-relay/config.json << 'EOF'
{
  "log": {"level": "warn"},
  "inbounds": [{
    "type": "vless", "tag": "in", "listen": "::", "listen_port": 24443,
    "users": [{"uuid": "71bf3d9f-01d6-4490-9164-2dfbf6cc24be", "flow": "xtls-rprx-vision"}],
    "tls": {"enabled": true, "server_name": "apple.com",
      "reality": {"enabled": true,
        "handshake": {"server": "apple.com", "server_port": 443},
        "private_key": "SJ4ZNDwwWhNbZx2qySc_Xcf0nnHdJ52tl3T0ykFHvHE",
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
cat > /etc/systemd/system/sing-box-relay.service << 'EOF'
[Unit]
Description=RN Relay (entry -> RN exit)
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box-relay run -c /etc/sing-box-relay/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
iptables -I INPUT -p tcp --dport 24443 -j ACCEPT 2>/dev/null || true
ufw allow 24443/tcp 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now sing-box-relay
sleep 2
systemctl is-active sing-box-relay && echo "=== 中转门装好了，端口 24443 已开工 ==="
