# VolumeWheel

A lightweight, native macOS menu-bar utility that lets you control **system volume with your scroll wheel**.

Hover the mouse over the **bottom edge of the screen (the Dock area)** and scroll up/down to raise/lower the global volume. No keyboard shortcuts, no fiddly sliders — just scroll where the Dock is.

> VolumeWheel is an **independent, original implementation**. It is not affiliated with, nor a copy of, Volume2 or any other product. It shares only the generic idea of "scroll-to-adjust-volume".

---

## Features

- 🎚️ **Scroll to control global volume** — scroll over the Dock area to change volume, scroll events there are consumed (won't trigger page scrolling)
- 🔊 **Choose the output device** to control, or **follow the system default**
- 📊 **On-screen volume bar (OSD)** feedback at the bottom of the screen
- 🧩 **Menu-bar icon** — enable/disable, pick device, adjust activation zone
- 📏 **Configurable activation zone** — 40 / 70 / 120 / 200 pt, or anywhere (global)
- 🌍 **Localized** — English and Simplified Chinese built in; easy to add more languages
- 🕹️ **100% native Swift** — Cocoa + CoreAudio + ApplicationServices, no dependencies

## Requirements

- macOS 13.0 or later
- Apple Silicon or Intel

## Installation (build from source)

Requires Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone <repo-url> VolumeWheel
cd VolumeWheel
./build.sh          # or: bash build.sh
# Output: build/VolumeWheel.app
```

Copy `build/VolumeWheel.app` to your `/Applications` folder.

## First-run setup (macOS requires this)

VolumeWheel uses two independent permissions, and deliberately degrades gracefully instead of
refusing to work:

| Permission | Needed for | If missing |
|---|---|---|
| **Input Monitoring** | Observing the scroll wheel at all | The app cannot do anything; it keeps retrying until you grant it |
| **Accessibility** | *Swallowing* the scroll event in the Dock area | The app still works — volume changes normally — but the scroll also reaches the window underneath |

On first launch the app asks for both itself (standard macOS prompts). To grant them manually:

1. **System Settings → Privacy & Security → Input Monitoring** → enable **VolumeWheel**
2. **System Settings → Privacy & Security → Accessibility** → enable **VolumeWheel**
   (add it with **+** if it isn't listed)

Both take effect immediately — no relaunch needed. The menu bar item shows the live state, e.g.
`Input Monitoring ✓   Accessibility ✗   ·   listen only (no swallowing)`, and offers a shortcut to the
Accessibility pane while it is missing.

> Note: how you launch the app matters. Launch it the normal way (Finder / Dock / Login Item) so that
> macOS attributes the permission to the app itself. Launching the raw binary from a terminal, or from
> a sandboxed/agent parent process, makes the TCC check fail even though the switches in System
> Settings are on.

### Auto-start on login

Use the standard **System Settings → General → Login Items → Open at Login** entry. That is enough:
the app recovers by itself if macOS has not finished bringing up the per-user privacy service
(`tccd`) in the first seconds after login. On such an early launch `CGEventTapCreate` fails, and the
app keeps retrying (5 s, then 15 s, forever) and also re-arms the tap whenever the session becomes
active, the screen is unlocked, or the Mac wakes from sleep.

Do **not** use a `LaunchAgent` with a fixed `sleep N` workaround: the delay needed varies per boot
(it was over 10 minutes on the machine this was debugged on), and running the binary directly bypasses
LaunchServices so the permission can be attributed to the wrong process. If you do install a
LaunchAgent, remove the Login Item first — otherwise two copies start and every scroll notch changes
the volume twice.

The app also re-enables its event tap when macOS disables it (`kCGEventTapDisabledByTimeout` /
`kCGEventTapDisabledByUserInput`), which is what used to make it silently stop working after sleep,
wake, or heavy system load.

### A note on signing and re-granting

TCC records permissions against the **code identity** of the binary, and that identity is derived from
how the app is signed:

| Signing | Designated Requirement | Survives a rebuild? |
|---|---|---|
| **ad-hoc** (`codesign -s -`, what the old `build.sh` did) | `cdhash H"…"` | ❌ No — every build is a new identity, so every rebuild asks for the permission again |
| **Apple Development** (what `build.sh` uses now) | `identifier "…" and certificate leaf[subject.CN] = "Apple Development: …"` | ✅ Yes — same certificate ⇒ same requirement |
| **Developer ID + notarized** (`release.sh`) | `identifier "…" and anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>"` | ✅ Yes — and it is also what lets other people run the app |

So the “re-authorize after every rebuild” problem was caused by **ad-hoc signing**, not by using a
development certificate. If you only build for yourself, `./build.sh` is enough. To clear stale records
for this bundle id (e.g. left behind by old ad-hoc builds):

```bash
tccutil reset All com.local.volumewheel
```

### Releasing to other people: Developer ID + notarization

```bash
./release.sh --setup-credentials   # once: stores an app-specific password in the keychain
./release.sh                       # build → sign → notarize → staple → verify
./release.sh --sign-only           # sign and self-check only
```

`release.sh` requires a **paid Apple Developer Program membership** (US$99/year) to issue a
`Developer ID Application` certificate; it prints step-by-step instructions and exits cleanly when the
certificate is missing. It signs with hardened runtime + a secure timestamp, submits the app to Apple's
notary service with `notarytool`, staples the ticket, and finally checks it with `spctl`.

Per-scroll logging is off by default. To turn it on for debugging:

```bash
defaults write com.local.volumewheel vwVerboseLog -bool true   # log: /tmp/vw_log.txt
```

## Usage

- Scroll up over the Dock area → volume up; scroll down → volume down
- Click the menu-bar speaker icon to: enable/disable, choose output device, change the activation zone, show current volume, or quit

## Localization

Interface strings use `NSLocalizedString` and live in `Sources/en.lproj` and `Sources/zh-Hans.lproj`.

To add a language, copy `Sources/en.lproj/Localizable.strings` to `<locale>.lproj/`, translate the values, and add the locale to `CFBundleLocalizations` in `Sources/Info.plist`.

## Project layout

```
VolumeWheel/
├── Sources/
│   ├── main.swift                 # All source (single file)
│   ├── Info.plist
│   ├── en.lproj/Localizable.strings
│   └── zh-Hans.lproj/Localizable.strings
├── build.sh                       # One-command build
├── LICENSE                        # MIT
└── README.md
```

## License

[MIT](LICENSE)
