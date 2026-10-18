# WallLocus

> **Remember every wallpaper's placement on every display.**

A tiny, hackable macOS video & image wallpaper app. `Wall` + `Locus` — it remembers the *locus* (position) of every wallpaper.

[简体中文](README.zh-CN.md) · English

---

A self-contained macOS wallpaper app in about 1,700 lines of Swift. No third-party dependencies, no analytics, no account. Built with `swiftc` alone — you do not need a full Xcode installation.

## What makes it different

**Per-display × per-wallpaper memory.**

Every wallpaper keeps its own scale mode, zoom and horizontal/vertical offset **on each display**, independently:

| Display             | Wallpaper A         | Wallpaper B        |
| ------------------- | ------------------- | ------------------ |
| 4K external display | 150% · offset −0.20 | 100% · centered    |
| Laptop display      | 100% · centered     | 73% · offset +0.15 |
| Vertical display    | 100% · offset −0.55 | 100% · centered    |

Switch displays or wallpapers and the previous framing comes back exactly. Most wallpaper apps offer at best a global fill/fit setting; this one treats framing as a property of the *pair*.

## Features

- **Video and still images**, from your own files
- **Independent wallpaper per display**, hot-plug aware
- **Scale modes**: Fill (crop), Fit (letterbox), Stretch
- **Zoom** 30–300% and **horizontal / vertical offset** ±100%, with editable numeric fields (two decimals) alongside each slider
- **Auto-pause on full screen** — detects when a display is fully covered by a full-screen app (≥96% coverage) and suspends that display only
- **Auto-pause on battery** (optional)
- **Menu bar resident** — closing the window releases the Dock icon, the menu bar icon stays
- **Locked-in low footprint**: AVPlayerLayer hardware decoding for video, ImageIO downsampling for stills
- **Compatibility check** for video: flags files macOS cannot decode and can fix HEV1 → HVC1 tags in place (no re-encode)
- **Bilingual UI** — English and Simplified Chinese, chosen automatically from your system language

## Measured footprint

On Apple silicon running macOS 26, three displays — two still images, one 4K video:

| Metric                               | Value           |
| ------------------------------------ | --------------- |
| Physical memory (`footprint`)        | **~96 MB**      |
| CPU, still-image displays            | **0.0 %**       |
| CPU, 4K video display                | **1.6 – 3.4 %** |
| CPU, while a full-screen app is open | **0.0 %**       |

> Note: `ps` RSS reads much higher (~190 MB) because it counts mapped shared system libraries. Use `footprint -p <pid>` or `vmmap --summary` for real usage.

## Requirements

- macOS **13.0** or later
- Apple silicon or Intel (build a universal binary with `UNIVERSAL=1`)
- Xcode **Command Line Tools** only (no full Xcode, no Homebrew)

## Build

```bash
git clone https://github.com/ZEBRALD/walllocus.git
cd walllocus
./build.sh                 # host architecture
UNIVERSAL=1 ./build.sh     # universal binary (arm64 + x86_64)
```

The app lands in `build/WallLocus.app`.

## Install

```bash
cp -R build/WallLocus.app /Applications/
xattr -dr com.apple.quarantine /Applications/WallLocus.app
open /Applications/WallLocus.app
```

Because this build is **ad-hoc signed and not notarized**, Gatekeeper will block the first launch. Either right-click the app and choose **Open**, or run the `xattr` command above.

## Usage

1. Click **Add files…** and pick videos and/or images.
2. Choose a target under **Target display** — one screen, or all of them at once.
3. Pick a wallpaper in the library, then press **Set as wallpaper for this display**.
4. Adjust **scale mode / zoom / horizontal / vertical** with the sliders or by typing exact values. Changes apply live and are remembered per display × wallpaper.

Everything is also reachable from the menu bar icon and from the app menu (Playback / Displays / Scale mode / Settings).

## Notes on architecture

The wallpaper is an `NSWindow` at the desktop window level hosting an `AVPlayerLayer` (video) or a `CALayer` (image). That keeps the implementation small and dependency-free, but it has two deliberate limits:

- **The wallpaper disappears when the app quits** — it is the app window, not a system wallpaper.
- **No lock-screen wallpaper** — the lock screen is drawn by a system process that third-party windows cannot enter.

Reaching those would require the private `WallpaperExtensionKit` framework, which is out of scope for a small utility.

### What about a screen saver?

A `.saver` bundle **does not work on macOS 26**: the system no longer scans
`~/Library/Screen Savers/` and only lists ExtensionKit `.appex` extensions for
`com.apple.screensaver`. Even Apple's own bundled `.saver` files are no longer
registered. See [SCREENSAVER.md](SCREENSAVER.md) for the full evidence and the
renderer code we kept for a future extension-based attempt.

## Configuration

State lives in `UserDefaults` under bundle id `app.walllocus`:

- `walllocus.state.v1` — library, per-display assignment, per-display × per-wallpaper adjustments
- `pauseOnFullscreen`, `pauseOnBattery` — behaviour toggles

Launch-at-login uses a `LaunchAgent` at `~/Library/LaunchAgents/app.walllocus.autostart.plist` (no authorization prompt, no Apple Developer account needed).

## Troubleshooting

**A video shows a black screen.** It is almost certainly HEV1 packaging. macOS only decodes `hvc1`. The app detects this and offers a one-click fix that rewrites the four tag bytes in place (original kept as `*.hev1bak.mp4`).

**Wallpaper vanished after quitting.** Expected — see *Notes on architecture*.

**Dock icon is gone.** Closing the window intentionally hides it; the menu bar icon remains. Click it and choose *Open WallLocus*.

## License

[MIT](LICENSE).

## Acknowledgements

Built and iterated with [DeepSeek Harness](https://github.com/deepseek-ai/dsh).
