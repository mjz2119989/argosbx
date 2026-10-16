#!/bin/bash
# 只读检查：打印 RN 的 xhttp 入站配置现状（不修改任何东西）
python3 - << 'PYEOF'
import json
try:
    cfg = json.load(open("/root/agsbx/xr.json"))
except Exception as e:
    print("读 xr.json 失败:", e); raise SystemExit
n = 0
for ib in cfg.get("inbounds", []):
    ss = ib.get("streamSettings", {})
    if ss.get("network") == "xhttp" or "xhttp" in str(ib.get("tag", "")):
        n += 1
        print("=== xhttp 入站:", ib.get("tag"), "| 端口:", ib.get("port"), "===")
        print(json.dumps(ss.get("xhttpSettings", {}), indent=1, ensure_ascii=False))
print("xhttp 入站总数:", n)
PYEOF
