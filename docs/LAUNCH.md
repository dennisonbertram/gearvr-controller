# Launch checklist

What has to be true before GearVR Remote is announced publicly, what only the owner
can do (it needs an Apple account), and where the Mac App Store stands.

## 1. GitHub release (DMG)

- [ ] `VERSION` in `mac/build.sh` matches the tag you are about to push (currently 1.8.0).
- [ ] The top section of `mac/RELEASE_NOTES.md` describes this release. CI uses the whole
      file as the release body.
- [ ] CI is green on `main`: the Python tests (`pytest`) and the Swift core tests
      (`mac/build.sh test`) both run in `.github/workflows/release-mac.yml`.
- [ ] Push the tag: `git tag v1.8.0 && git push origin v1.8.0`. CI builds the universal
      app, packages `GearVR-Remote-1.8.0.dmg`, creates the release if needed, and
      attaches the DMG.
- [ ] Check the build log for which signing path ran. Without the secrets below it
      says `not notarizing` (or doesn't mention notarization at all), and the DMG is
      ad-hoc signed.
- [ ] On a second Mac (or a fresh user account), download the DMG from the release
      page, drag the app to Applications, open it, and run the Welcome checklist:
      Bluetooth, Accessibility, then press Home on the controller.
- [ ] Verify the signature of the downloaded app:

  ```sh
  codesign -dv --verbose=2 "/Applications/GearVR Remote.app"   # Authority=Developer ID Application, TeamIdentifier=...
  spctl -a -t exec -vv "/Applications/GearVR Remote.app"       # accepted, source=Notarized Developer ID
  xcrun stapler validate GearVR-Remote-1.8.0.dmg
  ```

- [ ] Once releases are notarized, remove the "Open Anyway" / `xattr` step from the
      Install sections of `mac/README.md` and `mac/RELEASE_NOTES.md`.
- [ ] The README download link and the hosted viewer URL resolve:
      <https://github.com/dennisonbertram/gearvr-controller/releases/latest>,
      <https://dennisonbertram.github.io/gearvr-controller/viewer/>.

### Why notarization matters before launch

Without it, releases are ad-hoc signed. That has two user-visible costs:

1. **Gatekeeper blocks every download.** Each new user has to find Privacy & Security →
   Open Anyway (or run `xattr`). Many people coming from a blog post will stop there.
2. **Every update silently drops Accessibility.** macOS stores the permission
   against the app's code signature. An ad-hoc signature is just a hash of the
   binary, so it changes with every build. After an update the switch still looks on,
   but the pointer doesn't move until the user removes the entry (or runs
   `tccutil reset Accessibility com.dennisonbertram.gearvr-remote`) and allows it
   again. A Developer ID signature identifies the team instead of the binary, so the
   permission survives updates.

## 2. Notarization: what the owner has to do

`mac/build.sh` and CI already handle Developer ID signing (hardened runtime, secure
timestamp, `mac/GearVRRemote.entitlements`), signing the DMG, `xcrun notarytool submit
--wait` and `xcrun stapler staple`. They switch on as soon as these secrets exist and
fall back to the current ad-hoc build otherwise.

1. **Join the Apple Developer Program** (USD 99/year) at
   <https://developer.apple.com/programs/>. An individual membership is enough; the
   certificate will show your legal name.
2. **Create a Developer ID Application certificate.** In Xcode → Settings → Accounts →
   Manage Certificates → + → *Developer ID Application*, or at
   developer.apple.com → Certificates → + (upload a CSR made in Keychain Access →
   Certificate Assistant). It must be *Developer ID Application*, not *Apple
   Development* or *Apple Distribution*.
3. **Export it as a .p12** from Keychain Access (My Certificates → right-click the
   certificate, including its private key → Export), with a strong password.
4. **Create an app-specific password** at <https://account.apple.com> → Sign-In and
   Security → App-Specific Passwords. notarytool uses this, not your Apple ID password.
5. **Find your Team ID** at developer.apple.com → Account → Membership details
   (10 characters).
6. **Add the repository secrets** (GitHub → Settings → Secrets and variables → Actions):

   | Secret | Value |
   |---|---|
   | `MACOS_CERT_P12_BASE64` | `base64 -i DeveloperID.p12 \| pbcopy`, then paste |
   | `MACOS_CERT_PASSWORD` | the .p12 export password |
   | `APPLE_ID` | your Apple Account email |
   | `APPLE_TEAM_ID` | the Team ID |
   | `APPLE_APP_PASSWORD` | the app-specific password |

7. **Test it** with a workflow run (Actions → Mac app → Run workflow) before tagging,
   and check the log shows `notarizing` followed by `The staple and validate action
   worked!`. To sign locally instead, export the same variables plus
   `SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"` and run
   `mac/build.sh dist`.
8. **Tell existing users once.** The first Developer ID release replaces the ad-hoc
   signature, so 1.x users need to reset Accessibility one last time. Say so in that
   release's notes; after that, updates keep the permission.

Notes:

- Only the DMG is notarized and stapled. The app inside is covered by the same ticket,
  and Gatekeeper fetches it online when the app is first opened. If offline first launch
  matters, also notarize a zip of the app and staple the app before building the DMG.
- The app is not sandboxed and doesn't need to be for Developer ID. The only
  entitlement is `com.apple.security.automation.apple-events`, which `shell:` actions
  that run `osascript` need under the hardened runtime. The Info.plist has the matching
  `NSAppleEventsUsageDescription`.

## 3. Mac App Store: frank assessment

**Recommendation: don't ship on the Mac App Store. Distribute the notarized DMG.**

The App Store requires the App Sandbox, and what this app does is control the
rest of the Mac. Feature by feature:

| Feature | How it works | In the sandbox / App Review |
|---|---|---|
| Bluetooth link | CoreBluetooth | Works, with `com.apple.security.device.bluetooth` |
| Launch at login | `SMAppService.mainApp` | Works |
| Volume slider | CoreAudio on the default output | Expected to work; verify on hardware |
| Pointer, clicks, keys, media keys | `CGEvent` posting to the whole system after Accessibility is granted | Technically possible on macOS 10.15+ with the user's consent, but an app whose main job requires Accessibility to drive other apps is a common rejection (guideline 2.4.5 and similar). This is the biggest risk. |
| Magnetic buttons | Reads other apps' UI with `AXUIElementCopyElementAtPosition` and writes `AXEnhancedUserInterface` / `AXManualAccessibility` into Chromium and Electron apps | Reading other apps' accessibility trees isn't reliably available to sandboxed apps, and changing their accessibility state is a review red flag. Would have to go. |
| `shell:` button actions | Runs arbitrary commands with `/bin/sh -c` | Confined by the sandbox so most commands fail, and running user-supplied code conflicts with guideline 2.5.2. Would have to go. |
| Settings | `UserDefaults` | Move into the sandbox container, so users switching from the DMG version lose their settings |

On top of that, the App Store needs an Apple Distribution certificate, a provisioning
profile, a `.pkg` built with `productbuild` and signed with a Mac Installer Distribution
certificate, and a unique, increasing `CFBundleVersion` for every upload (`build.sh`
reads `BUILD_NUMBER` for this). None of that exists yet.

### Options

1. **Outside the App Store, notarized (recommended).** Everything keeps working,
   updates keep their permissions once signed with Developer ID, and the only cost is
   the Developer Program fee plus the steps in section 2. This is how most
   comparable utilities ship (input remappers, window managers, mouse tools).
2. **A reduced, sandboxed App Store build alongside it.** A separate `-D MAS` build
   that:
   - drops `shell:` actions (or replaces them with "Open app" via `NSWorkspace` and
     "Run Shortcut" via a `shortcuts://` URL),
   - drops magnetic buttons and the `AXEnhancedUserInterface` writes,
   - asks for event posting with `CGRequestPostEventAccess()` instead of the
     Accessibility prompt,
   - and keeps the air-mouse, clicks, keys, media keys, touchpad and volume.

   Even then, approval isn't certain because pointer and keyboard control is still the
   core feature. Build and test a sandboxed version on hardware (event posting, volume)
   before spending time on submission. It also means maintaining two builds and two
   sets of release notes.

Go with option 1 for launch, and revisit option 2 only if there's clear demand from
people who will only install from the App Store.
