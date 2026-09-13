import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.accessibilityTrusted && !model.dryRun { accessibilityWarning }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                SwitchRow(title: "Control this Mac", isOn: $model.enabled)
                SwitchRow(title: "Air mouse", isOn: $model.pointerOn)
                    .disabled(!model.enabled)
                SwitchRow(title: "Magnetic buttons", isOn: $model.config.magnetEnabled)
                    .help("Makes buttons, links and menu items slightly sticky so arm wobble doesn't knock the pointer off them.")
                if model.config.magnetEnabled {
                    MagnetStrengthRow(strength: $model.config.magnetStrength)
                        .controlSize(.small)
                        .padding(.leading, 12)
                }
                SwitchRow(title: "Re-home clutch", isOn: $model.config.clutchEnabled)
                    .help("Hold the trigger and touch the bottom of the touchpad to freeze the cursor while you reposition your hand.")
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Pointer speed")
                    Spacer()
                    Text("\(Int(model.config.sensitivity))").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $model.config.sensitivity, in: 6...60)
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Touchpad")
                Picker("Touchpad", selection: $model.config.touchModePointerOn) {
                    ForEach(TouchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            LiveControllerView(live: model.live, clutched: model.clutched, streaming: model.isStreaming)

            Divider()
            HStack {
                Button("Settings…") { model.presentSettings() }
                Button("Recalibrate…") { model.showCalibration() }
                    .help("Re-measure the gyro's zero point. Use this if the pointer drifts while your hand is still.")
                Button("Training…") { model.showTraining() }
                    .help("A one-minute aiming exercise that suggests pointer speed, smoothing and magnet strength for you.")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 310)
        .onAppear { model.liveVisible = true }
        .onDisappear { model.liveVisible = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: ControllerGlyph.image(model.isStreaming ? .active : .disconnected, size: 30))
                .renderingMode(.template)
                .foregroundStyle(model.isStreaming ? Color.accentColor : .secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.deviceName ?? "Gear VR Controller").font(.headline).lineLimit(1)
                Text(model.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if let level = model.battery, model.isStreaming { BatteryBadge(level: level) }
        }
    }

    private var accessibilityWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Accessibility access needed", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("macOS ignores the pointer and clicks until GearVR Remote is allowed under Privacy & Security → Accessibility.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

struct BatteryBadge: View {
    let level: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text("\(level)%").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(level <= 15 ? Color.red : .secondary)
    }

    private var symbol: String {
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Top-down sketch of the controller showing live touch and button state.
struct LiveControllerView: View {
    let live: LiveState
    let clutched: Bool
    let streaming: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.07))
                Circle().strokeBorder(live.buttons.contains(.touchpad) ? Color.accentColor : Color.primary.opacity(0.15),
                                      lineWidth: live.buttons.contains(.touchpad) ? 2 : 1)
                if clutched {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Color.accentColor)
                } else if live.touch.touching {
                    Circle().fill(Color.accentColor)
                        .frame(width: 10, height: 10)
                        .offset(x: (Double(live.touch.x) / GearVR.touchMax - 0.5) * 50,
                                y: (Double(live.touch.y) / GearVR.touchMax - 0.5) * 50)
                }
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 5) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                    ForEach([ControllerButton.trigger, .home, .back, .touchpad, .volumeUp, .volumeDown], id: \.self) {
                        chip($0)
                    }
                }
                Text(footer).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .opacity(streaming ? 1 : 0.45)
    }

    private func chip(_ b: ControllerButton) -> some View {
        let on = live.buttons.contains(b)
        let label: String = {
            switch b {
            case .touchpad: return "Pad"
            case .volumeUp: return "Vol+"
            case .volumeDown: return "Vol−"
            default: return b.title
            }
        }()
        return Text(label)
            .font(.caption2.weight(on ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
            .foregroundStyle(on ? Color.white : .secondary)
    }

    private var footer: String {
        guard streaming else { return "not connected" }
        let cal = live.gyroCalibrated ? "gyro calibrated" : "calibrating gyro…"
        let temp = live.temperature.map { " · \($0)°C" } ?? ""
        return "\(Int(live.packetRate)) pkt/s · \(cal)\(temp)"
    }
}

extension TouchMode {
    var title: String {
        switch self {
        case .scroll: return "Scroll"
        case .cursor: return "Cursor"
        case .gestures: return "Swipes"
        case .volume: return "Volume"
        case .off: return "Off"
        }
    }
}
