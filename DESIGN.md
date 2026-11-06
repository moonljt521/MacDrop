# MoonDrop Mobile — Design

Single design reference for the iOS and Android clients. macOS is out of scope.
Tokens live in `ios/MoonDrop/UI/MoonTheme.swift` and `android/app/src/main/java/com/macdrop/mobile/ui/MoonTheme.kt`; update this file when they change.

## Principles

- One task: send or receive a file between nearby devices. No tab bar, no dashboard.
- The nearby-device stage is the focal point; the file/photos tray is always within thumb reach.
- Show only states that exist. Pending is not sent, and progress is real, never simulated.
- Neutral surfaces and system type carry the hierarchy; brand blue is reserved for progress, links, and status.
- Never infer a device type, model, or identity from its name.

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

## Tray and Sheets

- Tray is anchored above the safe area: file action on `ink`, photos action on `surface`, both at least 56 pt/dp.
- Recent transfer is one compact row and opens the complete history sheet. At very large text sizes it moves into the scroll so the tray does not consume the screen.
- History: sent/received segmented control, date-grouped sections, preview/share/save/delete per row, explicit Close, and a native alert with a visible Cancel for destructive clear.
- Settings: appearance, language, auto-save to photos, background receiving, connection details, storage help, version.
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

- Say "device", never "other Mac/phone", because the protocol does not expose peer type.
- Use "This device", "Nearby", "Pending", "Sent", "Received".
- Errors state what failed and the next step; do not blame the network without evidence.
- No fake success: a pending file is described as waiting, never as delivered.

## Maintenance

- One design document only: this file. Do not add per-platform design docs.
- Change tokens in code first, then update the tables here in the same commit.
- Build both platforms after token or layout changes; UI acceptance is done on a physical iPhone and an Android device when available.
