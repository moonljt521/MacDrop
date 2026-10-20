# MacDrop

[English](README.md) | **简体中文**

在同一局域网内的两台 Mac 之间直接传文件，不经过云端，也没有第三方服务器。MacDrop 常驻菜单栏，提供一个安静的小圆形悬浮窗作为投放目标，文件通过 HTTP 在两台机器之间直接传输。

版本 1.4 · macOS 13+ · 默认构建 Apple silicon（通用二进制见下文）

## 功能

- **局域网直传** — 文件只在两台 Mac 之间流动。
- **悬浮投放窗** — 平时是 64×64 的圆形小窗，拖入文件时展开，结束后自动收回。
- **多设备选择器** — 在线设备多于一台时，先点选目标再发送。
- **接收进度** — 接收端实时显示百分比。
- **目录传输** — 递归展开文件夹，并在接收端还原目录结构。
- **不落半截文件** — 先写暂存区，核对字节数后再原子移动到接收目录。
- **同名避让** — `报告.pdf` 会变成 `报告 (1).pdf`，不会覆盖已有文件。
- **三条独立发送通道** — 悬浮窗、Finder 选中项、文件选择器。
- **升级自动接管** — 新实例启动时会先请旧实例退出。

## 系统要求

- 两台 Mac 均为 macOS 13 Ventura 或更新版本。
- 两台 Mac 在同一局域网（Wi-Fi 或有线）。
- 首次启动需要授予两项权限：

| 权限 | 用途 |
|---|---|
| 本地网络 | Bonjour 发现与直连传输 |
| 自动化（Finder） | 菜单栏「发送 Finder 选中项」读取选中文件 |

从源码构建需要 Swift 5.9+ 工具链（已在 Swift 6 / Xcode 26.3 下验证）。

## 安装

### 使用发布包

1. 把 `dist/MacDrop.zip` 拷贝到另一台 Mac 并解压。
2. 进入解压后的文件夹，双击 `install.command`。

脚本会自动退出正在运行的旧版、安装到 `/Applications/MacDrop.app`、清除隔离属性、校验 ad-hoc 签名并启动应用。

> 若双击被系统拦截，右键 →「打开」，或在该目录执行 `bash install.command`。

### 从源码构建

```bash
git clone git@github.com:moonljt521/MacDrop.git
cd MacDrop
./build-app.sh
```

产物：

- `dist/MacDrop.app`
- `dist/MacDrop.zip` —— 可分发的压缩包（含 App 与 `install.command`）

`build-app.sh` 使用 `swift build --disable-sandbox`，因为某些环境下直接执行 `swift build` 会报 `sandbox_apply: Operation not permitted`。

默认只构建当前架构。若目标机器是 Intel Mac，需要重新编译通用二进制：

```bash
swift build -c release --disable-sandbox --arch arm64 --arch x86_64
```

多架构产物位于 `.build/apple/Products/Release/MacDrop`，需要手动替换进 `.app`（或自行调整 `build-app.sh`）。

## 使用

### 发送

| 通道 | 方式 |
|---|---|
| A · 悬浮窗 | 从 Finder 把文件拖到圆形小窗。只有一台在线设备时直接发送；两台及以上先弹出设备列表，点选目标。 |
| B · Finder 选中项 | 在 Finder 中选中文件 → 菜单栏图标 → 点目标设备。走 Apple Events，不依赖拖放。 |
| C · 选择文件 | 菜单栏图标 →「选择文件发送…」。 |

系统不投递跨 Mac 拖放时，通道 B 最稳。

### 菜单说明

| 菜单项 | 作用 |
|---|---|
| 对端列表 | 把 Finder 当前选中项发给该设备 |
| 发送 Finder 选中项… | 发给第一台在线设备 |
| 选择文件发送… | 选择文件或文件夹发送 |
| 手动添加对端… | Bonjour 被拦截时按 IP 添加；无在线设备时显示 |
| 显示/隐藏悬浮窗 | 切换悬浮窗 |
| 打开接收文件夹 | 在 Finder 中打开接收目录 |
| 打开数据目录 | 打开暂存与日志所在目录 |
| 传输日志 | 打开 `transfer.log` |
| 退出 MacDrop | 退出应用 |

### 接收

默认接收到 `~/Downloads/来自另一台Mac`，目录结构保持不变。传输结束后悬浮窗显示「已接收：文件名」；若开启了自动显示（默认开启），Finder 会选中该文件。

## 工作原理

```
Mac A                                    Mac B
┌──────────────┐                        ┌──────────────┐
│ Finder 拖出  │                        │  HTTP 服务   │
│      ↓       │    HTTP 分块上传       │      ↓       │
│  悬浮窗      │  ───────────────────►  │   暂存文件   │
│              │    （Bonjour 发现）    │      ↓       │
│              │                        │  字节数校验  │
│              │                        │  原子移动    │
└──────────────┘                        └──────────────┘
```

- **发现** — Bonjour 服务类型 `_macdrop._tcp`，必要时可手动填 IP。
- **传输** — HTTP/1.1，2 MiB 顺序分块，上一块确认后才发下一块；每块带显式 offset，接收端据此定位写入。
- **暂存** — 分块先追加到 `~/Library/Application Support/MacDrop/.staging/` 下的临时文件。
- **校验** — 收到 `finish` 时比对暂存文件大小与发送端声明的字节数，不一致就拒收并删除临时文件。
- **原子交付** — 校验通过后一次性移动到接收目录；中断的传输不会在目标目录留下坏文件。
- **清理** — 异常退出遗留的暂存文件会在下次启动时清掉。

### HTTP 接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/macdrop/ping` | 健康检查，返回设备名与版本 |
| POST | `/macdrop/begin?id=…&name=…&path=…&size=…&root=…` | 声明传输并创建暂存文件 |
| POST | `/macdrop/chunk?id=…&offset=…` | 追加分块（请求体为原始字节） |
| POST | `/macdrop/finish?id=…` | 校验并移动到最终位置 |
| POST | `/macdrop/abort?id=…` | 丢弃未完成的传输 |
| POST | `/macdrop/quit` | 请本机实例退出（仅限 loopback） |

## 数据位置

| 内容 | 位置 |
|---|---|
| 源码 | 克隆目录 |
| 可分发的 App | `dist/MacDrop.zip` |
| 传输暂存 | `~/Library/Application Support/MacDrop/.staging/` |
| 传输日志 | `~/Library/Application Support/MacDrop/logs/transfer.log` |
| 收到的文件 | `~/Downloads/来自另一台Mac`（默认） |
| 配置 | `UserDefaults`，键 `com.macdrop.settings.v1` |

运行时数据刻意放在 Application Support，而不是项目目录或 `~/Library/Caches`：把 App 拷到别的 Mac 时不会带上暂存和日志，系统也不会定期清理它们。

## 测试

先构建 release 二进制（`./build-app.sh` 或 `swift build -c release --disable-sandbox`），然后：

```bash
./test-e2e.sh 52399       # 单实例：分块传输、SHA256 校验、同名避让、暂存清理
./test-discovery.sh       # 双实例：互相发现、不自发现、跨实例传输、同名设备
```

两个脚本都用 `MACDROP_RECV_DIR`、`MACDROP_PORT`、`MACDROP_NAME` 隔离配置，临时文件只写在项目内的 `.test-tmp/`。

### 环境变量

| 变量 | 作用 |
|---|---|
| `MACDROP_RECV_DIR` | 覆盖接收目录 |
| `MACDROP_PORT` | 覆盖监听端口（默认 `52345`） |
| `MACDROP_NAME` | 覆盖广播的设备名 |
| `MACDROP_UI_PROBE` | 仅开发用：把 UI 快照渲染到指定目录 |

## 排障

| 现象 | 原因 / 处理 |
|---|---|
| 找不到其他 Mac | 确认两台在同一网络并允许防火墙提示；到「系统设置 → 隐私与安全性 → 本地网络」中允许 MacDrop；Bonjour 被拦截时用「手动添加对端…」。 |
| 手动添加连不上 | 确认对端在运行、端口在监听：`lsof -nP -iTCP:52345 -sTCP:LISTEN`；端口被占则换端口。 |
| 端口被占用 | 启动时 MacDrop 会提示并自动切换到随机端口。 |
| 悬浮窗收不到跨机拖放 | 部分环境下属于预期：macOS 通过 AWDL 广播跨机器拖放，第三方 App 无法自行发起。改用通道 B 或 C。 |
| 提示「MacDrop 已损坏」 | 执行 `xattr -cr /Applications/MacDrop.app`；分发时用 zip，不要直接拷贝 `.app` 目录。 |
| Intel Mac 打不开 | 默认产物只有 arm64，按上文重新构建通用二进制。 |

## 安全模型

MacDrop 面向可信局域网：

- 传输使用明文 HTTP，**不加密**。
- HTTP 服务**不校验发送方身份**，任何能访问该端口的局域网主机都可以发起传输。
- 收到的文件会自动接收；「自动显示」只决定完成后是否在 Finder 中打开。
- 对端提供的文件名会被清洗，已有文件不会被覆盖。
- `/macdrop/quit` 仅接受本机 loopback 连接。

不要把端口暴露到公网，也不要在不可信网络中运行 MacDrop。

## 能力边界

- macOS 不允许第三方 App 主动发起跨机器拖放。悬浮窗能接住本机拖放，以及系统恰好投递的跨机拖放；通道 B、C 始终可用。
- 传输不支持断点续传。中断的传输会被丢弃，暂存文件在下次启动时清理。
- 中断或被拒收的传输不会进入接收目录，因此半截文件不会被误认为完整文件。

## 目录结构

```
Sources/MacDrop/
├── main.swift
├── AppDelegate.swift          # 生命周期、HTTP 路由、发送编排
├── Core/
│   ├── BonjourService.swift   # 发现与手动对端
│   ├── Config.swift           # 配置、暂存与日志路径
│   ├── HTTPService.swift      # 极简 HTTP/1.1 服务端
│   └── TransferEngine.swift   # 分块收发、暂存、原子移动
└── UI/
    ├── DropPanel.swift        # 悬浮窗、设备选择器、进度 UI
    └── StatusItemController.swift  # 菜单栏、Finder 桥接、日志
```

## 开发备注

- Swift 6 下 `NetService` API 有改名（`setTXTRecord`、`publish()`、无 `fullName`、`addresses` 为可选），旧写法无法编译。
- `sockaddr` 长度要按协议校验：IPv4 只有 16 字节，不能拿 `sockaddr_storage.size`（128）当下限。
- Bonjour 会浏览到自己的广告。判断「是不是自己」要用主机名加端口，不能只看显示名——两台 Mac 可能同名。
- App 包整体做 ad-hoc 签名，二进制再单独签名；分发后用 `xattr -cr` 清除隔离属性。请分发 zip，不要直接拷 `.app` 目录，避免 AppleDouble（`._*`）文件破坏签名。
- 新实例启动时通过本机 HTTP 请旧实例退出，超时后强制结束，避免两个菜单栏图标抢端口。
