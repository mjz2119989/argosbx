#!/bin/bash
# CC 试验田第二步 v2（xray 版）：Hy2 force-brutal + 原生端口跳跃
# 依据：Xray 官方文档 FinalMask.quicParams（congestion/brutalUp/brutalDown/udpHop）
# 目标文件：/root/agsbx/xr.json 中 tag=hy2-xr 的入站（CC 的 Hy2 由 xray 承载，2026-10-16 实查定案）
# 安全设计：改前备份；xray run -test 校验不过自动还原且不重启；可重复执行
# 注意：小钢炮 rep 重建会覆盖 xr.json，本补丁属试验性质，重建后需重打
set -u
XR="$HOME/agsbx/xr.json"
BIN="$HOME/agsbx/xray"
[ -f "$XR" ] || { echo "找不到 $XR ，停"; exit 1; }
# 只备份一次：重复运行不覆盖原始备份，保住回滚点
[ -f "$XR.bak-stage2" ] || cp "$XR" "$XR.bak-stage2"

python3 - "$XR" << 'PYEOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
hit = 0
for ib in cfg.get("inbounds", []):
    if ib.get("tag") == "hy2-xr" or ib.get("protocol") == "hysteria":
        ss = ib.setdefault("streamSettings", {})
        fm = ss.setdefault("finalmask", {})
        fm["quicParams"] = {
            "congestion": "force-brutal",
            "brutalUp": "100 mbps",
            "brutalDown": "100 mbps",
            "udpHop": {"ports": "31000-31100", "interval": "15-30"},
            "initStreamReceiveWindow": 8388608,
            "maxStreamReceiveWindow": 8388608,
            "initConnectionReceiveWindow": 20971520,
            "maxConnectionReceiveWindow": 20971520
        }
        hit += 1
print("hy2 inbound 命中:", hit)
if hit == 0:
    sys.exit(2)
json.dump(cfg, open(p, "w"), indent=2, ensure_ascii=False)
PYEOF
if [ $? -ne 0 ]; then echo "改配置失败，已还原"; cp "$XR.bak-stage2" "$XR"; exit 1; fi

if ! "$BIN" run -test -config "$XR" >/dev/null 2>&1; then
  echo "xray 配置校验不过，已还原（未重启）"; cp "$XR.bak-stage2" "$XR"; exit 1
fi
echo "配置校验通过，重启 xray 生效..."
pkill -f 'agsbx/xray run' 2>/dev/null; sleep 1
nohup "$BIN" run -c "$XR" >/dev/null 2>&1 &
sleep 2
echo "===== 验证 ====="
ps -ef | grep 'agsbx/xray run' | grep -v grep || echo "(xray 进程没看到，注意)"
ss -ulnp 2>/dev/null | grep -E '21346|3100[0-9]|310[0-9][0-9]|31100' | head -5 || echo "(ss 没看到监听，注意)"
grep -o '"congestion": "force-brutal"' "$XR" | head -1
echo "回滚方法: cp $XR.bak-stage2 $XR 后, pkill -f 'agsbx/xray run'; nohup $BIN run -c $XR >/dev/null 2>&1 &"
