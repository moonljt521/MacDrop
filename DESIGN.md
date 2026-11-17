# MoonDrop Mobile — Design

Single design reference for the iOS and Android clients. macOS is out of scope.
Tokens live in `ios/MoonDrop/UI/MoonTheme.swift` and `android/app/src/main/java/com/macdrop/mobile/ui/MoonTheme.kt`; update this file when they change.

## Principles

- One task: send or receive a file between nearby devices. No tab bar, no dashboard.
- The nearby-device stage is the focal point; the file/photos tray is always within thumb reach.
- Show only states that exist. Pending is not sent, and progress is real, never simulated.
- Neutral surfaces and system type carry the hierarchy; brand blue is reserved for progress, links, and status.
- Never infer a device type, model, or identity from its name; the peer reports its own type.

## Screen Anatomy

Top to bottom, one vertical scroll:

1. **Brand bar** — crescent + MoonDrop on the left, settings on the right.
2. **This device row** — name, reachability, chevron to connection details, separate rename button.
3. **Page title** — the current mode ("Nearby", "Receiving", "Result", etc.) plus one subtitle with the actual device count or hint.
4. **Stage** — nearby devices, pending files, the live transfer ring, or the result.
5. **Secondary actions** — scan again / manual add.
6. **Anchored tray** — file and photos actions, then the most recent transfer row (opens history).

Settings, connection details, storage help, and manual add are sheets. History is a full-height sheet, never a block on the home screen.

## Device Stage

The stage has one local device mark at the bottom centre and peers arranged on decorative arcs. Peers are real discovered endpoints only; the arcs are decoration, not distance.

Each peer shows the shape of the device it actually is: phone, tablet, or computer. The type comes from the peer itself — it is advertised in the Bonjour TXT record and in the `/macdrop/ping` response — never inferred from the device name, because names are whatever the user typed. A peer that reports no type keeps the generic computer mark; its icon may be wrong, but nothing about it is invented. The local device mark follows the same rule and shows a tablet on iPad and a tablet-sized Android device.

| Peers | Arrangement |
|---|---|
| 1 | one slot at top centre |
| 2 | two slots on the upper arc |
| 3 | one top, two lower-left / lower-right |
| 4 | 2 + 2 (upper arc, lower arc) |
| 5 | 3 + 2 |
| 6 | 3 + 3, single-line names, compact glyph |
| >6, or enlarged text | native list fallback |

- No pagination in any case.
- Peer glyphs shrink as density rises: 68 → 56 for 4–5 peers; the 6-peer layout is smaller on Android and uses single-line names on both platforms.
- Every peer is one button with the accessible label "Send to <name>" and the route as its value.
- The local device and its "This device" label stay at the bottom centre of the stage.
- If names cannot fit, fall back to a full-width list instead of truncating every row.

## Rescan

The rescan action is a radar, not a spinner.

- The scan streams. Devices found and the final outcome arrive as they happen. A device reaches the stage the moment the scan finds it, not twelve seconds later in one batch.
- This device is the radar. A soft beam leaves it at the bottom centre and turns at a constant rate, bright at its leading edge and fading behind it.
- The beam only lights the field above this device. What it points at behind the device is masked, as if the device itself blocked it, and it fades with distance so it never cuts a hard edge across the canvas. It stays behind the device tiles and never tints their labels.
- The action button carries a miniature of the same radar, turning at the same rate and in the same phase, so the two read as one mechanism rather than two decorations.
- The radar is an activity signal, not a percentage. It turns for exactly as long as the scan runs and vanishes when the scan ends. It never claims a number it cannot back up.
- The real numbers live where numbers belong: the subtitle counts what this scan found, and each device appears the moment it is found.
- Devices that arrive mid-scan land with a scale-and-fade spring, and the other devices make room for them.
- The subtitle carries the scan state: what this scan has found so far, then the outcome.
- A scan result never replaces the device stage. A successful scan keeps the list on screen and states the outcome in the subtitle; only a scan that found nothing at all raises the error card with the next step.
- A scan stays visible for at least 1 s even when the network answers instantly, so the tap is always acknowledged.
- Devices found by the scan are LAN discoveries, not manual entries: they read "Same Wi-Fi", never "Manual".

Reduce Motion drops the spring and stops the radar. It stays on screen, pointing at one place.

Android must match this. It is implemented on both platforms: Android draws the same beam in `MoonOrbitLayout` and the same dial in `MoonRadarDrawable`, sharing one radar period (`MoonRadar.PERIOD_MS` / `MoonRadar.period`) so the two read as one mechanism.

## States

The same central slot switches in place, so two states never stack.

| State | Content |
|---|---|
| Idle | nearby-device stage |
| Pending | pending count, choose/send/cancel; stage is replaced, truthfully labelled as pending |
| Sending | real percentage ring, file name, size, large-file warning |
| Receiving | real percentage ring, sender and file |
| Result | success/error icon, message, automatic dismissal |

The ring uses measured progress only. It never animates on a timer or fills to a guessed value.

## Wi-Fi Name

The network name answers the only question that matters when a peer is missing: are both devices on the same network?

- It lives in the connection details sheet, as one more row about this device. The main screen mentions it only when no peer was found at all; with peers on screen the name adds nothing and the stage stays the focal point.
- The name comes from the system, never from a guess. iOS needs the Access Wi-Fi Information capability plus precise-location authorization; Android needs the fine-location permission *and*, from Android 13 on, the nearby-devices permission: both platforms treat the SSID as location data, and several OEM builds redact the name unless every one of them is granted.
- The system location master switch matters too. With location services turned off, Android redacts the SSID no matter how many permissions the app holds, so the row says "needs system location on" and links straight to that settings page.
- Permission is requested when the user taps that row, never at launch. Without it the row reads "Connected · tap to show the name"; after a refusal it points at Settings; when permission was granted but the system still withholds the name, it says which one is missing instead of pretending.
- The app never invents a name. If it cannot read one, it states that the device is connected and leaves it there.

## Clipboard Capture
Entering the app can turn the clipboard's plain text into a pending file.

- The capture runs when the app comes to the foreground, and only plain text is taken; images and files on the clipboard are ignored.
- The text becomes a `.txt` file named `Clipboard-<timestamp>.txt` (`剪贴板-<时间戳>.txt` in Chinese), written to the app's private storage, never into Documents.
- It joins the same pending queue as shared files. The app never picks a device on its own: the user chooses the target and confirms, exactly like any other pending file.
- The same text is captured once. A repeat of identical text inside a 10-minute window, or text already sitting in the pending queue, is ignored. Cancelling the pending queue clears that memory so the text can be captured again.
- Captured files are deleted once they are sent, and cancelling the queue deletes them too. Nothing is left behind on disk.
- A settings switch, "Auto-capture clipboard text", turns the whole thing off. It is on by default.
- iOS asks for paste permission: the first read shows the system "Allow Paste?" prompt, and the read is retried for a few seconds so the capture still lands after the user allows it. Android reads the clipboard only while focused and shows the system "Pasted" toast.
- The pending state names the source, so the user knows where the file came from.

## Tray and Sheets

- Tray is anchored above the safe area: file action on `ink`, photos action on `surface`, both at least 56 pt/dp.
- Recent transfer is one compact row and opens the complete history sheet. At very large text sizes it moves into the scroll so the tray does not consume the screen.
- History: sent/received segmented control, date-grouped sections, preview/share/save/delete per row, explicit Close, and a native alert with a visible Cancel for destructive clear.
- Settings: appearance, language, auto-save to photos, auto-capture clipboard text, background receiving, connection details, storage help, version.
- Every sheet has a visible close or done control; drag-to-dismiss is never the only exit.

## Color

Shared light/dark tokens:

| Token | Light | Dark | Use |
|---|---|---|---|
| canvas | `#F7F8FB` | `#11141C` | screen background |
| surface | `#FFFFFF` | `#202631` | cards, dock, sheets |
| surfaceMuted | `#EDF1FB` | `#242E47` | tints, local device |
| ink / onInk | `#233149` / `#FFFFFF` | `#DCE5FA` / `#1B2740` | file action |
| textPrimary | `#202B40` | `#EDF1FB` | primary copy |
| textSecondary | `#687284` | `#A7B1C4` | hints, routes |
| divider | `#E2E7F0` | `#303B50` | hairlines at 1 physical pixel |
| primary | `#3E5BCA` | `#A9BBFF` | progress, links, local icon |
| success | `#227B65` | `#7DD4B6` | success state |
| warning | `#F79009` | `#FDB022` | warnings |
| danger | `#EF4444` | `#F97066` | destructive/errors |
| dangerText | `#B42318` | `#FDA29B` | error copy on surfaces |

Rules:

- Secondary text must clear 4.5:1 against canvas/surface; do not lighten it for aesthetics.
- Status color is never the only signal: pair it with text or an icon.
- No shadows, neon, or heavy borders. Separation comes from surface steps, hairlines, and spacing.
- Do not tint whole cards; one primary-colored object per viewport is enough.

## Typography

Semantic roles, never ad-hoc sizes:

| Role | iOS | Android |
|---|---|---|
| Brand | `.title3` semibold | 21sp medium |
| Page title | `.largeTitle` bold | 29sp medium, tight tracking |
| Section / sheet title | `.title3` semibold | 17sp medium |
| Device/file name | `.callout` medium | 13sp medium |
| Body / hint | `.callout` | 16sp |
| Meta (route, size) | `.footnote` | 13sp |
| Label | `.caption` | 12sp |
| Numeric progress | `.title3` semibold | 28sp semibold |
| Button | `.callout` semibold | 16sp medium |

- Use semantic text styles on iOS and `sp` on Android so Dynamic Type / font scale works.
- Body copy never below 16; labels never below 11–12.
- Names may use two lines on the stage; only the 6-peer layout uses one line, with the full name still available to accessibility and the send sheet.

## Shape and Spacing

- Radii: panel 22, dock 24, control 14–18, device tile 24 (20 when compact), small 10.
- Spacing steps: 4 / 8 / 12 / 16 / 20 / 24 / 32.
- Hairlines are one physical pixel, not one point/dp.
- Cards use internal padding of 16–20; grouped rows are separated by spacing, not boxes.

## Appearance

- Three modes: follow system (default), light, dark.
- Persisted: iOS `moon.appearance`; Android `moon_ui_prefs.appearance`.
- iOS applies a window-level `overrideUserInterfaceStyle`, so already-presented sheets switch immediately and follow-system still tracks the OS.
- Android wraps the activity base context with the night configuration, then recreates the activity.
- Both palettes must be verified with real content; do not design only for light.

## Language

- Simplified Chinese (default) and English.
- Persisted: iOS `moon.language`; Android `moon_ui_prefs.language`.
- Runtime string tables (`MoonPreferences.swift`, `MoonStrings.kt`) switch copy immediately without restart; do not rely on system language.
- Cover titles, hints, buttons, alerts, toasts, accessibility labels, route names, history dates, and send/receive results.
- Never translate user data: device names, file names, IPs, ports.
- Date headings follow the selected language (Today/Yesterday and localized date patterns), not the system locale.
- Language labels themselves stay native: 简体中文 / English.

## Accessibility

- Minimum touch target: 44×44 pt (iOS), 48×48 dp (Android).
- Every interactive element has a spoken label; decorative arcs and glyphs are hidden.
- Peer buttons read "Send to <name>, <route>"; rename, settings, and history have explicit labels.
- Support Dynamic Type / font scale: layouts reflow, and dense stages fall back to lists at large sizes.
- Respect Reduce Motion: no decorative transitions when enabled.
- Truncation never hides the only way to identify a target; full names remain in the send sheet and accessibility label.

## Copy

- Say "device" in prose, never "other Mac/phone" as a claim about the peer. The shape may show phone, tablet or computer, because the peer reports its own type; the words stay generic.
- Use "This device", "Nearby", "Pending", "Sent", "Received".
- Errors state what failed and the next step; do not blame the network without evidence.
- No fake success: a pending file is described as waiting, never as delivered.

## Maintenance

- One design document only: this file. Do not add per-platform design docs.
- Change tokens in code first, then update the tables here in the same commit.
- Build both platforms after token or layout changes; UI acceptance is done on a physical iPhone and an Android device when available.
