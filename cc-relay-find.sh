#!/bin/bash
# CC 中转门遗骸盘点（只读，不改任何东西）：找二进制、配置、单元残留、进程
echo "===== 1) sing-box 相关二进制 ====="
ls -l /usr/local/bin/ 2>/dev/null | grep -i sing || echo "/usr/local/bin 下没有 sing 开头的文件"
which sing-box sing-box-relay 2>/dev/null
echo "===== 2) 中转配置目录 ====="
ls -la /etc/sing-box-relay/ 2>/dev/null || echo "/etc/sing-box-relay 不存在"
echo "===== 3) /etc 与 /root 下带 relay 的文件 ====="
find /etc /root -maxdepth 3 -iname '*relay*' 2>/dev/null || true
echo "===== 4) systemd 单元残留 ====="
ls /etc/systemd/system/ 2>/dev/null | grep -i relay || echo "没有 relay 单元文件"
systemctl list-unit-files 2>/dev/null | grep -i relay || echo "unit-files 里也没有"
echo "===== 5) sing-box 相关进程 ====="
ps aux | grep -i sing | grep -v grep || echo "没有任何 sing 进程在跑"
echo "===== 盘点结束，把完整输出截图发我 ====="
