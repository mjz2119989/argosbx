#!/bin/bash
# CC 中转门诊断（只读）：服务状态 + 24443 监听 + 到 RN 落地口连通 + 最近日志
echo "===== 1) 中转服务状态 ====="
systemctl is-active sing-box-relay 2>&1
systemctl status sing-box-relay --no-pager -n 5 2>&1 | head -20
echo "===== 2) 24443 是否在监听 ====="
ss -tlnp 2>/dev/null | grep 24443 || echo "没找到 24443 监听！"
echo "===== 3) CC 到 RN 落地口 12438 连通性 ====="
timeout 6 bash -c 'echo > /dev/tcp/204.152.192.153/12438' 2>/dev/null && echo "12438 TCP 可达" || echo "12438 TCP 不可达！"
echo "===== 4) 中转服务最近日志（重点看出站报错） ====="
journalctl -u sing-box-relay --no-pager -n 60 2>&1 | tail -60
echo "===== 诊断结束，把完整输出截图发我 ====="
