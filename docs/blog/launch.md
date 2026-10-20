# Reviving the Gear VR Controller as a couch remote for the Mac

Samsung's Gear VR Controller (ET-YO324) was discontinued years ago. Mine was in a drawer. It still has a lot going for it: a gyroscope and accelerometer, a round clickable touchpad, a trigger, Home, Back and volume buttons, and two AAA batteries. What it didn't have was anything left to talk to.

This is the story of how I got it talking to my Mac. The result is two things: [PROTOCOL.md](/PROTOCOL.md), a full write-up of the controller's Bluetooth LE protocol verified on real hardware, and **GearVR Remote**, a native Swift menu-bar app that turns the controller into a gyro air-mouse, a trackpad and a media remote. It costs nothing if you already have the controller, and it lets me drive a Mac from the couch.

![The GearVR Remote menu](/docs/screenshots/menu.png)

## Reverse-engineering the protocol

I wasn't starting from zero. [jsyang](https://github.com/jsyang/gearvr-controller-webbluetooth), [gb2111](https://github.com/gb2111/Access-GearVR-Controller-from-PC) and [polygraphene](https://github.com/polygraphene/FreePIEVRController) had already published most of the packet layout, and polygraphene's FreePIE plugin gets the most right. The controller exposes a service with the charming UUID `4f63756c-7573-2054-6872-65656d6f7465`, which is ASCII for "Oculus Three Remote". One characteristic streams data, another takes two-byte commands.

The first thing that didn't add up was the data rate. Sending `0100` (start sensors) on its own gave me about 30 packets a second, with gaps. The known trick is to send `0800` (VR mode) first, but on my unit, sending `0800` and `0100` back to back would stream fast for about 1.5 seconds and then stop dead.

Logging every notification explained it. Once the controller has applied a command, it sends a two-byte notification echoing the command back. For `0800` that acknowledgement takes about 1.5 seconds, which is probably a connection-parameter update to a faster interval. So the order matters:

* `0800`, wait for the `08 00` ack, then `0100`: a steady 68 packets/s with no drops, indefinitely.
* `0800` then `0100` straight away: fast for about 1.5 s, then the controller echoes `01 00` and stops.
* `0100` then `0800`: streaming stops immediately.

That handshake is the single most useful thing in the protocol doc. Everything else in the app depends on it.

The second finding was that each 60-byte packet carries three IMU samples, not one. Each sample has a microsecond timestamp, three accelerometer axes and three gyro axes, which works out to about 206 Hz of motion data at 68 packets/s. polygraphene's plugin already processes all three. jsyang's code reads only the first and treats bytes 32 to 37 as the magnetometer, but those are actually sample 3's timestamp and accelerometer; the magnetometer is at bytes 48 to 53. I also pinned down the scales and axes, and found that the last byte, which polygraphene lists as unknown, is the battery percentage.

The third was a channel nobody seemed to have mentioned. The controller also has a HID-over-GATT service under a non-standard UUID (`1879`). When the data stream isn't running, it can send consumer-control reports on it: `EA 00` (Volume Decrement) on press and `00 00` on release. I only ever captured volume-down this way, and the report map also declares a keyboard and a vendor report that I never saw in use, so this one is documented as found rather than fully understood.

Later probing filled in the rest of the command table, including a device record with the controller's real serial number and a low power mode (`0600`) that switches the sensors off while staying connected. It also showed what isn't there: no vibration motor, no microphone or speaker.

One warning: don't hold Home. A long press puts the controller into pairing mode and wipes its bond, and macOS then refuses to connect until you use *Forget This Device* in Bluetooth settings.

## From packets to a pointer

The first version was `remote.py`, a Python script driven by `config.toml`. The Mac app came after it and kept the same defaults. Point and turn the controller to move the cursor. The trigger is left click (hold to drag), a touchpad click is right click, and sliding on the touchpad scrolls while the air-mouse is on, or works as a trackpad while it's off. Home toggles the air-mouse, Back is Escape, and the volume buttons control system volume.

The app is written in Swift with SwiftUI, CoreBluetooth and Quartz events, has no dependencies, and needs macOS 14 or later. Its core is tested against packets recorded from a real controller.

Getting a cursor to move was the easy part. Making it pleasant took most of the commits.

## The design problems

**Hand tremor.** A gyro air-mouse amplifies every small shake in your arm, and a window's close button is a small target. I attacked this from two sides. The first is adaptive smoothing, in the style of a 1-euro filter: the cutoff rises with speed, so slow, careful aiming is steadied and fast moves come through without lag. It's 30% by default, and 0% turns it off.

The second is magnetic buttons. The app uses the Accessibility API to find clickable things near the pointer: buttons, links, checkboxes, menu items, tabs, list rows and Dock icons, including on web pages in Safari and Chrome. My first version snapped the pointer onto the centre of a button and held it there. It worked, but it felt like being puppeted, and close-together targets like the window traffic lights became hard to hit. So the default became a subtle assist that never moves the pointer on its own. Your motion is damped over a button, most when you're nearly still, which cancels tremor, and bends slightly toward a button you're heading for. Push the strength slider past the middle and the old snap behaviour comes back, now with a small push hopping to the next target. It only applies to controller-driven motion, so a real trackpad or mouse behaves normally.

![Pointer settings](/docs/screenshots/settings-pointer.png)

**Re-gripping.** With an air-mouse, your hand eventually ends up somewhere uncomfortable while the cursor is exactly where you want it. A physical mouse solves this by lifting it off the desk. The controller equivalent is the clutch: hold the trigger, touch the bottom of the touchpad (you hear a *tink*), let go of the pad, and move your hand while the cursor stays put. Release the trigger (*pop*) to resume.

**Clicks that don't jiggle.** The clutch starts with holding the trigger, which would normally be a click. To make it possible without stray clicks, the trigger press is deferred: a tap clicks on release, and a drag only starts once the pointer has moved past a few pixels. That threshold also made ordinary clicks steadier, since a little wobble while pressing no longer counts as movement.

**Battery life.** This one I found the hard way. The app's keep-alives stopped the controller from ever falling asleep, so two AAAs drained in a day of streaming at 68 packets/s. Now the app sleeps the controller for you: sensors off and disconnected, after a few idle minutes (five by default, set in Settings → Pointer), and immediately when the Mac sleeps or locks. Press Home and the app reconnects on its own. Pausing with "Control this Mac" uses the low power mode instead, which keeps the connection. And the fast 68 packets/s stream is only used when the air-mouse is on. Buttons and scrolling don't need it, so they get the slower, lighter mode at about 30 packets/s.

## Training mode

Pointer speed, smoothing and magnet strength interact, and the right values depend on how steady your hands are. Rather than guess, I added a training mode. It's a one-minute aiming exercise: you click 15 targets that shrink down to the size of a window's close button. It measures your hand tremor from the gyro, how directly you reach each target, and how often you hit small targets on the first click. Then it suggests settings for pointer speed, smoothing and magnet strength, and you can apply them with one click.

![Training results](/docs/screenshots/training-results.png)

There's also a *Calibrate…* button for the gyro's zero point. Put the controller down, press Start and leave it still for two seconds. If it moves during the measurement, it says so and keeps the old calibration.

## The 3D viewer

While decoding the protocol I wanted to see what the controller thought it was doing, so I built a three.js viewer with a to-scale 3D model that mirrors the real controller live, plus a byte-by-byte packet decoder. In Chrome it connects straight to the controller over Web Bluetooth with no install. In other browsers, a small Python bridge connects and serves it on localhost. Without a controller, it runs a demo.

![3D viewer](/docs/viewer.png)

## Getting it

* **Download:** grab `GearVR-Remote-x.y.z.dmg` from the [latest GitHub release](https://github.com/dennisonbertram/gearvr-controller/releases/latest), open it and drag the app to Applications. It's a universal build for Apple silicon and Intel. On first launch a Welcome window walks you through allowing Bluetooth and Accessibility, then you press Home on the controller.
* **Try the viewer:** the interactive demo is at <https://dennisonbertram.github.io/gearvr-controller/>.
* **Build from source:** `cd mac && ./build.sh install`. The Command Line Tools are enough; you don't need Xcode. Run `tools/make_signing_identity.sh` once first, so the Accessibility permission survives rebuilds.

The Python version, the capture and analysis tools, and the recorded packets behind PROTOCOL.md are all in the [repository](https://github.com/dennisonbertram/gearvr-controller).

## Limitations

The app isn't notarized. The first time you open it, macOS will say it can't verify the developer, and you'll need to go to System Settings → Privacy & Security and click **Open Anyway**. After an update you may need to switch Accessibility off and on again for the new build.

It isn't in the Mac App Store either, and that's unlikely to change. App Store apps have to run in the App Sandbox, and this app's whole job is things the sandbox is designed to prevent: it posts synthesized mouse and keyboard events with Quartz `CGEvent`s, and it reads other apps' interfaces through the Accessibility API to find magnetic-button targets.

There are smaller ones too. The app can share the controller with `remote.py` or the viewer's bridge, but run only one thing that moves the mouse, or the cursor gets double input. The magnetometer's scale and axis alignment aren't worked out yet. And on Macs with a notch, a full menu bar can hide the app's icon; it detects that and tells you, and you can turn on **Always show in the Dock** instead.

## Credits

None of this would have gone as quickly without the earlier reverse-engineering by [jsyang](https://github.com/jsyang/gearvr-controller-webbluetooth), [gb2111](https://github.com/gb2111/Access-GearVR-Controller-from-PC) and [polygraphene](https://github.com/polygraphene/FreePIEVRController). PROTOCOL.md marks which findings are new, as far as I could tell, and where their versions differ from what I measured on my unit.
