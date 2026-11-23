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
MACDROP_RECV_DIR="$RECV_DIR" MACDROP_PORT="$PORT" MACDROP_NAME="TestReceiver" MACDROP_AUTO_ACCEPT=1 \
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
import sys, urllib.request, urllib.parse, uuid, os, time
port, path = sys.argv[1], sys.argv[2]
tid = str(uuid.uuid4())
base = f"http://127.0.0.1:{port}"
size = os.path.getsize(path)
name = os.path.basename(path)

def post(url, data=None):
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status, r.read()

q = urllib.parse.urlencode({"name": name, "path": name, "size": str(size), "root": "", "batch": str(uuid.uuid4()), "from": "ProtocolTest", "files": "1", "bytes": str(size)})
while True:
    s, b = post(f"{base}/macdrop/begin?id={tid}&{q}")
    print(f"  begin  -> HTTP {s}")
    if s == 200:
        break
    assert s == 202, f"unexpected begin status {s}"
    time.sleep(0.1)

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
import sys, urllib.request, urllib.parse, uuid, os, time
port, path = sys.argv[1], sys.argv[2]
tid = str(uuid.uuid4()); base = f"http://127.0.0.1:{port}"
name = os.path.basename(path); size = os.path.getsize(path)
def post(url, data=None):
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=60) as r: return r.status
q = urllib.parse.urlencode({"name": name, "path": name, "size": str(size), "root": "", "batch": str(uuid.uuid4()), "from": "ProtocolTest", "files": "1", "bytes": str(size)})
while True:
    status = post(f"{base}/macdrop/begin?id={tid}&{q}")
    if status == 200:
        break
    assert status == 202, f"unexpected begin status {status}"
    time.sleep(0.1)
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
echo "==> 测试 5: 分块边界校验（越界 / 未对齐 / 大小不符）"
/usr/bin/python3 - "$PORT" <<'PYEOF'
import sys, urllib.request, urllib.parse, urllib.error, uuid, time

port = sys.argv[1]
base = f"http://127.0.0.1:{port}"
tid = str(uuid.uuid4())
total = 10 * 1024 * 1024

def post(url, data=b""):
    req = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code

q = urllib.parse.urlencode({"name": "bounds.bin", "path": "bounds.bin", "size": str(total),
                            "root": "", "batch": str(uuid.uuid4()), "from": "ProtocolTest",
                            "files": "1", "bytes": str(total)})
url = f"{base}/macdrop/begin?id={tid}&{q}"
while True:
    s = post(url)
    if s == 200:
        break
    if s != 202:
        print(f"  ✗ begin 异常状态 {s}"); sys.exit(1)
    time.sleep(0.1)

fails = 0
def expect(desc, got, want):
    global fails
    if got == want:
        print(f"  ✓ {desc} → HTTP {got}")
    else:
        print(f"  ✗ {desc} → HTTP {got}（期望 {want}）"); fails += 1

chunk = 2 * 1024 * 1024
expect("offset == total（越界）", post(f"{base}/macdrop/chunk?id={tid}&offset={total}", b"x"), 400)
expect("offset 未按 2MiB 对齐", post(f"{base}/macdrop/chunk?id={tid}&offset=3", b"x" * chunk), 400)
expect("分块长度与声明不符", post(f"{base}/macdrop/chunk?id={tid}&offset=0", b"x"), 400)
expect("未知传输 ID", post(f"{base}/macdrop/chunk?id=no-such-id&offset=0", b"x" * chunk), 404)
post(f"{base}/macdrop/abort?id={tid}")
sys.exit(1 if fails else 0)
PYEOF

echo
echo "==> 测试 6: 重复分块幂等（同 offset 重发，内容不变）"
SMALL="$TMP/small-$$.bin"
/usr/bin/python3 -c "
with open('$SMALL','wb') as f: f.write(bytes(range(256)) * 1200)
"
/usr/bin/python3 - "$PORT" "$SMALL" <<'PYEOF'
import sys, urllib.request, urllib.parse, urllib.error, uuid, os, time, hashlib

port, path = sys.argv[1], sys.argv[2]
base = f"http://127.0.0.1:{port}"
tid = str(uuid.uuid4())
data = open(path, "rb").read()
name = os.path.basename(path)

def post(url, body=b""):
    req = urllib.request.Request(url, data=body, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

q = urllib.parse.urlencode({"name": name, "path": name, "size": str(len(data)),
                            "root": "", "batch": str(uuid.uuid4()), "from": "ProtocolTest",
                            "files": "1", "bytes": str(len(data))})
while True:
    s, _ = post(f"{base}/macdrop/begin?id={tid}&{q}")
    if s == 200:
        break
    if s != 202:
        print(f"  ✗ begin 异常状态 {s}"); sys.exit(1)
    time.sleep(0.1)

s1, _ = post(f"{base}/macdrop/chunk?id={tid}&offset=0", data)
s2, _ = post(f"{base}/macdrop/chunk?id={tid}&offset=0", data)
print(f"  首次分块 HTTP {s1} / 重发同一分块 HTTP {s2}")
s3, b = post(f"{base}/macdrop/finish?id={tid}")
print(f"  finish HTTP {s3}")
if not (s1 == s2 == s3 == 200):
    print("  ✗ 重发分块未保持幂等"); sys.exit(1)
print(f"  源文件 SHA256 {hashlib.sha256(data).hexdigest()[:16]}…")
PYEOF
SMALL_SRC=$(shasum -a 256 "$SMALL" | awk '{print $1}')
SMALL_DST="$RECV_DIR/$(basename "$SMALL")"
if [ -f "$SMALL_DST" ] && [ "$SMALL_SRC" = "$(shasum -a 256 "$SMALL_DST" | awk '{print $1}')" ]; then
    echo "  ✓ 重发后内容仍一致"
else
    echo "  ✗ 重发后内容不一致或未落盘：$SMALL_DST"
fi

echo
echo "==> 测试 7: 重复 begin（同 id）与同批次多文件只确认一次"
/usr/bin/python3 - "$PORT" "$SMALL" <<'PYEOF'
import sys, urllib.request, urllib.parse, urllib.error, uuid, os, time

port, path = sys.argv[1], sys.argv[2]
base = f"http://127.0.0.1:{port}"
data = open(path, "rb").read()
size = len(data)
batch = str(uuid.uuid4())
fails = 0

def post(url, body=b""):
    req = urllib.request.Request(url, data=body, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code

def begin(tid, name, batched=True):
    q = urllib.parse.urlencode({"name": name, "path": name, "size": str(size),
                                "root": "", "batch": batch if batched else str(uuid.uuid4()),
                                "from": "ProtocolTest", "files": "2", "bytes": str(size * 2)})
    url = f"{base}/macdrop/begin?id={tid}&{q}"
    while True:
        s = post(url)
        if s in (200, 202):
            return s
        return s

tid_a = str(uuid.uuid4())
first = begin(tid_a, "batch-a.bin")
if first == 202:
    while True:
        s = post(f"{base}/macdrop/begin?id={tid_a}&" + urllib.parse.urlencode(
            {"name": "batch-a.bin", "path": "batch-a.bin", "size": str(size), "root": "",
             "batch": batch, "from": "ProtocolTest", "files": "2", "bytes": str(size * 2)}))
        if s == 200:
            break
        if s != 202:
            print(f"  ✗ 确认后 begin 异常状态 {s}"); fails += 1; break
        time.sleep(0.1)
print("  ✓ 同批次首个文件确认后进入 200")

dup = post(f"{base}/macdrop/begin?id={tid_a}&" + urllib.parse.urlencode(
    {"name": "batch-a.bin", "path": "batch-a.bin", "size": str(size), "root": "",
     "batch": batch, "from": "ProtocolTest", "files": "2", "bytes": str(size * 2)}))
if dup == 200:
    print("  ✓ 重复 begin 同一 id → HTTP 200（复用会话）")
else:
    print(f"  ✗ 重复 begin 返回 {dup}"); fails += 1

tid_b = str(uuid.uuid4())
second = begin(tid_b, "batch-b.bin")
if second == 200:
    print("  ✓ 同批次第二个文件直接 200，不再重复确认")
else:
    print(f"  ✗ 同批次第二个文件返回 {second}（应为 200，说明重复确认了）"); fails += 1

for tid, name in ((tid_a, "batch-a.bin"), (tid_b, "batch-b.bin")):
    post(f"{base}/macdrop/chunk?id={tid}&offset=0", data)
    post(f"{base}/macdrop/finish?id={tid}")
sys.exit(1 if fails else 0)
PYEOF

echo
echo "==> 测试 8: abort 清理在途暂存"
BEFORE_COUNT=$(ls -1 "$HOME/Library/Application Support/MoonDrop/.staging" 2>/dev/null | wc -l | tr -d ' ')
/usr/bin/python3 - "$PORT" <<'PYEOF'
import sys, urllib.request, urllib.parse, urllib.error, uuid, time

port = sys.argv[1]
base = f"http://127.0.0.1:{port}"
tid = str(uuid.uuid4())
total = 10 * 1024 * 1024

def post(url, body=b""):
    req = urllib.request.Request(url, data=body, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code

q = urllib.parse.urlencode({"name": "aborted.bin", "path": "aborted.bin", "size": str(total),
                            "root": "", "batch": str(uuid.uuid4()), "from": "ProtocolTest",
                            "files": "1", "bytes": str(total)})
while True:
    s = post(f"{base}/macdrop/begin?id={tid}&{q}")
    if s == 200:
        break
    if s != 202:
        print(f"  ✗ begin 异常状态 {s}"); sys.exit(1)
    time.sleep(0.1)
print(f"  chunk 1/5 → HTTP {post(f'{base}/macdrop/chunk?id={tid}&offset=0', b'x' * (2*1024*1024))}")
print(f"  abort → HTTP {post(f'{base}/macdrop/abort?id={tid}')}")
print(f"  abort 后继续写分块（应拒绝）→ HTTP {post(f'{base}/macdrop/chunk?id={tid}&offset=0', b'x' * (2*1024*1024))}")
PYEOF
sleep 1
AFTER_COUNT=$(ls -1 "$HOME/Library/Application Support/MoonDrop/.staging" 2>/dev/null | wc -l | tr -d ' ')
if [ "$BEFORE_COUNT" = "$AFTER_COUNT" ]; then
    echo "  ✓ 暂存目录无新增残留（$BEFORE_COUNT → $AFTER_COUNT）"
else
    echo "  ✗ 暂存目录残留（$BEFORE_COUNT → $AFTER_COUNT）："
    ls -1 "$HOME/Library/Application Support/MoonDrop/.staging" | sed 's/^/    /'
fi
if [ -f "$RECV_DIR/aborted.bin" ]; then
    echo "  ✗ 被中止的文件仍落盘了：$RECV_DIR/aborted.bin"
else
    echo "  ✓ 被中止的文件未落盘"
fi

echo
echo "==> 测试 9: 拒绝接收（AUTO_REJECT）"
REJECT_PORT=$((PORT + 1))
REJECT_DIR="$TMP/reject-$$"
mkdir -p "$REJECT_DIR"
MACDROP_RECV_DIR="$REJECT_DIR" MACDROP_PORT="$REJECT_PORT" MACDROP_NAME="RejectReceiver" \
    MACDROP_ID="test-reject-$$" MACDROP_AUTO_REJECT=1 \
    "$BIN" > "$TMP/reject.log" 2>&1 &
REJECT_PID=$!
sleep 2
if kill -0 $REJECT_PID 2>/dev/null; then
    REJECT_RESULT=0
    /usr/bin/python3 - "$REJECT_PORT" <<'PYEOF' || REJECT_RESULT=1
import sys, urllib.request, urllib.parse, urllib.error, uuid, time, os

port = sys.argv[1]
base = f"http://127.0.0.1:{port}"
tid = str(uuid.uuid4())
total = 1024

def post(url, body=b""):
    req = urllib.request.Request(url, data=body, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code

q = urllib.parse.urlencode({"name": "rejected.bin", "path": "rejected.bin", "size": str(total),
                            "root": "", "batch": str(uuid.uuid4()), "from": "ProtocolTest",
                            "files": "1", "bytes": str(total)})
url = f"{base}/macdrop/begin?id={tid}&{q}"
statuses = []
deadline = time.time() + 6
while time.time() < deadline:
    s = post(url)
    statuses.append(s)
    if s in (403, 200):
        break
    time.sleep(0.2)
print(f"  begin 状态序列：{statuses}")
if statuses and statuses[0] == 202 and statuses[-1] == 403:
    print("  ✓ 202（待确认）→ 403（已拒绝）")
    sys.exit(0)
print("  ✗ 拒绝流程不符合预期"); sys.exit(1)
PYEOF
    sleep 1
    if [ -z "$(ls -A "$REJECT_DIR")" ]; then
        echo "  ✓ 拒绝后接收目录为空"
    else
        echo "  ✗ 拒绝后仍有文件："; ls -1 "$REJECT_DIR" | sed 's/^/    /'
    fi
else
    echo "  ✗ 拒绝实例启动失败："; cat "$TMP/reject.log"; REJECT_RESULT=1
fi
{ kill $REJECT_PID; wait $REJECT_PID; } 2>/dev/null || true
if [ "$REJECT_RESULT" -ne 0 ]; then
    echo "  ✗ 拒绝路径测试失败"
fi

echo
echo "==> 测试 10: 临时文件清理检查"
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
