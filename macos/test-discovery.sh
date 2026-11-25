#!/bin/bash
# 双实例互相发现测试：模拟两台 Mac，验证 Bonjour 能互相看到对方，且不会自发现。
# 所有临时文件都在项目内 .test-tmp/，不写 /tmp。
set -e
cd "$(dirname "$0")"

ROOT="$(pwd)"
TMP="$ROOT/.test-tmp"
BIN="$ROOT/.build/release/MoonDrop"
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
# AUTO_ACCEPT：接收前确认需要人点「接收」，无头测试里没人点，会一直停在 202
MACDROP_RECV_DIR="$D1" MACDROP_PORT=$P1 MACDROP_NAME="PeerA" MACDROP_ID="test-id-A" MACDROP_AUTO_ACCEPT=1 \
    "$BIN" > "$TMP/peerA.log" 2>&1 &
A=$!
sleep 1.5

echo "==> 启动 Peer B（$P2）"
MACDROP_RECV_DIR="$D2" MACDROP_PORT=$P2 MACDROP_NAME="PeerB" MACDROP_ID="test-id-B" MACDROP_AUTO_ACCEPT=1 \
    "$BIN" > "$TMP/peerB.log" 2>&1 &
B=$!
sleep 3

echo
echo "==> Peer A 日志"
grep "MoonDrop" "$TMP/peerA.log" | sed 's/^/  /'
echo
echo "==> Peer B 日志"
grep "MoonDrop" "$TMP/peerB.log" | sed 's/^/  /'

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
# 判断标准用「解析成功的地址+端口」而不是名字：本机实例被 Bonjour 改名后
# 名字不可预测，但端口一定等于自己监听的端口。
if grep -q "解析对端.*:$P1" "$TMP/peerA.log"; then
    echo "  ✗ A 把自己解析成了对端"
    grep "解析对端" "$TMP/peerA.log" | sed 's/^/      /'
else
    echo "  ✓ A 没有自发现"
fi
if grep -q "解析对端.*:$P2" "$TMP/peerB.log"; then
    echo "  ✗ B 把自己解析成了对端"
    grep "解析对端" "$TMP/peerB.log" | sed 's/^/      /'
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
# 接收前确认协议：begin 先回 202 等对方确认，确认后才回 200 并建暂存。
# 这里必须轮询到 200 再发分块，否则 chunk 会拿到 404（未知传输 ID）。
# 整段放进 if 里：跨实例传输失败也要继续跑后面的验证，不能让 set -e 把脚本掐断。
if ! /usr/bin/python3 - "$P1" "$SRC" <<'PYEOF'
import sys, urllib.request, urllib.parse, urllib.error, uuid, os, time

port, path = sys.argv[1], sys.argv[2]
tid = str(uuid.uuid4()); base = f"http://127.0.0.1:{port}"
name = os.path.basename(path); size = os.path.getsize(path)

def post(url, data=None):
    req = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code

q = urllib.parse.urlencode({"name": name, "path": name, "size": str(size), "root": "",
                            "batch": str(uuid.uuid4()), "from": "PeerB",
                            "files": "1", "bytes": str(size)})
url = f"{base}/macdrop/begin?id={tid}&{q}"
deadline = time.time() + 30
status = 0
while time.time() < deadline:
    status = post(url)
    if status == 200:
        break
    if status != 202:
        print(f"  begin 返回意外状态 {status}")
        sys.exit(1)
    time.sleep(0.2)
else:
    print("  begin 30 秒内没等到确认通过")
    sys.exit(1)

data = open(path, "rb").read(); off = 0
while off < len(data):
    c = data[off:off + 2 * 1024 * 1024]
    s = post(f"{base}/macdrop/chunk?id={tid}&offset={off}", c)
    if s != 200:
        print(f"  chunk offset={off} 返回 {s}")
        sys.exit(1)
    off += len(c)

s = post(f"{base}/macdrop/finish?id={tid}")
if s != 200:
    print(f"  finish 返回 {s}")
    sys.exit(1)
print(f"  已推送 {size} 字节到 Peer A")
PYEOF
then
    echo "  ✗ 跨实例传输失败"
else
    sleep 1
    if [ -f "$D1/$(basename "$SRC")" ]; then
        echo "  ✓ Peer A 落盘成功：$D1/$(basename "$SRC")"
        head -1 "$D1/$(basename "$SRC")" | sed 's/^/    内容首行: /'
    else
        echo "  ✗ Peer A 未落盘"; ls -la "$D1" || true
    fi
fi

kill $A $B 2>/dev/null || true
# wait 回收后台任务，否则 bash 会把 SIGTERM 的 "Terminated" 打到输出里
wait "$A" "$B" 2>/dev/null || true
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

MACDROP_RECV_DIR="$SD1" MACDROP_PORT=$SP1 MACDROP_NAME="MacBook Pro" MACDROP_ID="same-a" "$BIN" > "$TMP/same-a.log" 2>&1 &
SA=$!
sleep 1
MACDROP_RECV_DIR="$SD2" MACDROP_PORT=$SP2 MACDROP_NAME="MacBook Pro" MACDROP_ID="same-b" "$BIN" > "$TMP/same-b.log" 2>&1 &
SB=$!
# 同名撞车要「失败两次 → 换名 → 重发」，两轮退避各 2 秒，加上发现与解析留出余量
sleep 9

echo
echo "==> 同名实例的广播日志"
grep -E "广告" "$TMP/same-a.log" "$TMP/same-b.log" | sed 's/^/  /'

A_FOUND_B=$(grep -c "解析对端 MacBook Pro.*:$SP2" "$TMP/same-a.log" || true)
B_FOUND_A=$(grep -c "解析对端 MacBook Pro.*:$SP1" "$TMP/same-b.log" || true)

if [ "$A_FOUND_B" -gt 0 ]; then echo "  ✓ 同名下 A 解析到了 B"; else
    echo "  ✗ 同名下 A 没解析到 B（同名撞车未自愈）"; grep 解析对端 "$TMP/same-a.log" | sed 's/^/      /'; fi
if [ "$B_FOUND_A" -gt 0 ]; then echo "  ✓ 同名下 B 解析到了 A"; else
    echo "  ✗ 同名下 B 没解析到 A（同名过滤 bug 回归）"; grep 解析对端 "$TMP/same-b.log" | sed 's/^/      /'; fi

# 各自都不能把自己算进去：解析到的端口只能是对方的
if grep -q "解析对端.*:$SP1" "$TMP/same-a.log"; then
    echo "  ✗ 同名下 A 把自己也当成了对端"
else
    echo "  ✓ 同名下 A 正确排除了自己"
fi
if grep -q "解析对端.*:$SP2" "$TMP/same-b.log"; then
    echo "  ✗ 同名下 B 把自己也当成了对端"
else
    echo "  ✓ 同名下 B 正确排除了自己"
fi

if grep -q "Bonjour 广告已上线" "$TMP/same-a.log" && grep -q "Bonjour 广告已上线" "$TMP/same-b.log"; then
    echo "  ✓ 两台同名机器的广播都成功上线（TXT id 不同）"
else
    echo "  ✗ 有实例广播未上线，见日志"
fi

kill $SA $SB 2>/dev/null || true
wait "$SA" "$SB" 2>/dev/null || true
SA=""; SB=""
sleep 0.5
rm -rf "$SD1" "$SD2" "$D1" "$D2"

echo
echo "==> 完成（临时文件都在项目 .test-tmp/，可整体删掉）"
