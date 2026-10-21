# MoonDrop for macOS

[English](README.md) | [简体中文](README.zh-CN.md)

Menu bar app that sends files to other Macs, iPhones and Android devices on the same network. The full picture is in the [repository README](../README.md).

## Install

```bash
./build-app.sh
```

Produces `dist/MoonDrop.app` and `dist/MoonDrop.zip`. On the target Mac, unzip and run `install.command`: it quits the running copy, installs to `/Applications/MoonDrop.app`, clears the quarantine attribute and launches.

## Use

| Action | How |
|---|---|
| Send | Drag files onto the circular panel, or use the menu → **Send Finder Selection** / **Choose Files to Send** |
| Pick a target | With several peers online the panel lists them; with one it sends directly |
| Receive | Files land in `~/Downloads/来自另一台Mac`; the panel shows progress and the received name |
| Log | Menu → **Transfer Log** (`~/Library/Application Support/MoonDrop/logs/transfer.log`) |

Permissions requested on first launch: **Local Network** (discovery and transfer) and **Automation** (reading the Finder selection).

## Troubleshooting

| Symptom | Fix |
|---|---|
| No peers found | Same network, allow the firewall prompt, check System Settings → Privacy & Security → Local Network, or add the peer by IP |
| Port in use | The app offers a random port; peers are still found through Bonjour |
| Cross-Mac drag not received | macOS broadcasts cross-machine drags over AWDL and third-party apps cannot initiate them — use **Send Finder Selection** instead |
| “MoonDrop is damaged” | `xattr -cr /Applications/MoonDrop.app` |

## Tests

```bash
./test-e2e.sh 52399
./test-discovery.sh
```

Both scripts isolate their configuration with `MACDROP_RECV_DIR`, `MACDROP_PORT` and `MACDROP_NAME`, and write only to `.test-tmp/`.
