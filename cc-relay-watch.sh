#!/bin/bash
# CC 中转路径级验收（只读）：看 24443 入站已建立连接 + 到 RN 的出站连接 + 服务日志
echo "===== 1) 24443 入站已建立连接（应能看到你手机网络的来源 IP） ====="
ss -tnp | grep ':24443' || echo "暂无已建立连接"
echo "===== 2) 到 RN 12438 的出站连接 ====="
ss -tnp | grep '204.152.192.153:12438' || echo "暂无出站连接"
echo "===== 3) sing-box-relay 最近日志 25 行 ====="
journalctl -u sing-box-relay --no-pager -n 25
echo "===== 结束，把完整输出截图发我 ====="
