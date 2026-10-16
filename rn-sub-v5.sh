#!/bin/bash
# RN 订阅更新（拉仓库最新版）：备份一次 -> 拉仓库版 -> 验行数
[ -f /root/agsbx/jhsub.txt.bak-v4 ] || cp /root/agsbx/jhsub.txt /root/agsbx/jhsub.txt.bak-v4
curl -sL --max-time 60 https://raw.githubusercontent.com/mjz2119989/argosbx/main/rn-jhsub.txt -o /root/agsbx/jhsub.txt
echo "行数（应为 8）: $(wc -l < /root/agsbx/jhsub.txt)"
echo "RELAY 行数（应为 2）: $(grep -c 'RELAY-' /root/agsbx/jhsub.txt)"
echo "==== 完成，回小火箭刷新 RN 订阅 ===="
