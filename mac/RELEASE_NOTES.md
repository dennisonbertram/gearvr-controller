## What's new in 1.8.0

* **Waking and sleeping:** pressing Home after the controller dozes off wakes it
  properly instead of putting it back to sleep a second later. Locking the screen
  now sleeps the controller, and a sleeping controller stays asleep.
* **Steadier pointer:** the gyro calibration is no longer thrown away every time
  the air-mouse turns on or the controller reconnects, the cursor no longer jumps
  after a click, a pause or a recalibration, and the magnet is calmer.
* **No more stuck keys:** keys, media keys and mouse buttons are released when the
  controller disconnects, Bluetooth turns off, or you pause control.
* **Menu fixes:** the menu's touchpad picker changes the mode you're actually
  using, pausing shows as paused (not disconnected), and turning Bluetooth off
  says so.
* **Volume:** touchpad Volume mode slides smoothly on every device, keeps your
  left/right balance, and tells you when an output (such as HDMI) has no volume
  control. The on-screen level no longer vanishes mid-slide.
* **Keyboard shortcuts** mapped to buttons now work on non-US keyboard layouts.
* **Training** suggestions are more sensible, and applying them no longer undoes
  settings you changed meanwhile.
* **Start when you log in** stays in sync with System Settings → Login Items and tells
  you when macOS needs your approval.
* Fixed a crash when no display was active.

**GearVR Remote** is a menu-bar app that turns a Samsung Gear VR Controller
(ET-YO324 / SM-R324) into a gyro air-mouse, trackpad, and media remote for
macOS 14 or later. It's a universal build for Apple silicon and Intel.

### Install

1. Download **GearVR-Remote-x.y.z.dmg** below, open it, and drag **GearVR Remote**
   into **Applications**.
2. Open it from Applications. If macOS says it can't verify the developer, this
   build isn't notarized: go to **System Settings → Privacy & Security**, scroll
   down, and click **Open Anyway**. (Or run
   `xattr -dr com.apple.quarantine "/Applications/GearVR Remote.app"`.)
3. Allow **Bluetooth** when asked, and turn on **GearVR Remote** under
   **Privacy & Security → Accessibility** so it can move the pointer.
4. Press **Home** on the controller. The app lives in the menu bar; open it from
   Launchpad or Spotlight at any time to show its Welcome and Settings window.

**Updating:** if the pointer stops moving after an update even though Accessibility
still looks on, macOS is holding on to the permission for the old build, and switching
it off and on isn't enough. In **Privacy & Security → Accessibility**, select
**GearVR Remote** and remove it with **−** (or run
`tccutil reset Accessibility com.dennisonbertram.gearvr-remote` in Terminal), then
relaunch the app and allow Accessibility again.

Protocol details, a Python version, and a 3D web viewer are in the
[repository](https://github.com/dennisonbertram/gearvr-controller).
