# MoonDrop

**English** | [简体中文](README.zh-CN.md)

Native file transfer between **Mac, iPhone and Android** over the local network. No cloud, no accounts, no third-party servers — bytes move directly between devices.

| Platform | Stack | Directory | Minimum OS | Version |
|---|---|---|---|---|
| macOS | Swift · AppKit | [`macos/`](macos) | macOS 13 | 1.5 |
| iOS | Swift · SwiftUI · Network.framework | [`ios/`](ios) | iOS 16 | 1.5.0 |
| Android | Kotlin · platform APIs | [`android/`](android) | Android 10 (API 29) | 1.5.0 |

> The product is MoonDrop; the repository and the LAN protocol keep their original `macdrop` identifiers (`_macdrop._tcp`, `com.macdrop.*`) so existing installs stay compatible.

## Features

- Bonjour discovery, plus manual peer entry by IP
- Send files and folders; folder structure is recreated on the receiver
- Receive on any platform, with progress on both ends
- Open or share files from other apps (iOS: Open in / Share, Android: share sheet)
- Tap a received file to preview it with the system viewer; folders are browsable in-app on iOS
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

- **Discovery** — Bonjour `_macdrop._tcp`; a peer leaves the list only when it really goes away.
- **Transfer** — HTTP/1.1, sequential 2 MiB chunks, each acknowledged before the next one starts.
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
2. Send: pick files (or drag them onto the macOS panel). iOS and Android ask which device to use.
3. The receiver announces the finished file — tap it to preview, or use **Share** to pass it on.

To send from another app, use **Share → MoonDrop** (Android) or **Open in / Share → MoonDrop** (iOS). Files are staged and are only sent once you pick a target.

## Data locations

| Content | Path |
|---|---|
| Settings | `UserDefaults` (`com.macdrop.settings.v1`) |
| Staging | `~/Library/Application Support/MoonDrop/.staging` (macOS), app sandbox (mobile) |
| Transfer log | `~/Library/Application Support/MoonDrop/logs/transfer.log` |
| Received files | `~/Downloads/来自另一台Mac` (macOS), `Download/来自另一台Mac` (Android), `Files → On My iPhone → MoonDrop → Received` (iOS) |

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
- iOS suspends discovery and listening in the background; Android keeps them alive with a foreground service.
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
- Bonjour also finds the local advertisement; filter it out by TXT id or by local address.
- The app bundle is ad-hoc signed and the binary is re-signed separately; run `xattr -cr` after distribution.
- Distribute the zip rather than the `.app` directory, so AppleDouble files do not break the signature.
