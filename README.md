# MacDrop

**English** | [简体中文](README.zh-CN.md)

Send files and folders between Macs on the same local network — no cloud, no accounts, no third-party servers. MacDrop lives in the menu bar, adds a small floating drop target, and moves data directly from one Mac to the other over HTTP.

Version 1.4 · macOS 13+ · Apple silicon (universal build instructions below)

## Features

- **Direct LAN transfer** — files travel straight between the two Macs.
- **Floating drop target** — a quiet 64×64 circular panel that expands while you drag files onto it, then shrinks back when done.
- **Multi-device picker** — when more than one peer is online, choose the destination before sending.
- **Receive-side progress** — the panel shows incoming transfers with a live percentage.
- **Folder support** — directories are walked recursively and recreated on the receiver.
- **No partial files** — data is written to a staging area, verified against the announced size, then moved into place atomically.
- **Safe name collision handling** — `report.pdf` becomes `report (1).pdf` instead of overwriting.
- **Three independent send paths** — floating panel, Finder selection, or a file chooser.
- **Self-healing upgrades** — a newly launched instance asks any older running instance to quit first.

## Requirements

- macOS 13 Ventura or newer on both Macs.
- Both Macs on the same local network (Wi-Fi or Ethernet).
- Two one-time permission prompts on first launch:

| Prompt | Why it is needed |
|---|---|
| Local Network | Bonjour discovery and direct connections |
| Automation (Finder) | Read the current Finder selection for menu-bar sending |

Building from source requires a Swift 5.9+ toolchain (tested with Swift 6 / Xcode 26.3).

## Install

### From a release zip

1. Copy `dist/MacDrop.zip` to the other Mac and unzip it.
2. Open the unzipped folder and double-click `install.command`.

The script quits any running copy, installs to `/Applications/MacDrop.app`, removes the quarantine attribute, verifies the ad-hoc signature, and launches the app.

> If macOS blocks the script, right-click → **Open**, or run `bash install.command` in that folder.

### Build from source

```bash
git clone git@github.com:moonljt521/MacDrop.git
cd MacDrop
./build-app.sh
```

Outputs:

- `dist/MacDrop.app`
- `dist/MacDrop.zip` — the distributable archive (contains the app and `install.command`)

`build-app.sh` runs `swift build --disable-sandbox` because plain `swift build` can fail with `sandbox_apply: Operation not permitted` in some environments.

By default the build targets the host architecture. To produce a universal binary:

```bash
swift build -c release --disable-sandbox --arch arm64 --arch x86_64
```

The universal binary is written to `.build/apple/Products/Release/MacDrop`; copy it into the app bundle manually (or adapt `build-app.sh`).

## Usage

> The app UI is currently in Chinese. Menu labels below are translated for readability; the receive folder keeps its Chinese name.

### Sending

| # | Channel | How |
|---|---|---|
| A | Floating panel | Drag files from Finder onto the circular panel. With one peer online it sends immediately; with two or more, pick a destination from the list. |
| B | Finder selection | Select items in Finder → menu bar icon → peer name. Uses Apple Events and does not depend on drag-and-drop. |
| C | File chooser | Menu bar icon → **Choose Files to Send…** |

Channel B is the most reliable fallback when cross-Mac drag gestures are not delivered by the system.

### Menu reference

| Item | Action |
|---|---|
| Peer list | Send the current Finder selection to that peer |
| Send Finder Selection… | Send the current Finder selection to the first peer |
| Choose Files to Send… | Pick files or folders to send |
| Add Peer Manually… | Connect by IP when Bonjour discovery is blocked; shown when no peers are found |
| Show/Hide Floating Panel | Toggle the drop target |
| Open Receive Folder | Reveal the destination folder |
| Open Data Folder | Open staging and logs |
| Transfer Log | Open `transfer.log` |
| Quit MacDrop | Exit |

### Receiving

Incoming files are written to `~/Downloads/来自另一台Mac` by default. Folder structure is preserved. When a transfer completes, the panel shows the received file name and Finder reveals it if **auto reveal** is enabled (on by default).

## How it works

```
Mac A                                    Mac B
┌──────────────┐                        ┌──────────────┐
│ Finder drag  │                        │ HTTP server  │
│      ↓       │   HTTP chunked upload  │      ↓       │
│ Drop panel   │  ───────────────────►  │ Staging file │
│              │   (Bonjour discovery)  │      ↓       │
│              │                        │ Size check   │
│              │                        │ Atomic move  │
└──────────────┘                        └──────────────┘
```

- **Discovery** — Bonjour service type `_macdrop._tcp`, with manual IP entry as a fallback.
- **Transfer** — HTTP/1.1, 2 MiB sequential chunks, each acknowledged before the next is sent. Chunks carry an explicit offset, so the receiver writes them at the correct position.
- **Staging** — chunks are appended to a temporary file under `~/Library/Application Support/MacDrop/.staging/`.
- **Verification** — on `finish`, the receiver compares the staged file size with the announced size. A mismatch is rejected and the temporary file is removed.
- **Atomic delivery** — a verified file is moved into the receive folder in one step. Interrupted transfers never leave a corrupt file in the destination.
- **Cleanup** — staging leftovers from a crash are removed on the next launch.

### HTTP endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/macdrop/ping` | Health check, returns device name and version |
| POST | `/macdrop/begin?id=…&name=…&path=…&size=…&root=…` | Announce a transfer and create the staging file |
| POST | `/macdrop/chunk?id=…&offset=…` | Append a chunk (body is raw bytes) |
| POST | `/macdrop/finish?id=…` | Verify and move the file into place |
| POST | `/macdrop/abort?id=…` | Discard an incomplete transfer |
| POST | `/macdrop/quit` | Ask the local instance to exit (loopback only) |

## Data locations

| Content | Location |
|---|---|
| Source code | clone directory |
| Distributable app | `dist/MacDrop.zip` |
| Staging | `~/Library/Application Support/MacDrop/.staging/` |
| Transfer log | `~/Library/Application Support/MacDrop/logs/transfer.log` |
| Received files | `~/Downloads/来自另一台Mac` (default) |
| Settings | `UserDefaults`, key `com.macdrop.settings.v1` |

Runtime data deliberately lives in Application Support rather than in the project directory or `~/Library/Caches`: copying the app to another Mac will not carry staging or logs, and the system will not purge them.

## Testing

Build the release binary first (`./build-app.sh` or `swift build -c release --disable-sandbox`), then:

```bash
./test-e2e.sh 52399       # single instance: chunked transfer, SHA256 check,
                          # name collision, staging cleanup
./test-discovery.sh       # two instances: mutual discovery, no self-discovery,
                          # cross-instance transfer, duplicate device names
```

Both scripts isolate their configuration with `MACDROP_RECV_DIR`, `MACDROP_PORT`, and `MACDROP_NAME`, and write only to `.test-tmp/` inside the project.

### Environment variables

| Variable | Effect |
|---|---|
| `MACDROP_RECV_DIR` | Override the receive directory |
| `MACDROP_PORT` | Override the listening port (default `52345`) |
| `MACDROP_NAME` | Override the advertised device name |
| `MACDROP_UI_PROBE` | Development only: render UI snapshots to a directory |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| No peers found | Confirm both Macs are on the same network. Allow the firewall prompt. On macOS, check **System Settings → Privacy & Security → Local Network** and enable MacDrop. Use **Add Peer Manually…** if Bonjour is blocked. |
| Manual peer cannot connect | Verify the app is running and the port is listening: `lsof -nP -iTCP:52345 -sTCP:LISTEN`. If occupied, use a different port. |
| Port already in use | On launch, MacDrop offers to switch to a random port automatically. |
| Cross-Mac drag is not received | Expected in some environments: macOS broadcasts cross-Mac drags via AWDL, which third-party apps cannot initiate. Use channel B or C. |
| “MacDrop is damaged” | Run `xattr -cr /Applications/MacDrop.app`, or install from the provided zip instead of copying the `.app` directory directly. |
| App will not launch on an Intel Mac | The default build is arm64-only. Rebuild with the universal flags above. |

## Security model

MacDrop is designed for trusted local networks:

- Traffic is plain HTTP — **not encrypted**.
- The HTTP server does **not authenticate** senders; any host that can reach the port can start a transfer.
- Incoming files are accepted automatically; the auto-reveal setting only controls whether Finder opens after completion.
- File names from peers are sanitized, and existing files are never overwritten.
- `/macdrop/quit` is restricted to loopback connections.

Do not expose the port to the public internet or use MacDrop on untrusted networks.

## Limitations

- macOS does not let third-party apps initiate cross-Mac drag events. The floating panel receives same-Mac drags and any cross-Mac drags the system happens to deliver; channels B and C always work.
- Transfers are not resumable. An interrupted transfer is discarded, and staging files are cleaned up on the next launch.
- Interrupted or rejected transfers are never placed in the destination folder, so a partial file cannot be mistaken for a complete one.

## Project layout

```
Sources/MacDrop/
├── main.swift
├── AppDelegate.swift          # Lifecycle, HTTP routes, send orchestration
├── Core/
│   ├── BonjourService.swift   # Discovery and manual peers
│   ├── Config.swift           # Settings, staging and log paths
│   ├── HTTPService.swift      # Minimal HTTP/1.1 server
│   └── TransferEngine.swift   # Chunked send/receive, staging, atomic move
└── UI/
    ├── DropPanel.swift        # Floating panel, picker, progress UI
    └── StatusItemController.swift  # Menu bar, Finder bridge, logging
```

## Notes for contributors

- Under Swift 6, `NetService` APIs were renamed (`setTXTRecord`, `publish()`, no `fullName`, optional `addresses`). Older snippets will not compile.
- Validate `sockaddr` sizes carefully: IPv4 is 16 bytes; do not use `sockaddr_storage.size` (128) as a lower bound.
- Bonjour browsers see the local advertisement too. Self-discovery must be filtered by host name plus port, not by display name — two Macs can share the same name.
- The app bundle is ad-hoc signed as a whole and then re-signed per binary; `xattr -cr` removes quarantine after distribution. Distribute the zip rather than copying the `.app` directory, to avoid AppleDouble (`._*`) files breaking the signature.
- On launch, the new instance asks any older instance to quit over loopback HTTP, then force-terminates it after a timeout.
