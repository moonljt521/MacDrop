# MoonDrop

[English](README.md) | **简体中文**

在同一局域网内的 **Mac、iPhone、Android** 之间原生直传文件。不经过云端，没有账号，也没有第三方服务器——文件在设备之间直接流动。

| 平台 | 技术栈 | 目录 | 最低系统 | 版本 |
|---|---|---|---|---|
| macOS | Swift · AppKit | [`macos/`](macos) | macOS 13 | 1.5 |
| iOS | Swift · SwiftUI · Network.framework | [`ios/`](ios) | iOS 16 | 1.5.0 |
| Android | Kotlin · 平台原生 API | [`android/`](android) | Android 10（API 29） | 1.5.0 |

> 产品名是 MoonDrop；代码仓库与局域网协议沿用原来的 `macdrop` 标识（`_macdrop._tcp`、`com.macdrop.*`），以保证已安装的旧版本仍能互通。

## 功能

- Bonjour 自动发现，也可手动按 IP 添加设备
- 发送文件与文件夹，目录结构在接收端逐级还原
- 任意平台互收，发送与接收两端都有进度
- 支持从其他 App 打开或分享（iOS：用 MoonDrop 打开 / 分享；Android：系统分享面板）
- 点击已接收文件可用系统查看器预览；iOS 上文件夹可在 App 内浏览
- 交付前校验字节数，坏文件不会被当成完整文件

## 工作原理

```
发送端                                  接收端
┌────────────┐  POST /macdrop/begin   ┌────────────┐
│ 2 MiB      │ ────────────────────► │ 暂存       │
│ 分块 +     │  POST /macdrop/chunk   │ 字节数校验 │
│ 偏移量     │ ────────────────────► │ 交付       │
└────────────┘  POST /macdrop/finish  └────────────┘
```

- **发现** — Bonjour `_macdrop._tcp`；只有设备真正离线时才会从列表移除。
- **传输** — HTTP/1.1，2 MiB 顺序分块，每块确认后才发下一块。
- **完整性** — 接收端比对已写字节数与声明大小，不一致直接拒收。
- **交付** — macOS / iOS 校验通过后移动到目标位置；Android 发布待生效的 `MediaStore` 条目。

### 接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/macdrop/ping` | 健康检查：设备名与端口 |
| POST | `/macdrop/begin?id=&name=&path=&size=&root=` | 声明传输并创建暂存文件 |
| POST | `/macdrop/chunk?id=&offset=` | 追加分块（请求体为原始字节） |
| POST | `/macdrop/finish?id=` | 校验并交付 |
| POST | `/macdrop/abort?id=` | 丢弃未完成的传输 |

默认端口 `52345`；被占用时自动改用随机端口，并通过 Bonjour 广播真实端口。

## 构建与运行

### macOS

```bash
cd macos && ./build-app.sh      # 产出 dist/MoonDrop.app 与 dist/MoonDrop.zip
```

在目标 Mac 上解压后运行 `install.command`：退出正在运行的旧版、安装到 `/Applications/MoonDrop.app`、清除隔离属性并启动。

### iOS

需要 Xcode 16+ 与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
cd ios
xcodegen generate
open MoonDropMobile.xcodeproj      # 选择开发团队后运行到真机
```

首次启动会请求「本地网络」权限。收到的文件位于 **文件 → 我的 iPhone → MoonDrop → Received**。

### Android

需要 JDK 17+ 与 API 36 SDK。

```bash
cd android && ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

收到的文件发布到 **下载/来自另一台Mac**。接收端以前台服务运行，切到后台仍可继续接收。

## 使用

1. 两台设备都打开 MoonDrop，连接同一网络。
2. 发送：选择文件（或在 macOS 上拖到悬浮窗）；iOS 与 Android 会询问目标设备。
3. 接收端提示已收到的文件——点击可预览，用「分享」可继续转发。

从其他 App 发送时：Android 用 **分享 → MoonDrop**，iOS 用 **用 MoonDrop 打开 / 分享 → MoonDrop**。文件先进入待发送区，选好目标后才会真正发送。

## 数据位置

| 内容 | 路径 |
|---|---|
| 配置 | `UserDefaults`（`com.macdrop.settings.v1`） |
| 暂存 | `~/Library/Application Support/MoonDrop/.staging`（macOS）、应用沙盒（移动端） |
| 传输日志 | `~/Library/Application Support/MoonDrop/logs/transfer.log` |
| 收到的文件 | `~/Downloads/来自另一台Mac`（macOS）、`Download/来自另一台Mac`（Android）、`文件 → 我的 iPhone → MoonDrop → Received`（iOS） |

## 测试

```bash
cd macos
./test-e2e.sh 52399      # 分块传输、SHA256、同名避让、暂存清理
./test-discovery.sh      # 双实例：互相发现、不自发现、同名设备
```

## 安全

- 明文 HTTP：流量**不加密**，接收端**不校验**发送方身份。
- 任何能访问该端口的主机都能推送文件——只在可信网络使用。
- 对端提供的文件名会被清洗，已有文件不会被覆盖。
- `/macdrop/quit` 仅接受 loopback 调用，且只有 macOS 端存在。

## 已知边界

- 传输不可续传，中断即丢弃，需要重发。
- iOS 切到后台会暂停发现与监听；Android 靠前台服务维持。
- 只校验字节数，不校验内容哈希。
- Android 的已接收列表是平铺的，看不出目录层级。

## 目录结构

```
macos/    Swift Package + AppKit 菜单栏应用
ios/      SwiftUI 应用（XcodeGen），含分享扩展
android/  Kotlin 应用（Gradle）
assets/   图标源文件
tools/    图标生成脚本
```

## 开发备注

- Swift 6 改了多个 `NetService` API，老写法无法编译。
- 校验 `sockaddr` 长度：IPv4 是 16 字节，不能用 `sockaddr_storage.size`。
- Bonjour 也会发现本机自己的广播，按 TXT id 或本机地址过滤掉。
- App 包整体 ad-hoc 签名、二进制单独再签；分发后执行 `xattr -cr`。
- 分发 zip 而非 `.app` 目录，避免 AppleDouble 文件破坏签名。
