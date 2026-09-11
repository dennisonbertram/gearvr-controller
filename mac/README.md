# GearVR Remote for macOS

A native menu-bar app that turns a Samsung Gear VR Controller (ET-YO324) into a
gyro air-mouse, trackpad, and media remote. It's written in Swift
(SwiftUI + CoreBluetooth + Quartz events) with no dependencies, and needs macOS 14 or later.

## Install

**Download:** grab `GearVR-Remote-x.y.z.dmg` from the
[latest release](https://github.com/dennisonbertram/gearvr-controller/releases/latest),
open it, and drag the app to Applications. The app isn't notarized, so the first
time you open it macOS will say it can't verify the developer. Go to System
Settings → Privacy & Security and click **Open Anyway**.

**Or build it:**

```sh
cd mac
./build.sh install        # builds a universal app and copies it to /Applications
```

The Command Line Tools are enough; you don't need Xcode. On first launch the app
opens a Welcome window with a live setup checklist:

1. **Allow Bluetooth** when macOS asks.
2. **Allow Accessibility:** System Settings → Privacy & Security → Accessibility →
   turn on *GearVR Remote*. Without it, macOS ignores the pointer and clicks.
   The menu shows a warning until this is granted.
3. Press **Home** on the controller to wake it. The menu-bar glyph fills in
   once it's connected. Set the controller down for a second so the gyro can calibrate.

It's a menu-bar app, so there's no Dock icon. To bring back the Welcome and
Settings window, open *GearVR Remote* again from Spotlight, Launchpad, or
Applications while it's running. Turn on **Start when you log in** to have it
start automatically; it then appears under System Settings → General → Login Items.

macOS ties these permissions to the app's code signature. An ad-hoc signed app
gets a new signature every build, so after rebuilding, the Accessibility switch
can look *on* while the permission is silently gone: the buttons still light up
in the menu, but the pointer doesn't move. To avoid that when building yourself,
run `tools/make_signing_identity.sh` once. It creates a local self-signed
identity that `build.sh` then uses automatically. On the first build afterwards,
click **Always Allow** in the keychain prompt. If you're already stuck, run
`tccutil reset Accessibility com.dennisonbertram.gearvr-remote`, relaunch, and
allow Accessibility again.

## Using it

The defaults match `../config.toml`:

| Control | Action |
|---|---|
| Point and turn | move the cursor (gyro air-mouse) |
| Trigger | left click (tap) / drag (hold and move) |
| Touchpad slide | scroll (air-mouse on) or trackpad cursor (air-mouse off) |
| Touchpad click | right click |
| Home | air-mouse on/off |
| Back | Escape |
| Volume ± | system volume |
| Trigger + touch bottom of pad | **clutch:** freeze the cursor while you re-home your hand, release the trigger to resume |

The menu has quick switches for pausing control, the air-mouse, and the clutch,
plus pointer speed, touchpad mode, and a live view of the buttons and touchpad.
**Settings…** lets you remap every button and swipe (clicks, key combos like
`cmd+[`, media keys, or shell commands) and tune the pointer, touchpad, and clutch.
You can also turn on launch at login there.

> Don't hold **Home** for several seconds. That puts the controller into pairing
> mode and wipes its bond with the Mac. If it happens, use *Forget This Device*
> in Bluetooth settings and connect again.

## Building and testing

| Command | What it does |
|---|---|
| `./build.sh` | build `build/GearVR Remote.app` |
| `./build.sh run` | build and launch |
| `./build.sh dist` | build and package a drag-to-install DMG |
| `./build.sh test` | run the core tests against packets recorded from a real controller |
| `build/GearVR Remote.app/Contents/MacOS/GearVRRemote --dry-run --verbose` | connect and decode, but log actions instead of moving the mouse |

Layout:

* `Sources/Core`: protocol parser, config, and the input mapper (platform-free, fully tested)
* `Sources/App`: CoreBluetooth link, Quartz event output, and the SwiftUI menu/settings UI
* `Tests/main.swift`: headless test runner (no XCTest needed)
* `tools/make_icon.swift`: draws the app icon

The app can share the controller with other local clients such as `remote.py`
or `bridge.py`, because macOS multiplexes one Bluetooth link. Run only one thing
that moves the mouse, though, or the cursor gets double input.
