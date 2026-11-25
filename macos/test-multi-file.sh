#!/bin/bash
# 多文件端到端回归测试：一次拖选超过接收端并发会话上限（8 个）的文件，必须全部送达。
#
# 回归背景：接收端同时在收的文件数有上限（8），旧版发送端会把所有文件的
# 会话一次性全建起来，第 9 个文件被拒（HTTP 429）后整个传输失败。
# 现在发送端改成分批建会话，这个测试用真实 App 跑一遍，验证多文件不再失败。
#
# 所有临时文件都在项目内 .test-tmp/，不写 /tmp。
set -e
cd "$(dirname "$0")"

ROOT="$(pwd)"
TMP="$ROOT/.test-tmp"
BIN="$ROOT/.build/release/MoonDrop"
P1=52411
P2=52412
RX_NAME="MoonDropTestRx"
TX_NAME="MoonDropTestTx"
WORK="$TMP/multi-$$"
RECV_DIR="$WORK/received"
TX_DIR="$WORK/sender"
SRC_DIR="$WORK/src"
RX_PID=""; TX_PID=""

# 文件数量必须大于接收端的并发会话上限（8），否则测不到这个 bug
# 可以用第一个参数覆盖，方便定位问题从几个文件开始出现
FILE_COUNT=${1:-12}

cleanup() {
    for pid in $RX_PID $TX_PID; do
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
    done
    for pid in $RX_PID $TX_PID; do
        [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$RECV_DIR" "$TX_DIR" "$SRC_DIR"

echo "==> 准备 $FILE_COUNT 个测试文件（含空文件与多块文件）"
/usr/bin/python3 - "$SRC_DIR" "$FILE_COUNT" <<'PYEOF'
import sys, os
d, n = sys.argv[1], int(sys.argv[2])
for i in range(n):
    path = os.path.join(d, "multi-%02d.bin" % i)
    if i == 0:
        data = b""                       # 空文件：走「没有分块，直接收尾」那条路
    elif i == 1:
        data = bytes(range(256)) * 20000 # 5 MB：跨多个 2 MiB 分块
    else:
        data = ("payload-%02d-" % i).encode() * (100 + i * 37)
    with open(path, "wb") as f:
        f.write(data)
print("  生成 %d 个文件" % n)
PYEOF

# 期望的校验和，先算好，传输后逐个比对
EXPECT="$WORK/expected.sha"
( cd "$SRC_DIR" && shasum -a 256 ./*.bin ) > "$EXPECT"

echo "==> 启动接收端（$RX_NAME，端口 $P1，自动确认）"
MACDROP_RECV_DIR="$RECV_DIR" MACDROP_PORT=$P1 MACDROP_NAME="$RX_NAME" MACDROP_ID="test-rx-$$" \
    MACDROP_AUTO_ACCEPT=1 "$BIN" > "$WORK/rx.log" 2>&1 &
RX_PID=$!
sleep 2

if ! kill -0 $RX_PID 2>/dev/null; then
    echo "✗ 接收端启动失败，日志："; cat "$WORK/rx.log"; exit 1
fi
if ! lsof -nP -iTCP:$P1 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "✗ 接收端端口 $P1 未监听，日志："; cat "$WORK/rx.log"; exit 1
fi
echo "✓ 接收端已监听 127.0.0.1:$P1 (pid=$RX_PID)"

echo "==> 启动发送端（$TX_NAME，端口 $P2，发现 $RX_NAME 后自动发送 $FILE_COUNT 个文件）"
PATHS=$(ls -1 "$SRC_DIR"/*.bin | paste -sd, -)
MACDROP_RECV_DIR="$TX_DIR" MACDROP_PORT=$P2 MACDROP_NAME="$TX_NAME" MACDROP_ID="test-tx-$$" \
    MACDROP_AUTO_SEND="$RX_NAME:$PATHS" \
    "$BIN" > "$WORK/tx.log" 2>&1 &
TX_PID=$!
sleep 2

if ! kill -0 $TX_PID 2>/dev/null; then
    echo "✗ 发送端启动失败，日志："; cat "$WORK/tx.log"; exit 1
fi
echo "✓ 发送端已启动 (pid=$TX_PID)"

echo "==> 等待接收端收齐 $FILE_COUNT 个文件（最多 90 秒）"
DEADLINE=$(( $(date +%s) + 90 ))
RECEIVED=0
while [ $(date +%s) -lt $DEADLINE ]; do
    RECEIVED=$(ls -1 "$RECV_DIR" 2>/dev/null | grep -c '\.bin$' || true)
    [ "$RECEIVED" -ge "$FILE_COUNT" ] && break
    sleep 1
done

if [ "$RECEIVED" -lt "$FILE_COUNT" ]; then
    echo "✗ 只收到 $RECEIVED / $FILE_COUNT 个文件"
    echo "  接收端日志："; grep "MoonDrop" "$WORK/rx.log" | tail -15 | sed 's/^/    /'
    echo "  发送端日志："; grep "MoonDrop" "$WORK/tx.log" | tail -15 | sed 's/^/    /'
    exit 1
fi
echo "✓ 收到 $RECEIVED 个文件"

echo "==> 校验内容"
FAIL=0
while read -r hash path; do
    name=$(basename "$path")
    got="$RECV_DIR/$name"
    if [ ! -f "$got" ]; then
        echo "  ✗ 缺文件：$name"; FAIL=1; continue
    fi
    got_hash=$(shasum -a 256 "$got" | awk '{print $1}')
    if [ "$hash" != "$got_hash" ]; then
        echo "  ✗ 内容不一致：$name"; FAIL=1
    fi
done < "$EXPECT"

if [ "$FAIL" -ne 0 ]; then
    echo "✗ 多文件传输校验失败"
    exit 1
fi
echo "✓ $FILE_COUNT 个文件内容全部一致"

echo
echo "==> 接收端有没有撞上并发上限（HTTP 429）"
if grep -q "429" "$WORK/rx.log"; then
    echo "  ✗ 接收端返回过 429（同时接收的文件过多）"
    grep "429" "$WORK/rx.log" | sed 's/^/    /'
    exit 1
fi
echo "  ✓ 没有 429"

echo
echo "==> 发送端日志"
grep "MoonDrop" "$WORK/tx.log" | tail -8 | sed 's/^/  /'

echo
echo "==> 接收端日志"
grep "MoonDrop" "$WORK/rx.log" | tail -8 | sed 's/^/  /'

rm -rf "$WORK"
echo
echo "==> 测试完成（临时文件已清理）"
