# WallLocus

> **Remember every wallpaper's placement on every display.**

A small, hackable macOS video and image wallpaper tool.  
`Wall` + `Locus` — it remembers each wallpaper's **positional footprint** on every display.

English · [简体中文](README.zh-CN.md)

---

A self-contained macOS wallpaper app in about 8,900 lines of Swift. No third-party dependencies, no telemetry, no account. Built with nothing but `swiftc` — **no full Xcode install required**.

## What makes it different

**Two-dimensional memory: display × wallpaper.**

Every wallpaper remembers its own scale mode, zoom, and horizontal/vertical offset **per display**:

| Display          | Wallpaper A        | Wallpaper B      |
| ---------------- | ------------------ | ---------------- |
| 4K external      | 150% · offset −0.20 | 100% · centred   |
| Built-in laptop  | 100% · centred      | 73% · offset +0.15 |
| Portrait monitor | 100% · offset −0.55 | 100% · centred   |

Swap displays or wallpapers and the previous framing comes back exactly. Most wallpaper apps offer at most one global fill/fit switch; here the framing is a property of **the pairing**.

## Drag a wallpaper onto a display to apply it

Pick up any wallpaper in the grid, drag it out of the window and release it over a display — that display takes it, and only that one.

- A hint card appears on each screen while dragging; the one under the pointer highlights
- Releasing outside a card does nothing, so a stray drop cannot repaint a monitor
- Dropping on a display row in the sidebar works too, and is the steadier path
- Dropping on the desktop copies the file out
- Can be switched off in settings

## Interface

Three panes, modelled on the macOS Photos app:

- **Sidebar** — displays, library categories, presets. All three keep their **own selection**, so you can have "this picture" and "that display" chosen at once
- **Grid** — the library. Five columns running edge to edge, thumbnails rounded to each image's own aspect ratio
- **Details** — file information, framing controls, and actions for the selected item

Both side panes resize by dragging their edges, and the widths persist. All three share one liquid-glass base whose rim tints with the wallpaper's colour temperature. A persistent box at the bottom of the sidebar shows the current scope's resolution and the wallpaper in use.

## Features

- **Video and still images**, using your own files
- **Per-display wallpapers**, with hot-plug support
- **Scale modes**: fill (crop), fit (letterbox), stretch
- **Zoom** 30–300%, **horizontal/vertical offset** ±100%, each with a type-in field
- **Auto-pause on fullscreen**: pauses only the display that is fully covered (≥96%)
- **Pause on battery** (optional)
- **Menu bar resident**: the Dock icon hides when the window closes
- **Bounded overhead**: video through AVPlayerLayer's hardware decoding, images through ImageIO downsampling; bitmaps for displays not in use are released immediately
- **Video compatibility check**: warns about undecodable videos, with a one-click HEV1 → HVC1 retag
- **The library is a folder**: `~/Pictures/WallLocus` by default, each subfolder a category
- **Drag in from Finder**: drop images or videos anywhere on the window
- **Refresh on its own**: a folder fingerprint is compared when the app becomes active or you switch category or display; only a real change triggers a rescan
- **Toolbar + button** to add wallpapers; a search field filters by file name
- **Sorting**: by file name or modification date, either direction
- **Optional file names** in the grid
- **Context menus**: on a card — set as this display's wallpaper, reveal in Finder, move to Trash; on a category — move the whole folder to the Trash; on empty space — refresh, add files
- **Presets**: capture which wallpaper each display uses along with its framing; right-click to apply, rename, or delete
- **Bilingual UI**, following the system language

## Dropping a file copies it

Dropping an image from Finder **copies** the file into the wallpaper folder; the original stays where it was:

| The dropped file | Result |
| --- | --- |
| Already in the wallpaper folder | Used as is, not copied |
| Anywhere else | Copied in; the original remains |
| Name collision | Suffixed `-2` / `-3`, never overwritten |
| Copy fails | Falls back to the original path rather than blocking the add |

This keeps the library self-contained: moving or deleting the original later does not break anything.

## Measured overhead

Apple silicon, macOS 26, three displays (4096×2304 and 1080×1920) each showing a still image, 534 items in the library:

| Metric | Value |
| --- | --- |
| Physical footprint | **~270 MB** |
| CPU (idle) | **0.1 – 0.7 %** |
| Library of 534 items | ~+2 MB |

Memory is dominated by decoded bitmaps: roughly 20 MB for a 4096×2776 source, up to four kept, released as soon as no display needs them.

The library adds little: thumbnails decode at **their real display size × the screen scale** (about 480px on a Retina screen), only for visible cards, into a 48 MB cache. **Adding files triggers no decoding at all.**

> Note: `ps` reports a much higher RSS (~355 MB) because it counts mapped pages from shared system libraries. Use `footprint -p <pid>` for the real figure.

## Requirements

- macOS **13.0** or later
- Apple silicon or Intel (build a universal binary with `UNIVERSAL=1`)
- Only **Xcode Command Line Tools**

## Build

```bash
git clone https://github.com/ZEBRALD/walllocus.git
cd walllocus
./build.sh                 # current architecture
UNIVERSAL=1 ./build.sh     # universal binary (arm64 + x86_64)
```

The app lands in `build/WallLocus.app`.

## Install

```bash
cp -R build/WallLocus.app /Applications/
xattr -dr com.apple.quarantine /Applications/WallLocus.app
open /Applications/WallLocus.app
```

Builds are **ad-hoc signed and not notarised**, so Gatekeeper blocks the first launch. Right-click the app and choose **Open**.

## Usage

1. Add wallpapers with the **+** button, or drag images and videos **onto the window**.
2. Pick a display in the **sidebar**, or choose "All displays".
3. Select a wallpaper and click **Set as this display's wallpaper** — or just **drag it onto that display**.
4. Adjust **scale mode / zoom / horizontal / vertical** with the sliders or by typing a value. Changes apply live and are remembered per display × wallpaper.

Rename in **Finder** — the app deliberately offers no second naming path.

The box at the bottom of the sidebar shows the current scope's resolution and the wallpaper in use. It follows the selected display and is independent of which item is selected.

## Architecture

A wallpaper is an `NSWindow` at the desktop window level carrying either an `AVPlayerLayer` (video) or a `CALayer` (image). That keeps the implementation small and dependency-free, at the cost of two deliberate limitations:

- **Wallpapers vanish when the app quits** — they are the app's own windows, not system wallpapers.
- **Lock screen wallpapers are not supported** — the lock screen is drawn by a system process third-party windows cannot enter.

### A note on screen savers

`.saver` bundles are **unusable on macOS 26**: the system no longer scans `~/Library/Screen Savers/`,
and the Screen Saver pane only lists ExtensionKit `.appex` extensions. The full evidence is in [SCREENSAVER.md](SCREENSAVER.md).

## Configuration

State lives in `UserDefaults` under the bundle id `app.walllocus`:

- `walllocus.state.v1` — library, per-display assignments, per-display × per-wallpaper adjustments, presets
- `pauseOnFullscreen`, `pauseOnBattery` — behavioural switches
- `dragToApplyEnabled` — drop a wallpaper on a display to apply it (on by default)
- `paneSidebarWidth`, `paneDetailWidth` — pane widths
- `showGridFileNames`, `librarySortKey`, `librarySortAscending` — grid display and sorting
- `sidebarGroupOrder` — sidebar group order
- `wallpaperFolder` — the wallpaper folder path

Launch at login uses a `LaunchAgent`: `~/Library/LaunchAgents/app.walllocus.autostart.plist`.

## Troubleshooting

**Video shows black.** Almost certainly HEV1 packaging — macOS only decodes `hvc1`. The app detects this and offers a one-click fix.

**Wallpapers are gone after quitting.** Expected; see Architecture.

**The Dock icon disappeared.** It hides when the window closes; the menu bar icon remains.

**A file added in Finder does not appear.** Switch back to the app or change category — it refreshes automatically — or right-click empty space in the grid and choose **Refresh now**.

**Does dropping a file move my original?** No — it copies into the wallpaper folder.

## Licence

[MIT](LICENSE).

## Credits

Built and iterated with [DeepSeek Harness](https://github.com/deepseek-ai/dsh).
