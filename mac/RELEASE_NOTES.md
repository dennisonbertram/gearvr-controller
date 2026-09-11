**GearVR Remote** is a menu-bar app that turns a Samsung Gear VR Controller
(ET-YO324 / SM-R324) into a gyro air-mouse, trackpad, and media remote for
macOS 14 or later. It's a universal build for Apple silicon and Intel.

### Install

1. Download **GearVR-Remote-x.y.z.dmg** below, open it, and drag **GearVR Remote**
   into **Applications**.
2. Open it. The app isn't notarized by Apple, so the first time macOS will say it
   can't verify the developer. Go to **System Settings → Privacy & Security**,
   scroll down, and click **Open Anyway**. (Or run
   `xattr -dr com.apple.quarantine "/Applications/GearVR Remote.app"`.)
3. Allow **Bluetooth** when asked, and turn on **GearVR Remote** under
   **Privacy & Security → Accessibility** so it can move the pointer.
4. Press **Home** on the controller. The app lives in the menu bar; open it from
   Launchpad or Spotlight at any time to show its Welcome and Settings window.

If you update, you may need to switch Accessibility off and on again for the new build.

Protocol details, a Python version, and a 3D web viewer are in the
[repository](https://github.com/dennisonbertram/gearvr-controller).
