# WallLocus

> **Remember every wallpaper's placement on every display.**

A small, hackable macOS video and image wallpaper tool.  
`Wall` + `Locus` — it remembers each wallpaper's **positional footprint** on every display.

English · [简体中文](README.zh-CN.md)

---

A self-contained macOS wallpaper app in about 7,300 lines of Swift. No third-party dependencies, no telemetry, no account. Built with nothing but `swiftc` — **no full Xcode install required**.

## What makes it different

**Two-dimensional memory: display × wallpaper.**

Every wallpaper remembers its own scale mode, zoom, and horizontal/vertical offset **per display**:

| Display          | Wallpaper A        | Wallpaper B      |
| ---------------- | ------------------ | ---------------- |
| 4K external      | 150% · offset −0.20 | 100% · centred   |
| Built-in laptop  | 100% · centred      | 73% · offset +0.15 |
| Portrait monitor | 100% · offset −0.55 | 100% · centred   |

Swap displays or wallpapers and the previous framing comes back exactly. Most wallpaper apps offer at most one global fill/fit switch; here the framing is a property of **the pairing**.

## Interface

Three panes, modelled on the macOS Photos app:

- **Sidebar** — displays, library categories, presets. The three groups default to Displays → Library → Presets, reorderable in settings
- **Grid** — the library. Thumbnails tile the space, five columns, corners clipped to each image's own aspect ratio
- **Details** — file information, framing controls, and actions for the selected item

Both side panes resize by dragging their edges, and the widths persist. All three panes share one liquid-glass base whose rim tints with the wallpaper's colour temperature.

## Features

- **Video and still images**, using your own files
- **Per-display wallpapers**, with hot-plug support
- **Scale modes**: fill (crop), fit (letterbox), stretch
- **Zoom** 30–300%, **horizontal/vertical offset** ±100%, each with a type-in field beside the slider
- **Auto-pause on fullscreen**: detects when a display is fully covered (≥96%) and pauses only that one
- **Pause on battery** (optional)
- **Menu bar resident**: the Dock icon hides when the window closes, the menu bar icon stays
- **Very low overhead**: video runs through AVPlayerLayer's hardware decoding, images through ImageIO downsampling; bitmaps for displays not in use are released immediately
- **Video compatibility check**: warns about videos macOS cannot decode, with a one-click fix that retags HEV1 as HVC1 (no re-encoding)
- **The library is a folder**: `~/Pictures/WallLocus` by default, with each subfolder becoming a category
- **Drag in from Finder**: drop images or videos anywhere on the window. The interface blurs and dims behind the drop hint so both the hint and the target stay legible
- **Toolbar + button** to add wallpapers; a search field filters by file name
- **Sorting**: by file name or modification date, ascending or descending
- **Optional file names**: captions in the grid can be turned off, in which case each thumbnail fills its card
- **Context menus**: on a card — set as this display's wallpaper, reveal in Finder, move to Trash; on empty space — refresh the library, add files, reveal the folder
- **Presets**: capture which wallpaper each display uses along with its framing; right-click to apply, rename, or delete
- **Bilingual UI**, following the system language

## Measured overhead

Apple silicon, macOS 26, three displays each showing a 2160×2880 still image:

| Metric                     | Value            |
| -------------------------- | ---------------- |
| Physical footprint         | **~197 MB**      |
| CPU (image displays)       | **0.0 %**        |
| CPU (4K video display)     | **1.6 – 3.4 %**  |
| CPU (fullscreen app open)  | **0.0 %**        |
| Library of 60 items        | **+1.6 MB**      |

Memory is dominated by decoded bitmaps, so it scales with how many displays are driven and how large the sources are — roughly 24 MB per display for a 2160×2880 source, one copy each, released as soon as no display needs it.

The library adds very little: thumbnails decode at **their real display size × the screen scale** (about 480px on a Retina screen), only for visible cards, into a 48 MB cache. **Adding files to the library triggers no decoding at all.**

CPU is what genuinely sits at zero.

> Note: `ps` reports a much higher RSS (~190 MB) because it counts mapped pages from shared system libraries. Use `footprint -p <pid>` or `vmmap --summary` for the real figure.

## Requirements

- macOS **13.0** or later
- Apple silicon or Intel (build a universal binary with `UNIVERSAL=1`)
- Only **Xcode Command Line Tools** — no full Xcode, no Homebrew

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

Builds are **ad-hoc signed and not notarised**, so Gatekeeper blocks the first launch. Right-click the app and choose **Open**, or run the `xattr` command above.

## Usage

1. Add wallpapers either with the **+** button in the toolbar, or by dragging images and videos **onto the window**. Adding files triggers no decoding — only items you actually set as a wallpaper get decoded.
2. Pick a display in the **sidebar**, or choose "All displays".
3. Select a wallpaper in the grid and click **Set as this display's wallpaper** in the details pane. Items already assigned carry a green dot.
4. Adjust **scale mode / zoom / horizontal / vertical** with the sliders or by typing a value. Changes apply live and are remembered per display × wallpaper.

While dragging over the window, the background blurs and dims, a dashed border appears, and the count of items to be added is shown; unsupported types are called out rather than silently ignored.

Rename in **Finder** — the app deliberately offers no second naming path, so what you see is the file name itself.

The box at the bottom of the sidebar shows the selected display's resolution and the wallpaper currently in use. Right-click empty space in the grid to **refresh** the library, which is how files restored from the Trash show up.

The menu bar icon and the app menu (Playback / Scale mode / Settings) cover most operations too.

## Architecture

A wallpaper is an `NSWindow` at the desktop window level carrying either an `AVPlayerLayer` (video) or a `CALayer` (image). That keeps the implementation small and dependency-free, at the cost of two deliberate limitations:

- **Wallpapers vanish when the app quits** — they are the app's own windows, not system wallpapers.
- **Lock screen wallpapers are not supported** — the lock screen is drawn by a system process that third-party windows cannot enter.

Both would need the private `WallpaperExtensionKit` framework, which is beyond the scope of a small tool.

### A note on screen savers

`.saver` bundles are **unusable on macOS 26**: the system no longer scans `~/Library/Screen Savers/`,
and the Screen Saver pane only lists ExtensionKit `.appex` extensions (`com.apple.screensaver`).
Even Apple's own bundled `.saver` files no longer register. The full evidence is in [SCREENSAVER.md](SCREENSAVER.md),
which also keeps the rendering code written for a future extension.

## Configuration

State lives in `UserDefaults` under the bundle id `app.walllocus`:

- `walllocus.state.v1` — library, per-display assignments, per-display × per-wallpaper adjustments, presets
- `pauseOnFullscreen`, `pauseOnBattery` — behavioural switches
- `paneSidebarWidth`, `paneDetailWidth` — pane widths
- `showGridFileNames`, `librarySortKey`, `librarySortAscending` — grid display and sorting
- `sidebarGroupOrder` — sidebar group order
- `wallpaperFolder` — the wallpaper folder path

Launch at login uses a `LaunchAgent`: `~/Library/LaunchAgents/app.walllocus.autostart.plist` (no authorisation prompt, no Apple developer account needed).

## Troubleshooting

**Video shows black.** Almost certainly HEV1 packaging — macOS only decodes `hvc1`. The app detects this and offers a one-click fix that rewrites those four bytes in place, keeping the original as `*.hev1bak.mp4`.

**Wallpapers are gone after quitting.** Expected; see Architecture.

**The Dock icon disappeared.** It hides when the window closes; the menu bar icon remains. Click it and choose "Open WallLocus".

**A file added in Finder does not appear.** Right-click empty space in the grid and choose **Refresh now**, or relaunch the app.

## Licence

[MIT](LICENSE).

## Credits

Built and iterated with [DeepSeek Harness](https://github.com/deepseek-ai/dsh).
