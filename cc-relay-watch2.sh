#!/bin/bash
# xray 版中转路径级验收（只读）：看 access 日志里手机连接的 accepted 记录 + 24443 当前连接
echo "===== 1) access 日志最近 15 行（找你手机 IP 的 accepted） ====="
tail -15 /var/log/xray-relay/access.log 2>/dev/null || echo "access 日志暂无"
echo "===== 2) error 日志最近 10 行 ====="
tail -10 /var/log/xray-relay/error.log 2>/dev/null || echo "error 日志暂无"
echo "===== 3) 24443 当前已建立连接 ====="
ss -tnp | grep ':24443' || echo "暂无已建立连接"
echo "===== 结束，把完整输出截图发我 ====="
