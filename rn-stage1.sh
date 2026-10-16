#!/bin/bash
# RN 第一步：系统层调优（与 CC 试验田第一步同款）
# BBR + fq + TCP/UDP 缓冲拉满；幂等，可回滚：删 /etc/sysctl.d/99-opt.conf 后 sysctl --system
set -u
cat > /etc/sysctl.d/99-opt.conf << 'CONF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=4194304
net.core.wmem_default=4194304
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.core.netdev_max_backlog=16384
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
CONF
echo tcp_bbr > /etc/modules-load.d/bbr.conf
modprobe tcp_bbr 2>/dev/null
sysctl --system >/dev/null 2>&1
echo "===== 验证 ====="
echo "拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "队列规则: $(sysctl -n net.core.default_qdisc)"
echo "rmem_max: $(sysctl -n net.core.rmem_max)"
echo "wmem_max: $(sysctl -n net.core.wmem_max)"
echo "第一步完成（无重启、不断线）"
