# MoonDrop for macOS

[English](README.md) | [简体中文](README.zh-CN.md)

macOS 菜单栏应用，把文件发给同一网络里的其他 Mac、iPhone 和 Android 设备。整体说明见[仓库 README](../README.zh-CN.md)。

## 安装

```bash
./build-app.sh
```

产出 `dist/MoonDrop.app` 与 `dist/MoonDrop.zip`。在目标 Mac 上解压后运行 `install.command`：退出正在运行的旧版、安装到 `/Applications/MoonDrop.app`、清除隔离属性并启动。

## 使用

| 操作 | 方式 |
|---|---|
| 发送 | 把文件拖到圆形悬浮窗，或用菜单 → **发送 Finder 选中项** / **选择文件发送** |
| 选择目标 | 在线设备多于一台时悬浮窗会列出设备，只有一台时直接发送 |
| 接收 | 文件落在 `~/Downloads/来自另一台Mac`，悬浮窗显示进度和收到的文件名 |
| 日志 | 菜单 → **传输日志**（`~/Library/Application Support/MoonDrop/logs/transfer.log`） |

首次启动会请求：**本地网络**（发现与传输）、**自动化**（读取 Finder 选中项）。

## 排障

| 现象 | 处理 |
|---|---|
| 找不到设备 | 确认同一网络、允许防火墙提示、到「系统设置 → 隐私与安全性 → 本地网络」允许 MoonDrop，或手动按 IP 添加 |
| 端口被占 | 启动时可选随机端口；设备仍通过 Bonjour 正常发现 |
| 收不到跨机拖放 | 跨机拖放由 macOS 通过 AWDL 广播，第三方 App 无法主动发起——改用「发送 Finder 选中项」 |
| 提示「MoonDrop 已损坏」 | `xattr -cr /Applications/MoonDrop.app` |

## 测试

```bash
./test-e2e.sh 52399
./test-discovery.sh
```

两个脚本用 `MACDROP_RECV_DIR`、`MACDROP_PORT`、`MACDROP_NAME` 隔离配置，只写项目内 `.test-tmp/`。
