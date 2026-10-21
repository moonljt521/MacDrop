#!/bin/bash
# 端到端传输测试：起一个 MoonDrop 实例当接收端，用真实 HTTP 协议推送文件，校验落盘与内容一致性。
# 所有临时文件都在项目内 .test-tmp/，不写 /tmp。
set -e
cd "$(dirname "$0")"

PORT=${1:-52399}
ROOT="$(pwd)"
TMP="$ROOT/.test-tmp"
RECV_DIR="$TMP/e2e-$$"
BIN="$ROOT/.build/release/MoonDrop"
RECV_PID=""

mkdir -p "$RECV_DIR"
cleanup() {
    if [ -n "$RECV_PID" ] && kill -0 "$RECV_PID" 2>/dev/null; then
        kill "$RECV_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "==> 测试目录 $RECV_DIR（项目内）"

echo "==> 启动接收端（端口 $PORT）"
MACDROP_RECV_DIR="$RECV_DIR" MACDROP_PORT="$PORT" MACDROP_NAME="TestReceiver" \
    "$BIN" > "$TMP/e2e.log" 2>&1 &
RECV_PID=$!
sleep 2

if ! kill -0 $RECV_PID 2>/dev/null; then
    echo "✗ 接收端启动失败，日志："; cat "$TMP/e2e.log"; exit 1
fi

if ! lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "✗ 端口 $PORT 未监听，日志："; cat "$TMP/e2e.log"; exit 1
fi
echo "✓ 接收端已监听 127.0.0.1:$PORT (pid=$RECV_PID)"

# 造测试文件（~10MB，跨 6 个分块）
TEST_FILE="$TMP/src-$$.bin"
/usr/bin/python3 -c "
import os
with open('$TEST_FILE','wb') as f:
    for i in range(12):
        f.write(('chunk-%02d-' % i).encode() * 100000)
print('  生成测试文件 %.2f MB' % (os.path.getsize('$TEST_FILE')/1024/1024))
"

echo
echo "==> 测试 1: ping"
curl -s --max-time 5 "http://127.0.0.1:$PORT/macdrop/ping"; echo

echo
echo "==> 测试 2: 单文件分块传输（10MB / 6 块）"
/usr/bin/python3 - "$PORT" "$TEST_FILE" <<'PYEOF'
import sys, urllib.request, urllib.parse, uuid, os
port, path = sys.argv[1], sys.argv[2]
tid = str(uuid.uuid4())
base = f"http://127.0.0.1:{port}"
size = os.path.getsize(path)
name = os.path.basename(path)

def post(url, data=None):
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status, r.read()

q = urllib.parse.urlencode({"name": name, "path": name, "size": str(size), "root": ""})
s, b = post(f"{base}/macdrop/begin?id={tid}&{q}")
print(f"  begin  -> HTTP {s}")

data = open(path, "rb").read()
CH = 2 * 1024 * 1024
off, n = 0, 0
while off < len(data):
    chunk = data[off:off+CH]
    s, _ = post(f"{base}/macdrop/chunk?id={tid}&offset={off}", chunk)
    off += len(chunk); n += 1
    print(f"  chunk {n}  {off:>9}/{len(data)} bytes  -> HTTP {s}")

s, b = post(f"{base}/macdrop/finish?id={tid}")
print(f"  finish -> HTTP {s}  {b.decode(errors='replace')[:100]}")
PYEOF

echo
echo "==> 测试 3: 内容一致性校验"
SRC_HASH=$(shasum -a 256 "$TEST_FILE" | awk '{print $1}')
DST="$RECV_DIR/$(basename "$TEST_FILE")"
if [ -f "$DST" ]; then
    DST_HASH=$(shasum -a 256 "$DST" | awk '{print $1}')
    if [ "$SRC_HASH" = "$DST_HASH" ]; then
        echo "  ✓ SHA256 一致：${SRC_HASH:0:16}…"
    else
        echo "  ✗ 内容不一致！src=${SRC_HASH:0:16} dst=${DST_HASH:0:16}"
    fi
else
    echo "  ✗ 目标文件未落盘：$DST"
    ls -la "$RECV_DIR" || true
fi

echo
echo "==> 测试 4: 同名避让（再次发送同名文件）"
/usr/bin/python3 - "$PORT" "$TEST_FILE" <<'PYEOF'
import sys, urllib.request, urllib.parse, uuid, os
port, path = sys.argv[1], sys.argv[2]
tid = str(uuid.uuid4()); base = f"http://127.0.0.1:{port}"
name = os.path.basename(path); size = os.path.getsize(path)
def post(url, data=None):
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=60) as r: return r.status
q = urllib.parse.urlencode({"name": name, "path": name, "size": str(size), "root": ""})
post(f"{base}/macdrop/begin?id={tid}&{q}")
data = open(path,"rb").read(); CH = 2*1024*1024; off = 0
while off < len(data):
    c = data[off:off+CH]; post(f"{base}/macdrop/chunk?id={tid}&offset={off}", c); off += len(c)
post(f"{base}/macdrop/finish?id={tid}")
print("  第二次发送完成")
PYEOF
sleep 1
echo "  接收目录内容："
ls -1 "$RECV_DIR" | sed 's/^/    /'

echo
echo "==> 测试 5: 临时文件清理检查"
STAGE="$HOME/Library/Application Support/MoonDrop/.staging"
LEFT=$(ls -1 "$STAGE" 2>/dev/null | wc -l | tr -d ' ')
if [ "$LEFT" -eq 0 ]; then
    echo "  ✓ 无残留临时文件（$STAGE）"
else
    echo "  残留 $LEFT 个："; ls -1 "$STAGE" | sed 's/^/    /'
fi

echo
echo "==> 接收端日志"
grep "MoonDrop" "$TMP/e2e.log" | tail -8 | sed 's/^/  /'

echo
echo "==> 测试完成，接收目录保留在 $RECV_DIR 供检查（都在项目 .test-tmp/ 里，可整体删掉）"
