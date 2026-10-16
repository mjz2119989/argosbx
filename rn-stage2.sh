#!/bin/bash
# RN 第二步：Hy2 force-brutal 补丁（xray finalmask.quicParams）
# RN 原版 Hy2 已带 DNAT 端口跳跃（mport 已在订阅里），本补丁只加拥塞控制+接收窗，不动跳跃
# 安全设计：改前备份（只备一次）；xray run -test 校验不过自动还原且不重启；可重复执行
# 注意：小钢炮 rep 重建会覆盖 xr.json，重建后需重打
set -u
XR="$HOME/agsbx/xr.json"
BIN="$HOME/agsbx/xray"
[ -f "$XR" ] || { echo "找不到 $XR ，停"; exit 1; }
[ -f "$XR.bak-stage2" ] || cp "$XR" "$XR.bak-stage2"

python3 - "$XR" << 'PYEOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
hit = 0
port = None
for ib in cfg.get("inbounds", []):
    if ib.get("tag") == "hy2-xr" or ib.get("protocol") == "hysteria":
        ss = ib.setdefault("streamSettings", {})
        fm = ss.setdefault("finalmask", {})
        fm["quicParams"] = {
            "congestion": "force-brutal",
            "brutalUp": "100 mbps",
            "brutalDown": "100 mbps",
            "initStreamReceiveWindow": 8388608,
            "maxStreamReceiveWindow": 8388608,
            "initConnectionReceiveWindow": 20971520,
            "maxConnectionReceiveWindow": 20971520
        }
        hit += 1
        port = ib.get("port")
print("hy2 inbound 命中:", hit, "| 监听端口:", port)
if hit == 0:
    sys.exit(2)
json.dump(cfg, open(p, "w"), indent=2, ensure_ascii=False)
PYEOF
if [ $? -ne 0 ]; then echo "改配置失败，已还原"; cp "$XR.bak-stage2" "$XR"; exit 1; fi

if ! "$BIN" run -test -config "$XR" >/dev/null 2>&1; then
  echo "xray 配置校验不过，已还原（未重启）"; cp "$XR.bak-stage2" "$XR"; exit 1
fi
echo "配置校验通过，重启 xray 生效（全部节点断几秒）..."
pkill -f 'agsbx/xray run' 2>/dev/null; sleep 1
nohup "$BIN" run -c "$XR" >/dev/null 2>&1 &
sleep 2
echo "===== 验证 ====="
ps -ef | grep 'agsbx/xray run' | grep -v grep || echo "(xray 进程没看到，注意)"
grep -o '"congestion": "force-brutal"' "$XR" | head -1
echo "回滚方法: cp $XR.bak-stage2 $XR 后, pkill -f 'agsbx/xray run'; nohup $BIN run -c $XR >/dev/null 2>&1 &"
