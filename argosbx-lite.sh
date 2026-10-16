#!/bin/bash
# ======================================================================
# argosbx-lite.sh —— 精简版小钢炮（仅含实际在用的配方）
#
# 与原版的关系：
#   以勇哥 argosbx（2026-10-15 快照，2742 行）为蓝本，只提取实际在用的
#   6 条节点逻辑重写而成，不是原版的补丁也不是原版的分支。
#
# 砍掉的东西（原版有、本版没有）：
#   AnyTLS / TUIC / Naive / SOCKS / Shadowsocks-2022 / WARP 相关 /
#   acme 域名证书流程 / 全部菜单交互 / clash/sing-box 客户端配置生成 /
#   CDN 优选 IP 变体节点。Hy2 用自签证书 + pinSHA256（与现行一致）。
#
# 只留的 6 条（服务端）：
#   1) VLESS-Reality-XHTTP（xray）
#   2) VLESS-Reality-Vision（xray）
#   3) VLESS-WS（xray）
#   4) VMess-WS（xray）
#   5) Hysteria2（sing-box，带 brutal；原版 RN 即 sing-box 扛 Hy2）
#   6) Argo 隧道（cloudflared）→ 落在 VLESS-WS 端口上，输出 443 TLS + 80 两条
#
# 内置调优（比原版强的地方，写死带上）：
#   - sysctl：BBR + fq + 缓冲（与 99-opt.conf 同款，CC/RN 已验证）
#   - Hy2：sing-box 入站 up_mbps/down_mbps（brutal，默认 100）
#   - xhttp 客户端链接：mode=stream-one + xmux extra（与现行 RN v3 一致）
#
# 用法（全部零交互，环境变量配置）：
#   试跑（并行，不动原版 /root/agsbx）：
#     LITE_DIR=/root/agsbx-lite bash argosbx-lite.sh
#   正式（想让它接管整台机器时再用）：
#     LITE_DIR=/root/agsbx bash argosbx-lite.sh   # 仍不会删原版文件，仅同目录重装
#
# 回滚（试跑后想清干净）：
#   systemctl stop xray-lite sing-box-lite cloudflared-lite lite-sub-httpd
#   systemctl disable xray-lite sing-box-lite cloudflared-lite lite-sub-httpd
#   rm -rf /root/agsbx-lite
#   （如开了 LITE_HY2_DNAT=1，另需手动删对应的 iptables DNAT 规则）
#
# 进程守护说明：
#   本脚本用 systemd 单元（xray-lite / sing-box-lite / cloudflared-lite /
#   lite-sub-httpd），Ubuntu/Debian 开箱即用。无 systemd 的机器请改用
#   nohup + crontab @reboot 的方式（原版 depend() 里有现成写法可抄）。
#
# 幂等：
#   密钥/证书/端口/订阅 token 全部落盘在 $LITE_DIR，重跑时复用；
#   只有显式给出环境变量才会覆盖。备份文件只生成一次，不会叠加。
# ======================================================================
set -e

# ---------------- 环境变量（全部有默认值） ----------------
LITE_DIR="${LITE_DIR:-/root/agsbx-lite}"          # 安装目录，绝不读写 /root/agsbx
LITE_UUID="${LITE_UUID:-}"                        # 不给则自动生成
LITE_PORT_XH="${LITE_PORT_XH:-}"                  # VLESS-Reality-XHTTP
LITE_PORT_VL="${LITE_PORT_VL:-}"                  # VLESS-Reality-Vision
LITE_PORT_VW="${LITE_PORT_VW:-}"                  # VLESS-WS（Argo 也落在这个端口）
LITE_PORT_VM="${LITE_PORT_VM:-}"                  # VMess-WS
LITE_PORT_HY2="${LITE_PORT_HY2:-}"                # Hysteria2（sing-box）
LITE_ARGO_TOKEN="${LITE_ARGO_TOKEN:-}"            # 给则固定隧道；不给则临时隧道
LITE_ARGO_DOMAIN="${LITE_ARGO_DOMAIN:-}"          # 固定隧道时必填（与 token 配对）
LITE_SUB_TOKEN="${LITE_SUB_TOKEN:-}"              # 订阅路径 token，不给则用 UUID
LITE_SUB_PORT="${LITE_SUB_PORT:-}"                # 订阅端口，不给则随机
LITE_SNI="${LITE_SNI:-www.bing.com}"              # Hy2 的 sni
LITE_SNI_REALITY="${LITE_SNI_REALITY:-apple.com}"  # Reality 的 sni/dest
LITE_HY2_MPORT="${LITE_HY2_MPORT:-19800-25807,30000}"  # Hy2 客户端 mport（与 RN 现行一致）
LITE_HY2_BRUTAL="${LITE_HY2_BRUTAL:-100}"          # Hy2 brutal Mbps（up/down 同值）
LITE_HY2_DNAT="${LITE_HY2_DNAT:-0}"                # 1=给 mport 加 iptables DNAT（试跑建议 0）
LITE_IP="${LITE_IP:-}"                            # 服务器公网 IP，不给则自动探测
LITE_NAME="${LITE_NAME:-LITE}"                     # 节点名后缀
SKIP_SYSCTL="${SKIP_SYSCTL:-0}"                    # 1=跳过 sysctl 调优

MIRROR="https://github.com/mjz2119989/argosbx/releases/download/argosbx"
# xhttp 客户端调优参数（与现行 RN 订阅 v3 一字不差，URL 编码形式）
XMUX_EXTRA='%7B%22xmux%22%3A%7B%22maxConnections%22%3A2%2C%22cMaxReuseTimes%22%3A32%2C%22hMaxReusableSecs%22%3A300%7D%7D'

[ "$EUID" -eq 0 ] || { echo "请用 root 运行"; exit 1; }
mkdir -p "$LITE_DIR"
echo "安装目录：$LITE_DIR"

# ---------------- 架构与二进制 ----------------
cpu="$(uname -m)"
case "$cpu" in
  x86_64)  cpu=amd64 ;;
  aarch64|arm64) cpu=arm64 ;;
  *) echo "不支持的架构：$cpu"; exit 1 ;;
esac

dl() { # dl <url> <out>
  (command -v curl >/dev/null 2>&1 && curl -Lo "$2" --retry 2 "$1") \
    || (command -v wget >/dev/null 2>&1 && wget -O "$2" --tries=2 "$1")
}
[ -x "$LITE_DIR/xray" ] || { echo "下载 xray…"; dl "$MIRROR/xray-$cpu" "$LITE_DIR/xray"; chmod +x "$LITE_DIR/xray"; }
[ -x "$LITE_DIR/sing-box" ] || { echo "下载 sing-box…"; dl "$MIRROR/sing-box-$cpu" "$LITE_DIR/sing-box"; chmod +x "$LITE_DIR/sing-box"; }
[ -x "$LITE_DIR/cloudflared" ] || { echo "下载 cloudflared…"; dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cpu" "$LITE_DIR/cloudflared"; chmod +x "$LITE_DIR/cloudflared"; }
command -v busybox >/dev/null 2>&1 || { echo "安装 busybox…"; apt-get update -qq && apt-get install -y -qq busybox openssl >/dev/null 2>&1 || true; }
BUSYBOX="$(command -v busybox)"
[ -n "$BUSYBOX" ] || { echo "找不到 busybox，订阅服务无法启动"; exit 1; }

# ---------------- sysctl 调优（与 99-opt.conf 同款） ----------------
if [ "$SKIP_SYSCTL" != "1" ]; then
cat > /etc/sysctl.d/99-opt-lite.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.netdev_max_backlog = 16384
EOF
sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-opt-lite.conf >/dev/null 2>&1 || true
echo "sysctl 调优已写入 /etc/sysctl.d/99-opt-lite.conf"
fi

# ---------------- UUID / 端口（落盘复用，幂等） ----------------
if [ -z "$LITE_UUID" ]; then
  if [ -s "$LITE_DIR/uuid" ]; then LITE_UUID="$(cat "$LITE_DIR/uuid")"
  else LITE_UUID="$("$LITE_DIR/sing-box" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)"; echo "$LITE_UUID" > "$LITE_DIR/uuid"; fi
else
  echo "$LITE_UUID" > "$LITE_DIR/uuid"
fi
uuid="$LITE_UUID"

pick_port() { # pick_port <env_value> <file>  -> echo port
  local v="$1" f="$2" p
  if [ -n "$v" ]; then echo "$v" > "$LITE_DIR/$f"; echo "$v"; return; fi
  if [ -s "$LITE_DIR/$f" ]; then cat "$LITE_DIR/$f"; return; fi
  while :; do
    p="$(shuf -i 10000-65535 -n 1)"
    ss -tln 2>/dev/null | grep -q ":$p " || { echo "$p" > "$LITE_DIR/$f"; echo "$p"; return; }
  done
}
port_xh="$(pick_port "$LITE_PORT_XH" port_xh)"
port_vl_re="$(pick_port "$LITE_PORT_VL" port_vl_re)"
port_vw="$(pick_port "$LITE_PORT_VW" port_vw)"
port_vm_ws="$(pick_port "$LITE_PORT_VM" port_vm_ws)"
port_hy2="$(pick_port "$LITE_PORT_HY2" port_hy2)"
echo "端口：xhttp-reality=$port_xh reality-vision=$port_vl_re vless-ws=$port_vw vmess-ws=$port_vm_ws hy2=$port_hy2"

# ---------------- 密钥材料（落盘复用） ----------------
if [ ! -s "$LITE_DIR/xrk_private" ]; then
  kp="$("$LITE_DIR/xray" x25519)"
  echo "$kp" | awk -F':' '/PrivateKey/{print $2}' | xargs > "$LITE_DIR/xrk_private"
  echo "$kp" | awk -F':' '/Password/{print $2}' | xargs > "$LITE_DIR/xrk_public"
  date +%s%N | sha256sum | cut -c1-8 > "$LITE_DIR/xrk_shortid"
fi
private_key_x="$(cat "$LITE_DIR/xrk_private")"
public_key_x="$(cat "$LITE_DIR/xrk_public")"
short_id_x="$(cat "$LITE_DIR/xrk_shortid")"

if [ ! -s "$LITE_DIR/vl_enkey" ]; then
  vlkey="$("$LITE_DIR/xray" vlessenc)"
  echo "$vlkey" | grep '"decryption":' | sed -n '2p' | cut -d' ' -f2- | tr -d '"' > "$LITE_DIR/vl_dekey"
  echo "$vlkey" | grep '"encryption":' | sed -n '2p' | cut -d' ' -f2- | tr -d '"' > "$LITE_DIR/vl_enkey"
fi
dekey="$(cat "$LITE_DIR/vl_dekey")"
enkey="$(cat "$LITE_DIR/vl_enkey")"

# Hy2 自签证书（与原版同法：prime256v1，CN=www.bing.com）
if [ ! -s "$LITE_DIR/hy2_private.key" ]; then
  openssl ecparam -genkey -name prime256v1 -out "$LITE_DIR/hy2_private.key" >/dev/null 2>&1
  openssl req -new -x509 -days 36500 -key "$LITE_DIR/hy2_private.key" -out "$LITE_DIR/hy2_cert.crt" -subj "/CN=$LITE_SNI" >/dev/null 2>&1
fi
sha_hy2="$(openssl x509 -in "$LITE_DIR/hy2_cert.crt" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"

# ---------------- 服务器 IP ----------------
if [ -z "$LITE_IP" ]; then
  server_ip="$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || curl -s --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  [ -n "$server_ip" ] || { echo "探测不到公网 IP，请用 LITE_IP=xxx 指定"; exit 1; }
else
  server_ip="$LITE_IP"
fi
echo "服务器 IP：$server_ip"

# ---------------- xray 配置（4 条入站） ----------------
cat > "$LITE_DIR/xr-lite.json" <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "tag": "xhttp-reality",
      "listen": "::",
      "port": $port_xh,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$uuid", "flow": "xtls-rprx-vision" } ],
        "decryption": "$dekey"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "target": "$LITE_SNI_REALITY:443",
          "serverNames": [ "$LITE_SNI_REALITY" ],
          "privateKey": "$private_key_x",
          "shortIds": [ "$short_id_x" ]
        },
        "xhttpSettings": { "host": "", "path": "$uuid-xh", "mode": "auto" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    },
    {
      "tag": "reality-vision",
      "listen": "::",
      "port": $port_vl_re,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$uuid", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "dest": "$LITE_SNI_REALITY:443",
          "serverNames": [ "$LITE_SNI_REALITY" ],
          "privateKey": "$private_key_x",
          "shortIds": [ "$short_id_x" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    },
    {
      "tag": "vless-ws",
      "listen": "::",
      "port": $port_vw,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$uuid", "flow": "xtls-rprx-vision" } ],
        "decryption": "$dekey"
      },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "$uuid-vw" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    },
    {
      "tag": "vmess-xr",
      "listen": "::",
      "port": $port_vm_ws,
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "$uuid" } ] },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "$uuid-vm" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
"$LITE_DIR/xray" run -test -c "$LITE_DIR/xr-lite.json" >/dev/null 2>&1 && echo "xray 配置校验通过" \
  || { echo "xray 配置校验失败，请检查"; exit 1; }

# ---------------- sing-box 配置（Hy2，带 brutal） ----------------
cat > "$LITE_DIR/sb-lite.json" <<EOF
{
  "log": { "level": "error" },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-lite",
      "listen": "::",
      "listen_port": $port_hy2,
      "up_mbps": $LITE_HY2_BRUTAL,
      "down_mbps": $LITE_HY2_BRUTAL,
      "users": [ { "password": "$uuid" } ],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true,
        "alpn": [ "h3" ],
        "certificate_path": "$LITE_DIR/hy2_cert.crt",
        "key_path": "$LITE_DIR/hy2_private.key"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
"$LITE_DIR/sing-box" check -c "$LITE_DIR/sb-lite.json" >/dev/null 2>&1 && echo "sing-box 配置校验通过" \
  || { echo "sing-box 配置校验失败，请检查"; exit 1; }

# ---------------- Hy2 端口跳跃（可选，默认不开） ----------------
if [ "$LITE_HY2_DNAT" = "1" ]; then
  # 注意：只追加规则，不 flush（试跑机上可能已有别的 DNAT）
  for prange in $(echo "$LITE_HY2_MPORT" | tr ',' ' '); do
    if echo "$prange" | grep -q '-'; then
      iptables -t nat -C PREROUTING -p udp --dport "$prange" -j DNAT --to-destination ":$port_hy2" 2>/dev/null \
        || iptables -t nat -A PREROUTING -p udp --dport "$prange" -j DNAT --to-destination ":$port_hy2"
    else
      iptables -t nat -C PREROUTING -p udp --dport "$prange" -j DNAT --to-destination ":$port_hy2" 2>/dev/null \
        || iptables -t nat -A PREROUTING -p udp --dport "$prange" -j DNAT --to-destination ":$port_hy2"
    fi
  done
  echo "Hy2 mport DNAT 已追加：$LITE_HY2_MPORT -> $port_hy2"
fi

# ---------------- systemd 单元（独立服务名，不碰原版） ----------------
mkunit() { # mkunit <name> <exec>
  cat > "/etc/systemd/system/$1.service" <<EOF
[Unit]
Description=$1 (argosbx-lite)
After=network.target
[Service]
Type=simple
ExecStart=$2
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable "$1" >/dev/null 2>&1
  systemctl restart "$1" >/dev/null 2>&1
}
mkunit xray-lite "$LITE_DIR/xray run -c $LITE_DIR/xr-lite.json"
mkunit sing-box-lite "$LITE_DIR/sing-box run -c $LITE_DIR/sb-lite.json"
echo "xray-lite / sing-box-lite 服务已启动"

# ---------------- Argo 隧道 ----------------
echo "$port_vw" > "$LITE_DIR/argoport.log"
if [ -n "$LITE_ARGO_TOKEN" ]; then
  echo "固定隧道模式"
  [ -n "$LITE_ARGO_DOMAIN" ] || { echo "LITE_ARGO_TOKEN 给了，LITE_ARGO_DOMAIN 也必须给"; exit 1; }
  echo "$LITE_ARGO_DOMAIN" > "$LITE_DIR/argo_domain.log"
  echo "$LITE_ARGO_TOKEN" > "$LITE_DIR/argo_token.log"
  mkunit cloudflared-lite "$LITE_DIR/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token $LITE_ARGO_TOKEN"
  argodomain="$LITE_ARGO_DOMAIN"
else
  echo "临时隧道模式，申请中（约 15 秒）…"
  nohup "$LITE_DIR/cloudflared" tunnel --url "http://localhost:$port_vw" --edge-ip-version auto --no-autoupdate --protocol http2 > "$LITE_DIR/argo.log" 2>&1 &
  echo $! > "$LITE_DIR/argo.pid"
  sleep 15
  argodomain="$(grep -a trycloudflare.com "$LITE_DIR/argo.log" 2>/dev/null | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')"
  if [ -z "$argodomain" ]; then
    echo "临时隧道申请失败，可稍后重跑（配置已落盘，重跑会复用）"; exit 1
  fi
  echo "$argodomain" > "$LITE_DIR/argo_domain.log"
fi
echo "Argo 域名：$argodomain"

# ---------------- 生成 6 条链接 ----------------
N="$LITE_NAME"
: > "$LITE_DIR/jhsub.txt"
l1="vless://$uuid@$server_ip:$port_xh?encryption=$enkey&flow=xtls-rprx-vision&security=reality&sni=$LITE_SNI_REALITY&fp=chrome&pbk=$public_key_x&sid=$short_id_x&type=xhttp&path=$uuid-xh&mode=stream-one&extra=$XMUX_EXTRA#VL-XHTTP-REALITY-ENC-$N"
l2="vless://$uuid@$server_ip:$port_vl_re?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$LITE_SNI_REALITY&fp=chrome&pbk=$public_key_x&sid=$short_id_x&type=tcp&headerType=none#VL-REALITY-VISION-$N"
l3="vless://$uuid@$server_ip:$port_vw?encryption=$enkey&flow=xtls-rprx-vision&type=ws&path=$uuid-vw#VL-WS-ENC-$N"
l4="vmess://$(printf '{"v":"2","ps":"VM-WS-%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/%s-vm","tls":""}' "$N" "$server_ip" "$port_vm_ws" "$uuid" "$LITE_SNI" "$uuid" | base64 -w0)"
l5="hysteria2://$uuid@$server_ip:$port_hy2?security=tls&alpn=h3&insecure=0&allowInsecure=0&mport=$LITE_HY2_MPORT&sni=$LITE_SNI&pinSHA256=$sha_hy2#HY2-$N"
l6="vless://$uuid@www.shopify.com:443?encryption=$enkey&flow=xtls-rprx-vision&type=ws&host=$argodomain&path=$uuid-vw&security=tls&sni=$argodomain&fp=chrome&insecure=0&allowInsecure=0#VLESS-WS-TLS-ARGO-ENC-VISION-$N"
l7="vless://$uuid@www.wto.org:80?encryption=$enkey&flow=xtls-rprx-vision&type=ws&host=$argodomain&path=$uuid-vw&security=none#VLESS-WS-ARGO-ENC-VISION-$N"
printf '%s\n' "$l1" "$l2" "$l3" "$l4" "$l5" "$l6" "$l7" > "$LITE_DIR/jhsub.txt"

# ---------------- 订阅服务（busybox httpd，独立目录/端口） ----------------
if [ -z "$LITE_SUB_TOKEN" ]; then
  if [ -s "$LITE_DIR/subtoken.log" ]; then LITE_SUB_TOKEN="$(cat "$LITE_DIR/subtoken.log")"
  else LITE_SUB_TOKEN="$uuid"; echo "$LITE_SUB_TOKEN" > "$LITE_DIR/subtoken.log"; fi
else
  echo "$LITE_SUB_TOKEN" > "$LITE_DIR/subtoken.log"
fi
if [ -z "$LITE_SUB_PORT" ]; then
  if [ -s "$LITE_DIR/subport.log" ]; then LITE_SUB_PORT="$(cat "$LITE_DIR/subport.log")"
  else
    while :; do LITE_SUB_PORT="$(shuf -i 10000-65535 -n 1)"; ss -tln 2>/dev/null | grep -q ":$LITE_SUB_PORT " || break; done
    echo "$LITE_SUB_PORT" > "$LITE_DIR/subport.log"
  fi
else
  echo "$LITE_SUB_PORT" > "$LITE_DIR/subport.log"
fi
mkdir -p "$LITE_DIR/websbx-lite/$LITE_SUB_TOKEN"
ln -sf "$LITE_DIR/jhsub.txt" "$LITE_DIR/websbx-lite/$LITE_SUB_TOKEN/jhsub.txt"
# 停掉本 lite 的旧 httpd（只杀自己的 -h 路径，不碰原版 websbx）
pkill -f "httpd.*$LITE_DIR/websbx-lite" 2>/dev/null || true
cat > "/etc/systemd/system/lite-sub-httpd.service" <<EOF
[Unit]
Description=lite-sub-httpd (argosbx-lite)
After=network.target
[Service]
Type=simple
ExecStart=$BUSYBOX httpd -f -p $LITE_SUB_PORT -h $LITE_DIR/websbx-lite
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload >/dev/null 2>&1
systemctl enable lite-sub-httpd >/dev/null 2>&1
systemctl restart lite-sub-httpd >/dev/null 2>&1

# ---------------- 输出 ----------------
suburl="http://$server_ip:$LITE_SUB_PORT/$LITE_SUB_TOKEN/jhsub.txt"
echo
echo "==================== 完成 ===================="
echo "订阅地址：$suburl"
echo
echo "6 条节点（逐条复制）："
printf '%s\n\n' "$l1" "$l2" "$l3" "$l4" "$l5" "$l6" "$l7"
echo "=============================================="
echo "试跑回滚：systemctl stop xray-lite sing-box-lite cloudflared-lite lite-sub-httpd；rm -rf $LITE_DIR"
