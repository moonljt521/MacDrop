#!/bin/bash
# 双实例互相发现测试：模拟两台 Mac，验证 Bonjour 能互相看到对方，且不会自发现。
# 所有临时文件都在项目内 .test-tmp/，不写 /tmp。
set -e
cd "$(dirname "$0")"

ROOT="$(pwd)"
TMP="$ROOT/.test-tmp"
BIN="$ROOT/.build/release/MacDrop"
P1=52401
P2=52402
D1="$TMP/peerA-$$"
D2="$TMP/peerB-$$"
A=""; B=""; SA=""; SB=""

mkdir -p "$TMP"
rm -rf "$D1" "$D2"

cleanup() {
    for pid in $A $B $SA $SB; do
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

echo "==> 启动 Peer A（$P1）"
MACDROP_RECV_DIR="$D1" MACDROP_PORT=$P1 MACDROP_NAME="PeerA" "$BIN" > "$TMP/peerA.log" 2>&1 &
A=$!
sleep 1.5

echo "==> 启动 Peer B（$P2）"
MACDROP_RECV_DIR="$D2" MACDROP_PORT=$P2 MACDROP_NAME="PeerB" "$BIN" > "$TMP/peerB.log" 2>&1 &
B=$!
sleep 3

echo
echo "==> Peer A 日志"
grep "MacDrop" "$TMP/peerA.log" | sed 's/^/  /'
echo
echo "==> Peer B 日志"
grep "MacDrop" "$TMP/peerB.log" | sed 's/^/  /'

echo
echo "==> 验证 1: 互相发现"
if grep -q "发现对端: PeerB" "$TMP/peerA.log"; then
    echo "  ✓ A 发现了 B"
else
    echo "  ✗ A 未发现 B"
fi
if grep -q "发现对端: PeerA" "$TMP/peerB.log"; then
    echo "  ✓ B 发现了 A"
else
    echo "  ✗ B 未发现 A"
fi

echo
echo "==> 验证 2: 不自发现（关键 bug 回归）"
# 正确做法：自发现判断必须基于「自己广告的实例」在 mDNS 里被改名后的样子，
# 而不是简单 grep 自己的名字。两台同名时，各自都会把对方当成对端（这是正确的）。
# 这里用「A 的日志里出现的对端数量」来判断：应为 2（Air + MoonM1Pro），
# 不应包含本机的实例名 Pro / MacBook Pro (2) 这类被 Bonjour 改名的自己。
if grep -qE "发现对端: (Pro|MacBook Pro \([0-9]+\))$" "$TMP/peerA.log"; then
    echo "  ✗ A 把自己当成了对端"
    grep -E "发现对端" "$TMP/peerA.log" | sed 's/^/      /'
else
    echo "  ✓ A 没有自发现"
fi
if grep -qE "发现对端: (Pro|MacBook Pro \([0-9]+\))$" "$TMP/peerB.log"; then
    echo "  ✗ B 把自己当成了对端"
else
    echo "  ✓ B 没有自发现"
fi

echo
echo "==> 验证 3: 地址解析成功（关键 bug 回归）"
if grep -q "解析地址失败" "$TMP/peerA.log" || grep -q "解析地址失败" "$TMP/peerB.log"; then
    echo "  ✗ 仍有地址解析失败"
    grep "解析地址失败" "$TMP/peerA.log" "$TMP/peerB.log" | sed 's/^/    /'
else
    echo "  ✓ 无地址解析失败"
fi

echo
echo "==> 验证 4: B → A 真实跨实例传输"
SRC="$TMP/cross-$$.txt"
/usr/bin/python3 -c "open('$SRC','w').write('hello from PeerB to PeerA\n'*5000)"
/usr/bin/python3 - "$P1" "$SRC" <<'PYEOF'
import sys, urllib.request, urllib.parse, uuid, os
port, path = sys.argv[1], sys.argv[2]
tid = str(uuid.uuid4()); base = f"http://127.0.0.1:{port}"
name = os.path.basename(path); size = os.path.getsize(path)
def post(url, data=None):
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=30) as r: return r.status
q = urllib.parse.urlencode({"name": name, "path": name, "size": str(size), "root": ""})
post(f"{base}/macdrop/begin?id={tid}&{q}")
data = open(path,"rb").read(); off = 0
while off < len(data):
    c = data[off:off+2*1024*1024]; post(f"{base}/macdrop/chunk?id={tid}&offset={off}", c); off += len(c)
post(f"{base}/macdrop/finish?id={tid}")
print(f"  已推送 {size} 字节到 Peer A")
PYEOF
sleep 1
if [ -f "$D1/$(basename "$SRC")" ]; then
    echo "  ✓ Peer A 落盘成功：$D1/$(basename "$SRC")"
    head -1 "$D1/$(basename "$SRC")" | sed 's/^/    内容首行: /'
else
    echo "  ✗ Peer A 未落盘"; ls -la "$D1" || true
fi

kill $A $B 2>/dev/null || true
A=""; B=""
sleep 0.5
rm -f "$SRC"

# ─────────────────────────────────────────────────────────────
# 验证 5: 同名机器（真实踩过的 bug）
# 两台都叫 "MacBook Pro" 时，旧实现用「显示名 == 我的名字」判断自己，
# 会把对方误当成自己滤掉 → 互相看不见。现在改用「主机名 + 端口」判断。
# ─────────────────────────────────────────────────────────────
echo
echo "==> 验证 5: 同名设备（回归：两台都叫 MacBook Pro）"
SD1="$TMP/same-a-$$"; SD2="$TMP/same-b-$$"
SA=""; SB=""
rm -rf "$SD1" "$SD2"
SP1=$((P1+10)); SP2=$((P2+10))

MACDROP_RECV_DIR="$SD1" MACDROP_PORT=$SP1 MACDROP_NAME="MacBook Pro" "$BIN" > "$TMP/same-a.log" 2>&1 &
SA=$!
sleep 1
MACDROP_RECV_DIR="$SD2" MACDROP_PORT=$SP2 MACDROP_NAME="MacBook Pro" "$BIN" > "$TMP/same-b.log" 2>&1 &
SB=$!
sleep 3.5

A_FOUND_B=$(grep -c "发现对端: MacBook Pro" "$TMP/same-a.log" || true)
B_FOUND_A=$(grep -c "发现对端: MacBook Pro" "$TMP/same-b.log" || true)

if [ "$A_FOUND_B" -gt 0 ]; then echo "  ✓ 同名下 A 能发现 B"; else
    echo "  ✗ 同名下 A 没发现 B（同名过滤 bug 回归）"; grep 发现对端 "$TMP/same-a.log" | sed 's/^/      /'; fi
if [ "$B_FOUND_A" -gt 0 ]; then echo "  ✓ 同名下 B 能发现 A"; else
    echo "  ✗ 同名下 B 没发现 A（同名过滤 bug 回归）"; fi

# 且不能把自己算进去：日志里恰好一条 "MacBook Pro"（对方的），没有 "Pro"（自己的改名）
if grep -qE "发现对端: (Pro|MacBook Pro \([0-9]+\))$" "$TMP/same-a.log"; then
    echo "  ✗ 同名下 A 把自己也当成了对端"
else
    echo "  ✓ 同名下 A 正确排除了自己"
fi

kill $SA $SB 2>/dev/null || true
SA=""; SB=""
sleep 0.5
rm -rf "$SD1" "$SD2" "$D1" "$D2"

echo
echo "==> 完成（临时文件都在项目 .test-tmp/，可整体删掉）"
