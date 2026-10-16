#!/bin/bash
# RN 第二步（sing-box 版）：Hy2 brutal 补丁
# RN 的 Hy2 由 sing-box 承载（sb.json，2026-10-16 实查定案），补丁 = hysteria2 入站加 up_mbps/down_mbps（sing-box 的 brutal 开关）
# 安全设计：改前备份（只备一次）；sing-box check 校验不过自动还原且不重启；可重复执行
# 注意：小钢炮 rep 重建会覆盖配置，重建后需重打
set -u
CFG=$(ps -ef | grep 'agsbx/sing-box run' | grep -v grep | sed -n 's/.*-c \([^ ]*\).*/\1/p' | head -1)
BIN=$(ps -ef | grep 'agsbx/sing-box run' | grep -v grep | awk '{print $8}' | head -1)
[ -n "$CFG" ] && [ -f "$CFG" ] || { echo "找不到 sing-box 运行配置，停"; exit 1; }
[ -n "$BIN" ] && [ -x "$BIN" ] || BIN="$HOME/agsbx/sing-box"
echo "目标配置: $CFG | 程序: $BIN"
[ -f "$CFG.bak-stage2" ] || cp "$CFG" "$CFG.bak-stage2"

python3 - "$CFG" << 'PYEOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
hit = 0
port = None
for ib in cfg.get("inbounds", []):
    if ib.get("type") == "hysteria2":
        ib["up_mbps"] = 100
        ib["down_mbps"] = 100
        hit += 1
        port = ib.get("listen_port")
print("hysteria2 inbound 命中:", hit, "| 监听端口:", port)
if hit == 0:
    sys.exit(2)
json.dump(cfg, open(p, "w"), indent=2, ensure_ascii=False)
PYEOF
if [ $? -ne 0 ]; then echo "改配置失败，已还原"; cp "$CFG.bak-stage2" "$CFG"; exit 1; fi

if ! "$BIN" check -c "$CFG" >/dev/null 2>&1; then
  echo "sing-box 配置校验不过，已还原（未重启）"; cp "$CFG.bak-stage2" "$CFG"; exit 1
fi
echo "配置校验通过，重启 sing-box 生效（sing-box 承载的节点断几秒，xray 的不受影响）..."
pkill -f 'agsbx/sing-box run' 2>/dev/null; sleep 1
nohup "$BIN" run -c "$CFG" >/dev/null 2>&1 &
sleep 2
echo "===== 验证 ====="
ps -ef | grep 'agsbx/sing-box run' | grep -v grep || echo "(sing-box 进程没看到，注意)"
ss -ulnp 2>/dev/null | grep 35444 || echo "(35444 没在监听，注意)"
grep -o '"up_mbps": 100' "$CFG" | head -1
echo "回滚方法: cp $CFG.bak-stage2 $CFG 后, pkill -f 'agsbx/sing-box run'; nohup $BIN run -c $CFG >/dev/null 2>&1 &"
