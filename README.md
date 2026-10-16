# MacDrop — 两台 Mac 之间拖拽传文件

在局域网内把文件从一台 Mac 传到另一台 Mac。菜单栏常驻，不依赖云端，文件不经过任何第三方服务器。

项目位置：`~/Documents/moon_pro/MacDrop`

## 快速开始

```bash
cd ~/Documents/moon_pro/MacDrop
./build-app.sh          # 编译、签名并打包出 dist/MacDrop.app 和 dist/MacDrop.zip
```

安装到另一台 Mac：

1. 把 `dist/MacDrop.zip` 拷过去（AirDrop / 共享皆可），解压
2. 进入解压出的文件夹，双击 `install.command`

   脚本会自动：**退出正在运行的旧版** → 覆盖安装到 `/Applications` → 清除隔离属性 → 启动。
   旧版没在运行也能跑，重复执行也没问题，全程不用手动关掉旧版本。

   > 若双击被拦（提示来自身份不明的开发者），右键 → 打开；或在该目录执行 `bash install.command`。

两台 Mac 上都装一份，菜单栏会出现一个向下箭头图标。

> 注：`swift build` 在本机会报 `sandbox_apply: Operation not permitted`，
> 所以 `build-app.sh` 里带了 `--disable-sandbox`。若换机器报同样错，也是这个原因。

首次启动系统会弹两个权限框，都点「好」：

| 弹窗 | 用途 |
|---|---|
| 本地网络 | Bonjour 发现 + 直连传输 |
| 自动化（Finder） | 「发送 Finder 选中项」通道读取选中文件 |

## 三条通道

macOS 的「两台 Mac 之间拖放」是系统在 `sharingd` 层做的广播，第三方 App 无法自己发起这类事件。所以做了三条互相独立的通道，哪条能用哪条顶：

| # | 通道 | 依赖 | 怎么用 |
|---|---|---|---|
| A | **拖到悬浮窗** | 同机拖放一定可用；跨机取决于系统 AWDL | 把文件拖到悬浮窗 → 自动送到对端 |

悬浮窗平时是**圆形小图标**（64×64，不挡桌面）；文件拖到它上面时自动放大展开，
显示发送目标与进度，拖离或传完 3 秒后自动缩回圆形。接收文件时也会自动展开显示进度。
在线只有一台 Mac 时直接发送；**两台以上**时拖入后先弹出设备列表，点选目标再发送（点面板外取消）。
| B | **菜单栏发送选中项** | 无（Apple Events） | Finder 选中文件 → 点菜单栏图标 → 选对端 |
| C | **选择文件发送** | 无 | 菜单栏 → 「选择文件发送…」 |

通道 B 是最稳的：完全不走拖放，只读 Finder 选中项后走 HTTP 推送。如果原生跨机拖放在你这台机器上不生效，**用 B 一样能达成目的**。

## 能力边界（重要）

- **不能**拖到另一台 Mac 的 Finder 窗口或桌面 —— 那是系统功能，只有「同一 Apple ID」才有
- 通道 A 的跨机拖放能否触发，取决于系统 AWDL 是否广播。原生拖放失效时，悬浮窗同样收不到，此时请用通道 B/C
- 需要两台在同一局域网；不要求同一 Apple ID

## 工作方式

```
Mac A                                    Mac B
┌──────────────┐                        ┌──────────────┐
│ Finder 拖出  │                        │  监听端口    │
│      ↓       │   HTTP 分块传输        │      ↓       │
│ 拦截拖放事件 │  ───────────────────►  │  临时文件    │
│              │   （Bonjour 自动发现） │      ↓       │
│              │                        │ 原子 rename  │
│              │                        │   → 落盘    │
└──────────────┘                        └──────────────┘
```

- **发现**：Bonjour `_macdrop._tcp`，自动列出对端，不用手输 IP（防火墙拦截时菜单里有「手动添加对端」）
- **传输**：2 MB 分块，可传大文件
- **落盘**：先写 `~/Library/Caches/MacDropStaging/` 临时文件，完成后 `moveItem` 原子移动到接收目录。传一半断掉不会留下坏文件
- **同名避让**：`foo.txt` → `foo (1).txt`
- **目录拖放**：递归展开，保持子目录结构，在接收端建同名文件夹

默认接收目录：`~/Downloads/来自另一台Mac`

## 菜单

- 对端列表（点一个 = 把 Finder 选中项发给它）
- 发送 Finder 选中项 / 选择文件发送
- 显示/隐藏悬浮窗
- 打开接收文件夹
- 传输日志（`~/Library/Application Support/MacDrop/logs/transfer.log`）

## 测试

```bash
./test-e2e.sh 52399        # 单实例：分块传输 + SHA256 校验 + 同名避让 + 临时文件清理
./test-discovery.sh        # 双实例：互相发现 + 不自发现 + 跨实例传输
```

两个脚本都用环境变量隔离配置（`MACDROP_RECV_DIR` / `MACDROP_PORT` / `MACDROP_NAME`），
不会污染真实设置，也不会往你的 Downloads 里写东西。
所有测试临时文件都生成在项目内 `.test-tmp/`（不再写 `/tmp`），可随时整体删除。

## 排障

| 现象 | 原因 / 处理 |
|---|---|
| 菜单栏说「未发现其他 Mac」 | 确认两台在同一 Wi-Fi；首次运行防火墙弹窗要选「允许」；或用「手动添加对端」填对方 IP |
| 手动添加连不上 | `lsof -nP -iTCP:52345 -sTCP:LISTEN` 看端口是否被占；换端口 |
| 提示端口被占 | 启动时会弹窗，可自动换随机端口重试 |
| 悬浮窗收不到跨机拖放 | 符合预期设计，见上面「能力边界」，改用通道 B |

## 环境变量（用于多实例 / 调试）

| 变量 | 作用 |
|---|---|
| `MACDROP_RECV_DIR` | 覆盖接收目录 |
| `MACDROP_PORT` | 覆盖监听端口 |
| `MACDROP_NAME` | 覆盖设备名（Bonjour 广告名） |
## 开发备注

- Swift 6 / Xcode 26.3 下 `NetService` API 有改名（`setTXTRecord`、`publish()`、无 `fullName`、`addresses` 为可选），照抄旧写法会编译不过
- `sockaddr` 长度校验：IPv4 只有 16 字节，不能拿 `sockaddr_storage.size`（128）做下限
- Bonjour 会 browse 到自己的广告，`didFind` 里必须按名字过滤

## 分发到另一台 Mac（踩坑记录）

首次分发时报「MacDrop 已损坏，无法打开」，原因是 **SPM 产物的 app 包只有 linker-signed，
整个 bundle 没做签名**，`codesign --verify` 直接失败：

```
code has no resources but signature indicates they must be present
Info.plist=not bound
```

`build-app.sh` 已修掉：ad-hoc 签整个 bundle + 二进制单独再签 + `xattr -cr` 清隔离属性。
现在 `Sealed Resources version=2 rules=13`，`codesign --verify --deep --strict` 通过。

**用 zip 分发，别直接拷 .app**：`build-app.sh` 已自动生成 `dist/MacDrop.zip`
（内含 `MacDrop.app` + `install.command`，已在打包时排除 `._*` AppleDouble 文件——
这是跨机器解压后包损坏的常见原因，已实测排除后解压签名依然有效）。

**升级不用手动关旧版**：`install.command` 会先退出正在运行的旧进程再覆盖安装；
即使漏了（比如直接 `open -n`），新版本启动时也会通过本机 HTTP 通道请旧实例退出，
超时则强制结束，不会出现两个菜单栏图标抢端口的情况。

**若那台机器仍报损坏**，手动清一次隔离属性：

```bash
xattr -cr /Applications/MacDrop.app
```

**注意**：`swift build` 默认只产出 arm64。若对面是 Intel Mac，跑不起来，
需 `swift build -c release --arch arm64 --arch x86_64` 重新编译。

## 同名设备 bug（已修）

两台机器都叫 `MacBook Pro` 时互相看不见。原因：Bonjour 发现同名服务时，
会把**后注册的那台改名**成 `MacBook Pro (2)`，但注册方自己不知道这件事。
旧实现用「对端显示名 == 我的名字」来判断"是不是自己"，
于是两台都把对方当成自己滤掉了。

修复：改用「主机名 + 端口」这一组更唯一的特征判断自己，
名字只用于显示。`test-discovery.sh` 验证 5 专门钉死这个场景。

`Peer.id` 也从 `host:port` 改成 `name@host:port`——
IP 被 DHCP 换掉后，同一台机器仍是同一个条目，不会变成重复项。

## 目录分布

| 内容 | 位置 |
|---|---|
| 源码 | `~/Documents/moon_pro/MacDrop/` |
| 可分发的 app | `~/Documents/moon_pro/MacDrop/dist/MacDrop.zip` |
| 传输暂存 | `~/Library/Application Support/MacDrop/.staging/` |
| 传输日志 | `~/Library/Application Support/MacDrop/logs/transfer.log` |
| 收到的文件 | `~/Downloads/来自另一台Mac/` |

**为什么运行时数据不放项目目录**：拷 `.app` 给另一台 Mac 时不会把暂存和日志一起带过去。
**为什么不放 `~/Library/Caches/`**：系统会定期清理 Caches，传输日志会被莫名删掉。
Application Support 才是 Apple 规范里"应用数据该待的地方"。

菜单栏「打开数据目录」可直接跳转到该位置。

**启动时自动清理**：上次异常退出留下的半截暂存文件（传输中途断掉的），
在下次启动时会被清掉并记入日志，不会越积越多。
