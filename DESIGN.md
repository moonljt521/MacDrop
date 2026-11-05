---
version: alpha
name: MoonDrop Mobile
description: iOS and Android clients for the MoonDrop local-network file transfer utility.
colors:
  canvas: "#F7F9FC"
  surface: "#FFFFFF"
  surface-muted: "#F1F5F9"
  text-primary: "#0F172A"
  text-secondary: "#64748B"
  text-tertiary: "#94A3B8"
  divider: "#EDF1F6"
  primary: "#2C6BFF"
  primary-strong: "#1E56D6"
  primary-tint: "#EAF0FF"
  on-primary: "#FFFFFF"
  success: "#12B76A"
  success-text: "#067647"
  success-tint: "#E7F8F0"
  warning: "#F79009"
  warning-text: "#B54708"
  warning-tint: "#FFF4E5"
  danger: "#EF4444"
  danger-text: "#B42318"
  danger-tint: "#FEF3F2"
typography:
  brand:
    fontFamily: SF Pro
    fontSize: 20px
    fontWeight: 600
    lineHeight: 26px
    letterSpacing: 0px
  hero:
    fontFamily: SF Pro
    fontSize: 26px
    fontWeight: 700
    lineHeight: 32px
    letterSpacing: -0.5px
  section:
    fontFamily: SF Pro
    fontSize: 15px
    fontWeight: 600
    lineHeight: 20px
  body:
    fontFamily: SF Pro
    fontSize: 16px
    fontWeight: 400
    lineHeight: 22px
  row-title:
    fontFamily: SF Pro
    fontSize: 15px
    fontWeight: 500
    lineHeight: 20px
  meta:
    fontFamily: SF Pro
    fontSize: 12px
    fontWeight: 400
    lineHeight: 16px
  numeric:
    fontFamily: SF Pro
    fontSize: 24px
    fontWeight: 700
    lineHeight: 28px
    fontFeature: tnum
  button:
    fontFamily: SF Pro
    fontSize: 15px
    fontWeight: 600
    lineHeight: 20px
rounded:
  sm: 10px
  md: 14px
  lg: 18px
  xl: 24px
  full: 999px
spacing:
  xs: 4px
  sm: 8px
  md: 12px
  lg: 16px
  xl: 20px
  2xl: 24px
  3xl: 32px
components:
  card:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.lg}"
    padding: "{spacing.lg}"
  primary-button:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    rounded: "{rounded.md}"
    height: 48px
  secondary-button:
    backgroundColor: "{colors.primary-tint}"
    textColor: "{colors.primary-strong}"
    rounded: "{rounded.md}"
    height: 48px
  status-pill:
    backgroundColor: "{colors.surface-muted}"
    rounded: "{rounded.full}"
    height: 28px
  device-row:
    height: 64px
  segmented-control:
    backgroundColor: "{colors.surface-muted}"
    rounded: "{rounded.md}"
    height: 36px
  bottom-sheet:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.xl}"
---
## Overview

MoonDrop Mobile transfers files directly between a phone and another device on the same local network. The interface exists to answer three questions in order: is this phone reachable, which devices are nearby, and what is being sent or received. The visual direction is a calm, native utility: neutral surfaces, SF Pro/Roboto type, and brand blue reserved for the primary action and active state.

## Colors

Brand blue appears only on the primary button, selected segment, active icon tile, and focus rings. Every other surface stays neutral so the primary action is unambiguous.

Status color is never the only signal. A status is rendered as a colored dot plus text, except for large icons that carry an adjacent label.

`success`, `warning`, and `danger` are reserved for dots, icons, and fills. Text uses `success-text`, `warning-text`, and `danger-text` because the bright variants fall below 4.5:1 on white.

## Themes

The frontmatter records the light theme. Dark mode uses the values below; the active theme is selected from the system appearance, with no in-app switch.

| Token | Dark value |
|---|---|
| canvas | `#0B0F14` |
| surface | `#141A22` |
| surface-muted | `#1B232D` |
| text-primary | `#E8EDF5` |
| text-secondary | `#9AA7B8` |
| text-tertiary | `#6B7A8C` |
| divider | `#242D39` |
| primary | `#6E9BFF` |
| primary-strong | `#A8C3FF` |
| primary-tint | `#1A2740` |
| on-primary | `#06122B` |
| success | `#3DD68C` |
| success-text | `#6EE7B7` |
| success-tint | `#102A20` |
| warning | `#FDB022` |
| warning-text | `#FEC84B` |
| warning-tint | `#2A210F` |
| danger | `#F97066` |
| danger-text | `#FDA29B` |
| danger-tint | `#2A1512` |

## Typography

The scale has seven roles and no others. `brand` is the app name, `hero` is the local device name, `section` is a group heading, `row-title` is a device or file name, `body` is explanatory copy, `meta` is timestamp and size, and `numeric` is the transfer percentage.

iOS uses SF Pro through Dynamic Type text styles; Android uses Roboto through `sp`. Sizes in the frontmatter are the default values, and both platforms must scale with the system text-size setting.

Body copy never drops below 16px/sp. Labels never drop below 12px/sp.

## Layout

Screens use a single vertical scroll; there is no tab bar. History is split by a segmented control instead of a second screen.

Horizontal page padding is `spacing.xl` (20px). Cards use `spacing.lg` (16px) internal padding. Adjacent cards are separated by `spacing.md` (12px); sections by `spacing.2xl` (24px).

The local device block is the first content on the screen and the only block with the `hero` type role. The transfer block sits directly below it whenever a transfer is active, before the send actions.

Interactive targets are at least 44×44pt on iOS and 48×48dp on Android, even when the visible icon is smaller. A device row and a history row are both tappable across their full width; no row contains a second primary action.

## Elevation & Depth

Cards use no shadow and no border. Light theme separates `surface` from `canvas` through color and spacing; dark theme does the same with a one-step surface lift. The only elevated layer is a bottom sheet, which sits above the system scrim.

Modals are bottom sheets on both platforms, with rounded top corners. They rely on the system scrim; there is no custom backdrop blur.

## Shapes

Cards, sheets, and inner tiles use only `rounded.lg`, `rounded.xl`, `rounded.md`, and `rounded.full`. No square corners and no heavy outlines; separation comes from spacing, surface color, or the `divider` token at 1px.

## Components

**Local device card** — `hero` device name on `card`. Status is a dot plus one of `在线`, `启动中`, `广播未上线`. Port and address share one `meta` line. Rename is a borderless action, not a second button.

**Status pill** — `status-pill` shape with a 6px dot and `meta` text. Current states: online, starting, advertising unavailable.

**Device row** — 40px icon tile using `primary-tint`, `row-title` name, `meta` address, trailing chevron. Peer-to-peer devices add a `warning-tint` pill. Tapping the row starts the send flow with that device preselected.

**Send actions** — two tiles: file sending uses `primary-button`, album sending uses `secondary-button`. Both collapse to 40% opacity and become non-interactive when no peer is available.

**Transfer card** — `section` status label, `numeric` percentage, a 6px progress track, and one `meta` line with file name and size. Large transfers add a `warning-text` line. A finished transfer shows success or failure for 5 seconds, then the card leaves the scroll.

**History row** — 40px file-type icon tile, `row-title` file name, `meta` line with size, time, and peer. iOS keeps swipe-to-delete; Android keeps the existing left-swipe delete. The trailing overflow menu holds open, share, save-to-album, install, and delete; received media already saved to the library omits save-to-album.

**Empty state** — 32px line icon, `row-title` heading, one `meta` line, at most one `secondary-button`. No illustrations and no multi-paragraph empty copy.

**Storage and help** — one row opens a bottom sheet. Long storage and connection explanations never live in the main scroll.

## Do's and Don'ts

- Do use the system navigation bar and large title on iOS; do not build a custom top bar.
- Do use `insetGrouped` list rhythm on iOS and cards on Android; do not force one platform's container onto the other.
- Do keep one brand-blue element per viewport; do not stack colored cards.
- Do not use gradients, neon colors, or glow effects.
- Do not add borders to cards or rows; use spacing and `divider`.
- Do not add a tab bar for this single-task utility.
- Do not put more than one primary action in a row.
- Do not shrink body copy below 16px/sp or touch targets below 44pt/48dp.
