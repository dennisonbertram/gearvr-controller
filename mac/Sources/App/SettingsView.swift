import SwiftUI

enum SettingsTab: Hashable {
    case welcome, buttons, pointer, touchpad, clutch, general
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            WelcomeTab().tabItem { Label("Welcome", systemImage: "hand.wave") }.tag(SettingsTab.welcome)
            ButtonsTab().tabItem { Label("Buttons", systemImage: "button.programmable") }.tag(SettingsTab.buttons)
            PointerTab().tabItem { Label("Pointer", systemImage: "cursorarrow.motionlines") }.tag(SettingsTab.pointer)
            TouchpadTab().tabItem { Label("Touchpad", systemImage: "hand.point.up.left") }.tag(SettingsTab.touchpad)
            ClutchTab().tabItem { Label("Clutch", systemImage: "hand.raised") }.tag(SettingsTab.clutch)
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
        }
        .frame(width: 540)
        .frame(minHeight: 560)
        .padding(.vertical, 6)
    }
}

/// First-run guide and live setup checklist. Also shown when the app is launched while already running.
struct WelcomeTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GearVR Remote lives in your menu bar").font(.title3.weight(.semibold))
                        HStack(spacing: 6) {
                            Text("Look for")
                            Image(nsImage: ControllerGlyph.image(model.glyphStyle)).renderingMode(.template)
                            Text("at the top right of the screen. Click it for quick controls.")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Setup") {
                CheckRow(done: model.linkState != .unauthorized, title: "Bluetooth access",
                         detail: model.linkState == .unauthorized ? "Allow GearVR Remote under Privacy & Security → Bluetooth." : "Allowed")
                CheckRow(done: model.accessibilityTrusted, title: "Accessibility access",
                         detail: model.accessibilityTrusted ? "Allowed. The controller can move the pointer."
                                                            : "Needed to move the pointer and click.") {
                    if !model.accessibilityTrusted { Button("Open Settings…") { model.openAccessibilitySettings() } }
                }
                CheckRow(done: model.isStreaming, title: "Controller connected",
                         detail: model.isStreaming ? (model.deviceName ?? "Connected") : "Press Home on the controller to wake it.")
                Toggle("Start GearVR Remote when you log in",
                       isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
            Section("Controls") {
                ForEach([("Point & turn", "move the pointer"),
                         ("Trigger", "click · hold and move to drag"),
                         ("Touchpad", "slide to scroll · click to right-click"),
                         ("Home", "air mouse on/off"),
                         ("Trigger + touch bottom of pad", "freeze the pointer while you re-grip"),
                         ("Slow down near a button", "the pointer snaps onto it (magnetic buttons)"),
                         ("Back · Volume ±", "Escape · system volume")], id: \.0) { control, action in
                    LabeledContent(control) { Text(action).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CheckRow<Accessory: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var accessory: () -> Accessory

    init(done: Bool, title: String, detail: String, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.done = done
        self.title = title
        self.detail = detail
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? Color.green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            accessory()
        }
    }
}

struct ButtonsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(ControllerButton.allCases, id: \.self) { b in
                    ActionEditor(title: b.title, action: Binding(
                        get: { model.config.buttons[b.rawValue] ?? "none" },
                        set: { model.config.buttons[b.rawValue] = $0 }))
                }
            } footer: {
                Text("Holding Home for several seconds puts the controller into pairing mode and erases its pairing with this Mac, so don't rely on long-pressing Home.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PointerTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Gyro air mouse") {
                Toggle("Air mouse on at launch", isOn: $model.config.pointerEnabledAtLaunch)
                SliderRow(title: "Speed", value: $model.config.sensitivity, range: 6...60, format: "%.0f px/°")
                SliderRow(title: "Smoothing", value: $model.config.smoothing, range: 0...1, format: "%.0f%%", scale: 100)
                    .help("Evens out small wobbles. It adapts to speed: steadier when you move slowly, quick when you move fast. 0% turns it off.")
                SliderRow(title: "Dead zone", value: $model.config.deadzoneDPS, range: 0...5, format: "%.1f °/s")
                SliderRow(title: "Click steadying", value: $model.config.clickFreezeMS, range: 0...400, format: "%.0f ms")
            }
            Section {
                Toggle("Snap the pointer onto buttons", isOn: $model.config.magnetEnabled)
                MagnetStrengthRow(strength: $model.config.magnetStrength)
            } header: {
                Text("Magnetic buttons")
            } footer: {
                Text("Near buttons, links, checkboxes, menu items and Dock icons the pointer gets a little sticky: your motion is damped over them (most when you're nearly still, which cancels arm wobble) and bends slightly toward them as you approach. It never moves on its own. Past the middle of the slider it becomes a real magnet: the pointer snaps onto the nearest button and holds, a small push hops to the next one, and a push into empty space pulls free. Works in apps that support Accessibility, which is nearly all of them, including web pages in Safari and Chrome.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Not sure what suits you?") {
                    Button("Start training…") { model.showTraining() }
                }
                LabeledContent("Pointer drifting on its own?") {
                    Button("Recalibrate gyro…") { model.showCalibration() }
                }
                Text("Point and turn the controller to move the cursor. Turning is measured around the real vertical, so it works however you roll your wrist. When it connects, set the controller down for a second so it can calibrate the gyro. Smoothing adapts to speed: it steadies slow, careful movement and stays out of the way when you move fast.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct TouchpadTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Touchpad") {
                Picker("While the air mouse is on", selection: $model.config.touchModePointerOn) {
                    ForEach(TouchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("While the air mouse is off", selection: $model.config.touchModePointerOff) {
                    ForEach(TouchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SliderRow(title: "Cursor speed", value: $model.config.cursorSpeed, range: 0.5...8, format: "%.1f×")
                SliderRow(title: "Scroll speed", value: $model.config.scrollSpeed, range: 0.1...2, format: "%.1f×")
                Toggle("Invert scrolling", isOn: $model.config.invertScroll)
            }
            Section {
                Toggle("Holding a button repeats it", isOn: $model.config.repeatWhileHeld)
                    .help("Keys and media keys repeat while you hold the button, like a keyboard, so holding volume down keeps lowering it.")
            } footer: {
                Text("Touchpad modes: Scroll, Cursor (trackpad-style pointer), Swipes (quick flicks run the actions below), Volume (slide up and down for the system volume), or Off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Swipes (in Swipes mode)") {
                ForEach([("swipe_left", "Swipe left"), ("swipe_right", "Swipe right"), ("swipe_up", "Swipe up"),
                         ("swipe_down", "Swipe down"), ("tap", "Tap")], id: \.0) { key, title in
                    ActionEditor(title: title, action: Binding(
                        get: { model.config.gestures[key] ?? "none" },
                        set: { model.config.gestures[key] = $0 }))
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ClutchTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Enable re-home clutch", isOn: $model.config.clutchEnabled)
                Picker("Hold", selection: $model.config.clutchButton) {
                    ForEach(ControllerButton.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Then touch", selection: $model.config.clutchZone) {
                    ForEach(ClutchZone.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                SliderRow(title: "Zone size", value: $model.config.clutchZoneSize, range: 0.15...0.6, format: "%.0f%%", scale: 100)
                SliderRow(title: "Drag starts after", value: $model.config.dragThresholdPX, range: 2...40, format: "%.0f px")
                Toggle("Play sounds", isOn: $model.config.clutchSound)
            } footer: {
                Text("Hold the trigger, touch the bottom of the touchpad (tink), let go of the pad and move your hand to a comfortable position while the cursor stays put. Release the trigger (pop) to resume. With the clutch on, a trigger tap clicks on release and a drag starts once the pointer moves past the threshold.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                LabeledContent("Accessibility") {
                    if model.accessibilityTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Settings…") { model.openAccessibilitySettings() }
                    }
                }
                LabeledContent("Controller", value: model.statusText)
            }
            Section {
                Button("Reset all settings to defaults", role: .destructive) { model.resetConfig() }
            }
            Section {
                Link("Protocol notes and source on GitHub",
                     destination: URL(string: "https://github.com/dennisonbertram/gearvr-controller")!)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: shared controls

struct MagnetStrengthRow: View {
    @Binding var strength: Double

    var body: some View {
        let m = MagnetSettings(strength: strength)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Magnet strength")
                Spacer()
                Text(m.describes).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("Subtle").font(.caption).foregroundStyle(.secondary)
                Slider(value: $strength, in: 0...1)
                Text("Strong").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale = 1.0

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range).frame(width: 220)
                Text(String(format: format, value * scale)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
        }
    }
}

/// Edits an action string: a kind picker plus a parameter field where needed.
struct ActionEditor: View {
    let title: String
    @Binding var action: String

    enum Kind: String, CaseIterable, Identifiable {
        case left = "Left click", right = "Right click", middle = "Middle click", key = "Key combo",
             media = "Media key", shell = "Shell command", toggle = "Toggle air mouse", none = "Nothing"
        var id: String { rawValue }
    }

    private var kind: Kind {
        switch Action(action) {
        case .click(.left): return .left
        case .click(.right): return .right
        case .click(.middle): return .middle
        case .key: return .key
        case .media: return .media
        case .shell: return .shell
        case .togglePointer: return .toggle
        case .none: return .none
        }
    }

    private var argument: String {
        guard let i = action.firstIndex(of: ":") else { return "" }
        return String(action[action.index(after: i)...])
    }

    private func set(_ k: Kind, _ arg: String) {
        switch k {
        case .left: action = "left_click"
        case .right: action = "right_click"
        case .middle: action = "middle_click"
        case .key: action = "key:\(arg)"
        case .media: action = "media:\(arg.isEmpty ? "play" : arg)"
        case .shell: action = "shell:\(arg)"
        case .toggle: action = "toggle_pointer"
        case .none: action = "none"
        }
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { kind }, set: { set($0, kind == $0 ? argument : "") })) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
                switch kind {
                case .key:
                    TextField("", text: Binding(get: { argument }, set: { set(.key, $0) }), prompt: Text("cmd+shift+["))
                        .labelsHidden()
                        .frame(width: 130)
                        .foregroundStyle(KeyCombo.parse(argument) == nil ? Color.red : .primary)
                        .help("Modifiers cmd, shift, alt/option, ctrl, fn joined with + and a key: a–z, 0–9, left, right, up, down, space, return, escape, tab, delete, f1–f12, pageup, pagedown, home, end, or punctuation.")
                case .media:
                    Picker("", selection: Binding(get: { argument }, set: { set(.media, $0) })) {
                        ForEach(MediaKey.names, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                case .shell:
                    TextField("", text: Binding(get: { argument }, set: { set(.shell, $0) }), prompt: Text("open -a Safari"))
                        .labelsHidden()
                        .frame(width: 130)
                default:
                    Color.clear.frame(width: 130, height: 1)
                }
            }
        }
    }
}
