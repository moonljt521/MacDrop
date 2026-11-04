# MoonDrop

**English** | [简体中文](README.zh-CN.md)

Native file transfer between **Mac, iPhone and Android** over the local network. No cloud, no accounts, no third-party servers — bytes move directly between devices.

| Platform | Stack | Directory | Minimum OS | Version |
|---|---|---|---|---|
| macOS | Swift · AppKit | [`macos/`](macos) | macOS 13 | 1.6 |
| iOS | Swift · SwiftUI · Network.framework | [`ios/`](ios) | iOS 16 | 1.6.0 |
| Android | Kotlin · platform APIs | [`android/`](android) | Android 10 (API 29) | 1.6.0 |

> The product is MoonDrop; the repository and the LAN protocol keep their original `macdrop` identifiers (`_macdrop._tcp`, `com.macdrop.*`) so existing installs stay compatible.

## Features

- Bonjour discovery, self-healing (resolve retries, re-advertising, watchdog)
- Subnet scan and manual peer entry for networks that block multicast
- Apple devices on a *different* Wi-Fi in range show up too, tagged "peer-to-peer" (AWDL); Android devices need the same Wi-Fi
- Custom device name on every platform (menu bar → Rename this Mac; iOS: 本机 → 重命名本机; Android: 本机 → 重命名本机)
- Send files, or pick photos and videos straight from the library (iOS / Android: Send from Photos; macOS: menu → Send from Photos…)
- Receive on any platform, with progress on both ends
- Open or share files from other apps (iOS: Open in / Share, Android: share sheet)
- Tap a received file to preview it with the system viewer; folders are browsable in-app on iOS
- Received photos and videos are saved to the system photo library (iOS and Android; can be turned off)
- "Sent" and "Received" keep a log, each with a one-tap clear (clearing received deletes the files)
- Verified delivery: the byte count is checked before a file is handed over

## How it works

```
Sender                                  Receiver
┌────────────┐  POST /macdrop/begin   ┌────────────┐
│ 2 MiB      │ ────────────────────► │ staging    │
│ chunks +   │  POST /macdrop/chunk   │ size check │
│ offsets    │ ────────────────────► │ finalize   │
└────────────┘  POST /macdrop/finish  └────────────┘
```

- **Discovery** — Bonjour `_macdrop._tcp`, with resolve retries, re-advertising after a wake/foreground and a watchdog that restarts a silent browser. Instance names must be unique, so a name clash (two devices called "MacBook Pro") retries as "MacBook Pro (2)" instead of silently staying invisible. A peer leaves the list only when it really goes away.
- **Fallback** — if the network drops multicast, *Scan the LAN* probes port `52345` across the local /24 and adds whatever answers; manual entry by IP also works.
- **Transfer** — HTTP/1.1 with keep-alive; 2 MiB chunks travel over up to 3 parallel connections, each acknowledged before the next one starts.
- **Integrity** — the receiver compares the written byte count with the announced size and rejects mismatches.
- **Delivery** — macOS and iOS move a verified file into place; Android publishes a pending `MediaStore` entry.

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/macdrop/ping` | Health check: device name and port |
| POST | `/macdrop/begin?id=&name=&path=&size=&root=` | Announce a transfer, create the staging file |
| POST | `/macdrop/chunk?id=&offset=` | Append a chunk (raw body) |
| POST | `/macdrop/finish?id=` | Verify and deliver |
| POST | `/macdrop/abort?id=` | Discard an incomplete transfer |

Default port is `52345`. When it is taken, an app falls back to a random port and advertises the real one through Bonjour.

## Build and run

### macOS

```bash
cd macos && ./build-app.sh      # dist/MoonDrop.app and dist/MoonDrop.zip
```

On the target Mac: unzip, then run `install.command`. It quits the running copy, installs to `/Applications/MoonDrop.app`, clears the quarantine attribute and launches.

### iOS

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cd ios
xcodegen generate
open MoonDropMobile.xcodeproj      # pick a team, then run on a device
```

The Local Network permission is requested on first launch. Received files are in **Files → On My iPhone → MoonDrop → Received**.

### Android

Requires JDK 17+ and the API 36 SDK.

```bash
cd android && ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Received files are published to **Download/来自另一台Mac**. The receiver runs as a foreground service, so transfers continue in the background.

## Usage

1. Start MoonDrop on both devices, on the same network.
2. Send: pick files, pick photos/videos from the library (or drag them onto the macOS panel). iOS and Android ask which device to use.
3. The receiver announces the finished file — tap it to preview, or use **Share** to pass it on. Photos and videos are copied into the system library as well.

History: "Sent" and "Received" each keep a list with a one-tap clear in the section header (clearing received deletes the files; the photo library copies stay).

Name the devices you can see: **Rename this Mac** in the macOS menu, and 重命名本机 in the 本机 card on iOS / Android.

When devices are online on the same Wi-Fi but do not appear: check the address and advertise line in the 本机 card, then use **Scan the LAN**; if that fails too, add the peer by IP. Peers tagged "peer-to-peer" are on a different Wi-Fi and reachable over the AirDrop-style direct link — Apple devices only.

To send from another app, use **Share → MoonDrop** (Android) or **Open in / Share → MoonDrop** (iOS). Files are staged and are only sent once you pick a target.

## Data locations

| Content | Path |
|---|---|
| Settings | `UserDefaults` (`com.macdrop.settings.v1`) |
| Device name | same settings store (macOS), `com.macdrop.mobile.deviceName` (iOS), `macdrop/device_name` (Android) — falls back to the host or model name |
| Staging | `~/Library/Application Support/MoonDrop/.staging` (macOS), app sandbox (mobile) |
| Transfer log | `~/Library/Application Support/MoonDrop/logs/transfer.log` |
| Received files | `~/Downloads/来自另一台Mac` (macOS), `Download/来自另一台Mac` (Android), `Files → On My iPhone → MoonDrop → Received` (iOS) |
| Received media | `Pictures/MoonDrop` and `Movies/MoonDrop` (Android), the photo library (iOS) |

## Testing

```bash
cd macos
./test-e2e.sh 52399      # chunked transfer, SHA256, name collision, staging cleanup
./test-discovery.sh      # two instances: discovery, no self-discovery, same-name peers
```

## Security

- Plain HTTP: traffic is **not** encrypted, and the receiver does **not** authenticate senders.
- Any host that can reach the port may send files — use MoonDrop on trusted networks only.
- Peer file names are sanitized, and existing files are never overwritten.
- `/macdrop/quit` is loopback-only and exists on macOS only.

## Limitations

- Transfers are not resumable; an interrupted transfer is discarded.
- iOS suspends discovery and listening in backgrounded apps, so keep the receiver in the foreground for large files; Android keeps them alive with a foreground service.
- The subnet scan only finds devices listening on the default port `52345`, and nothing works across a network that isolates clients from each other.
- Reaching a device on a *different* Wi-Fi works only between Apple devices (AWDL peer-to-peer); Android needs the same Wi-Fi.
- Only the byte count is verified, not a content hash.
- Android lists received files flat, without their folder hierarchy.

## Layout

```
macos/    Swift package + AppKit menu bar app
ios/      SwiftUI app (XcodeGen) with a Share extension
android/  Kotlin app (Gradle)
assets/   icon sources
tools/    icon generator
```

## Development notes

- Swift 6 renamed several `NetService` APIs; older snippets no longer compile.
- Validate `sockaddr` lengths: IPv4 is 16 bytes, not `sockaddr_storage.size`.
- Bonjour also finds the local advertisement; filter it out by the resolved address plus the listening port, never by display name.
- A duplicate service instance name makes the second publisher fail (`didNotPublish`, code -72001) and that device stays invisible forever — retry with a ` (2)` suffix. `macos/test-discovery.sh` 验证 5 covers it.
- iOS tears the published Bonjour record down when the app is suspended; re-advertise when it returns to the foreground.
- macOS signs with a stable Apple Development identity: an ad-hoc signature resets the Local Network permission on every reinstall, so peers are listed but every send fails with `NSURLError -1009`.
- Distribute the zip rather than the `.app` directory, so AppleDouble files do not break the signature.
