// Reads and sets the default output device's volume through CoreAudio, for the
// touchpad's volume mode. (Button presses use media keys instead, so macOS shows
// its own volume HUD and plays the feedback click.)
import AppKit
import CoreAudio

enum SystemAudio {
    private static var device: AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    /// The main volume, or the left and right channel volumes on devices that only have those.
    private static func levels(_ device: AudioDeviceID) -> [(address: AudioObjectPropertyAddress, value: Double)] {
        func read(_ element: AudioObjectPropertyElement) -> (AudioObjectPropertyAddress, Double)? {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                     mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
            return (address, Double(value))
        }
        if let main = read(kAudioObjectPropertyElementMain) { return [main] }
        return [1, 2].compactMap(read)
    }

    /// The louder channel, when there is no main volume.
    static var volume: Double? {
        guard let device else { return nil }
        return levels(device).map(\.value).max()
    }

    private static var balance: [Double]? // per-channel level relative to the louder one

    @discardableResult
    static func setVolume(_ level: Double) -> Bool {
        guard let device else { return false }
        let level = min(max(level, 0), 1)
        let current = levels(device)
        let top = current.map(\.value).max() ?? 0
        // scale the channels together so the balance set in Sound settings survives,
        // remembering it across a slide down to silence
        if top > 0.001, current.count > 1 { balance = current.map { $0.value / top } }
        let ratios = current.count > 1 && balance?.count == current.count ? balance! : current.map { _ in 1.0 }
        let size = UInt32(MemoryLayout<Float32>.size)
        var ok = false
        for (i, (var address, _)) in current.enumerated() {
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { continue }
            var value = Float32(ratios[i] * level)
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr { ok = true }
        }
        if ok { unmuteIfNeeded(device) }
        return ok
    }

    private static func unmuteIfNeeded(_ device: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr, muted == 1 else { return }
        var off = UInt32(0)
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &off)
    }
}

/// Small floating level indicator, shown while the touchpad is changing the volume
/// (macOS only shows its own HUD for media keys).
@MainActor
final class VolumeHUD {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let bar = NSView()
    private let fill = NSView()
    private var hideWork: DispatchWorkItem?

    func show(level: Double) {
        let panel = self.panel ?? makePanel()
        label.stringValue = "\(Int((level * 100).rounded()))%"
        let width = bar.bounds.width * min(max(level, 0), 1)
        fill.frame = CGRect(x: 0, y: 0, width: width, height: bar.bounds.height)
        hideWork?.cancel()
        if panel.isVisible {
            // may be fading out: take over the running animation
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
        } else {
            position(panel)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.4
                    self.panel?.animator().alphaValue = 0
                }
                self.hide(after: 0.45)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func hide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.panel?.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2,
                                     y: screen.frame.minY + screen.frame.height * 0.12))
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.hasShadow = true

        let blur = NSVisualEffectView(frame: p.contentRect(forFrameRect: p.frame))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)!)
        icon.frame = CGRect(x: 16, y: 20, width: 24, height: 24)
        icon.contentTintColor = .labelColor

        bar.frame = CGRect(x: 50, y: 28, width: 118, height: 8)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.2).cgColor
        bar.layer?.cornerRadius = 4
        bar.layer?.masksToBounds = true
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.labelColor.cgColor
        bar.addSubview(fill)

        label.frame = CGRect(x: 172, y: 22, width: 40, height: 18)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.alignment = .right

        blur.addSubview(icon)
        blur.addSubview(bar)
        blur.addSubview(label)
        p.contentView = blur
        panel = p
        return p
    }
}
