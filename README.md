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

Global scroll monitoring needs the **Input Monitoring** permission:

1. Open **System Settings → Privacy & Security → Input Monitoring**
2. Enable **VolumeWheel** (add it with **+** if it isn't listed)
3. Launch the app. When the mouse is over the Dock area, scroll to adjust volume.

> Note: directly running `.../VolumeWheel.app/Contents/MacOS/VolumeWheel` (or a login LaunchAgent) is the most reliable way to launch, since double-clicking a locally-built app can occasionally cause event monitoring to stop working.

### Auto-start on login (optional)

```bash
cat > ~/Library/LaunchAgents/com.local.volumewheel.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.local.volumewheel</string>
  <key>ProgramArguments</key><array><string>/Applications/VolumeWheel.app/Contents/MacOS/VolumeWheel</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
launchctl load ~/Library/LaunchAgents/com.local.volumewheel.plist
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
