import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            ButtonsTab().tabItem { Label("Buttons", systemImage: "button.programmable") }
            PointerTab().tabItem { Label("Pointer", systemImage: "cursorarrow.motionlines") }
            TouchpadTab().tabItem { Label("Touchpad", systemImage: "hand.point.up.left") }
            ClutchTab().tabItem { Label("Clutch", systemImage: "hand.raised") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 520)
        .padding(.vertical, 6)
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
                SliderRow(title: "Dead zone", value: $model.config.deadzoneDPS, range: 0...5, format: "%.1f °/s")
                SliderRow(title: "Click steadying", value: $model.config.clickFreezeMS, range: 0...400, format: "%.0f ms")
            }
            Section {
                Text("Point and turn the controller to move the cursor. Turning is measured around the real vertical, so it works however you roll your wrist. When it connects, set the controller down for a second so it can calibrate the gyro.")
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
