#!/bin/bash
# 打印中转 Reality 公钥的十六进制编码（只读）：避免截图肉眼读错字符
. /etc/sing-box-relay/keys.env
echo "PUB 字符数（应为 43）: ${#PUB}"
echo "PUB 十六进制（把这一长串截图发我）:"
printf %s "$PUB" | od -An -tx1 | tr -d ' \n'
echo
echo "（上面每个字符只可能是 0-9 或 a-f，不会认错）"
