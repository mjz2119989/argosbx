#!/bin/bash
# RN 三网回程检测：oneclickvirt/backtrace 封装（幂等，只读诊断，不动任何现有配置）
# 装工具 -> 跑一次 -> 结果存 /root/backtrace-result.txt
cd /root || exit 1
if ! command -v backtrace >/dev/null 2>&1 && [ ! -x /root/backtrace/backtrace ] && [ ! -x /usr/bin/backtrace ]; then
  echo "正在安装 backtrace（三网回程检测工具）..."
  curl https://raw.githubusercontent.com/oneclickvirt/backtrace/main/backtrace_install.sh -sSf | bash || \
  curl https://cdn.spiritlhl.net/https://raw.githubusercontent.com/oneclickvirt/backtrace/main/backtrace_install.sh -sSf | bash
fi
BT=$(command -v backtrace || true)
[ -z "$BT" ] && [ -x /usr/bin/backtrace ] && BT=/usr/bin/backtrace
[ -z "$BT" ] && [ -x /root/backtrace/backtrace ] && BT=/root/backtrace/backtrace
[ -z "$BT" ] && [ -x /root/backtrace ] && BT=/root/backtrace
if [ -z "$BT" ]; then
  echo "安装失败：找不到 backtrace 程序，把这段输出截图发我。"
  exit 1
fi
echo "开始三网回程检测，大约需要一到三分钟，请等它自己跑完..."
"$BT" 2>&1 | tee /root/backtrace-result.txt
echo "==== 检测完成，结果已存 /root/backtrace-result.txt，把完整输出截图发我 ===="
