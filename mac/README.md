# GearVR Remote for macOS

A native menu-bar app that turns a Samsung Gear VR Controller (ET-YO324) into a
gyro air-mouse, trackpad, and media remote. It's written in Swift
(SwiftUI + CoreBluetooth + Quartz events) with no dependencies, and needs macOS 14 or later.

## Install

**Download:** grab `GearVR-Remote-x.y.z.dmg` from the
[latest release](https://github.com/dennisonbertram/gearvr-controller/releases/latest),
open it, and drag the app to Applications, then open it from there (not from
the disk image). If macOS says it can't verify the developer, the build isn't
notarized yet: go to System Settings → Privacy & Security and click **Open Anyway**.

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

It installs to **/Applications**, so Spotlight, Launchpad and Finder all find it —
search for "GearVR". It's a menu-bar app: normally there's no Dock icon, just the
controller glyph at the top right. A Dock icon appears whenever one of its windows
is open, and opening *GearVR Remote* again while it's running brings the Welcome
and Settings window back. If you'd rather keep it in the Dock permanently, turn on
**Always show in the Dock** in Settings → General; you can then drag it to your
Dock and launch it like any other app. **Start when you log in** is in the same place,
and adds it to System Settings → General → Login Items. If the switch turns itself
back off, macOS wants you to approve it: switch GearVR Remote on in Login Items.

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

The default button mapping matches `../config.toml` (the Python remote). The app
keeps its own settings, so its default pointer speed is 18 px/degree rather than
config.toml's 22, and smoothing, the magnet, and battery care exist only here.

| Control | Action |
|---|---|
| Point and turn | move the cursor (gyro air-mouse) |
| Trigger | left click (tap) / drag (hold and move) |
| Touchpad slide | scroll (air-mouse on) or trackpad cursor (air-mouse off) |
| Touchpad click | right click |
| Home | air-mouse on/off |
| Back | Escape |
| Volume ± | system volume — hold to keep changing it |
| Touchpad in Volume mode | slide up and down for smooth system volume |
| Double-click the trigger, hold the second click | **recenter:** the pointer jumps to the middle of the main screen (turn it off in Settings → Pointer) |
| Trigger + touch bottom of pad | **clutch:** freeze the cursor while you re-home your hand, release the trigger to resume |
| Near a button | **magnetic buttons:** buttons are slightly sticky, so arm wobble doesn't knock the pointer off them |

**Magnetic buttons** use the Accessibility API to find clickable things near the
pointer: buttons, links, checkboxes, menu items, tabs, list rows, and Dock icons,
including on web pages in Safari and Chrome. By default the effect is subtle
and the pointer never moves on its own. Your motion is damped over a button
(most when you're nearly still, which cancels tremor) and bends slightly toward
a button you're heading for. Drag the strength slider in the menu past the
middle and it becomes a true magnet: the pointer snaps onto the nearest button
and holds, a small push hops to the next one (handy for the window traffic
lights or menus), and a push into empty space pulls free. It only acts on
controller-driven movement, so your trackpad and mouse behave normally.

**Battery care.** The controller runs on two AAA batteries and stays awake as long
as an app streams from it. So after a few idle minutes (Settings → Pointer, five by
default), and as soon as your Mac sleeps or locks, GearVR Remote switches its sensors
off and disconnects. The controller keeps advertising for about two and a half minutes
and then sleeps, so the app waits before listening for Home again (reconnecting any
sooner would wake it straight back up). Press **Home**, or **Wake** in the menu, to
bring it back; the app reconnects on its own. Pausing
with "Control this Mac" switches the sensors off but keeps the connection, and the
fast 68 packets/s stream is only used when the air-mouse is on — buttons and
scrolling get the slower, lighter 30 packets/s mode. A slow red flash on the
controller means the batteries need replacing.

**If you can't see the menu bar icon:** on Macs with a notch, a full menu bar can
leave the icon in the gap behind it. The app notices and tells you. Hold ⌘ and drag
menu bar icons to rearrange them, or turn on **Always show in the Dock** in
Settings → General.

**Audio.** The volume buttons send the same media keys as a keyboard's volume
keys, so macOS shows its usual volume HUD; holding a button repeats it. For finer
control, set the touchpad to **Volume** mode (in the menu or Settings → Touchpad)
and slide your thumb up and down: that drives the output device's volume directly,
in smooth steps rather than sixteenths, with its own on-screen level indicator.
Any button can also be mapped to play/pause, next, previous, mute or brightness in
Settings → Buttons.

**Smoothing** (Settings → Pointer, 30% by default) evens out small wobbles. It
adapts to speed: slow, careful movements are steadied, and fast moves come through
without lag. Set it to 0% to turn it off.

**Recalibrate** (the *Calibrate…* button in the menu) re-measures the gyro's
zero point: put the controller down, press Start, and leave it still for two
seconds. Use it if the pointer creeps on its own while your hand is still. If the
controller moves during the measurement it says so and keeps the old calibration.

**Training** (the *Training…* button in the menu) is a one-minute aiming exercise.
You click 15 targets that shrink to the size of a window's close button. It
measures your hand tremor from the gyro, how directly you reach each target, and
how often you hit small targets on the first click. It then suggests pointer
speed, smoothing, and magnet strength, and you can apply them with one click.

The menu has quick switches for pausing control, the air-mouse, and the clutch,
plus pointer speed, touchpad mode, and a live view of the buttons and touchpad.
**Settings…** lets you remap every button and swipe (clicks, key combos like
`cmd+[`, media keys, or shell commands) and tune the pointer, touchpad, and clutch.
You can also turn on **Start when you log in** there.

> Don't hold **Home** for several seconds. That puts the controller into pairing
> mode and wipes its bond with the Mac. If it happens, use *Forget This Device*
> in Bluetooth settings and connect again.

## Building and testing

| Command | What it does |
|---|---|
| `./build.sh` | build `build.noindex/GearVR Remote.app` (a `.noindex` folder so Spotlight doesn't list the build next to the installed app) |
| `./build.sh run` | build and launch |
| `./build.sh dist` | build and package a drag-to-install DMG |
| `./build.sh test` | run the core tests against packets recorded from a real controller |
| `build.noindex/GearVR Remote.app/Contents/MacOS/GearVRRemote --dry-run --verbose` | connect and decode, but log actions instead of moving the mouse |

Layout:

* `Sources/Core`: protocol parser, config, input mapper, and magnet logic (platform-free, fully tested)
* `Sources/App`: CoreBluetooth link, Quartz event output, the Accessibility target
  scanner, and the SwiftUI menu/settings UI
* `Tests/main.swift`: headless test runner (no XCTest needed)
* `tools/make_icon.swift`: draws the app icon

The app can share the controller with other local clients such as `remote.py`
or `bridge.py`, because macOS multiplexes one Bluetooth link. Run only one thing
that moves the mouse, though, or the cursor gets double input.
