import AppKit
import SwiftUI

// MARK: - Shared Icon Helper

/// A colored rounded-square SF Symbol icon, consistent with macOS Settings style.
struct MenuItemIcon: View {
    let systemName: String
    var color: Color = .blue

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
    }
}

// MARK: - ExpandableRow

struct ExpandableRow: View {
    let icon: String
    var iconColor: Color = .blue
    let label: String
    var subtitle: String? = nil
    @Binding var isExpanded: Bool
    @State private var isHovered = false

    var body: some View {
        HStack {
            MenuItemIcon(systemName: icon, color: iconColor)
            Text(label).font(.body)
            Spacer()
            if let sub = subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(isExpanded ? "\(label), expanded" : "\(label), collapsed")
        .accessibilityHint("Click to expand or collapse this section")
        .accessibilityAddTraits(.isButton)
        .help("Click to expand or collapse this section")
    }
}

struct MenuBarView: View {
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var updateService = UpdateService.shared
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var virtualDisplayService = VirtualDisplayService.shared
    @State private var expandedDisplayIDs: Set<CGDirectDisplayID> = []
    @State private var showArrangement: Bool = false
    @State private var showVirtualDisplays: Bool = false
    @State private var showAutoBrightness: Bool = false
    @State private var showSettings: Bool = false
    @State private var quitHovered = false

    private var visibleDisplays: [DisplayInfo] {
        displayManager.displays.filter { !virtualDisplayService.isVirtualDisplay($0.displayID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Display list
                    if visibleDisplays.isEmpty {
                        HStack(spacing: 8) {
                            MenuItemIcon(systemName: "display.trianglebadge.exclamationmark", color: .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("No displays detected")
                                    .font(.body)
                                Text("Rescans when the menu opens")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Refresh") {
                                displayManager.refreshDisplays()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    } else {
                        ForEach(visibleDisplays) { display in
                            VStack(spacing: 0) {
                                DisplayRowView(
                                    display: display,
                                    isExpanded: expandedDisplayIDs.contains(display.displayID),
                                    onToggleExpand: {
                                        if expandedDisplayIDs.contains(display.displayID) {
                                            expandedDisplayIDs.remove(display.displayID)
                                        } else {
                                            expandedDisplayIDs.insert(display.displayID)
                                        }
                                    }
                                )

                                if expandedDisplayIDs.contains(display.displayID) {
                                    DisplayDetailView(display: display)
                                }
                            }
                        }
                    }

                    // Preset list (Phase 19)
                    Divider()
                        .opacity(0.3)
                        .padding(.vertical, 2)

                PresetListView()

                // Arrange Displays section (Phase 4)
                if visibleDisplays.count > 1 {
                    Divider()
                        .opacity(0.3)
                        .padding(.vertical, 2)

                    ExpandableRow(
                        icon: "rectangle.3.offgrid",
                        iconColor: .blue,
                        label: "Arrange Displays",
                        isExpanded: $showArrangement
                    )

                    if showArrangement {
                        ArrangementView()
                            .environmentObject(displayManager)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                // Combined brightness control (Phase 2)
                if settings.showCombinedBrightness {
                    CombinedBrightnessView(displays: displayManager.displays)
                    Divider()
                        .opacity(0.3)
                        .padding(.vertical, 2)
                }

                // Tools section title
                Text("Tools")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 2)

                // Virtual displays tool entry (Phase 10)
                ExpandableRow(
                    icon: "display.2",
                    iconColor: .blue,
                    label: "Virtual Displays",
                    isExpanded: $showVirtualDisplays
                )

                if showVirtualDisplays {
                    VirtualDisplayView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Auto brightness entry (Phase 11)
                ExpandableRow(
                    icon: "sun.and.horizon.fill",
                    iconColor: .orange,
                    label: "Auto Brightness",
                    isExpanded: $showAutoBrightness
                )

                if showAutoBrightness {
                    AutoBrightnessView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                // Settings section (Phase 12)
                ExpandableRow(
                    icon: "gearshape.fill",
                    iconColor: .gray,
                    label: "Settings",
                    isExpanded: $showSettings
                )

                if showSettings {
                    SettingsView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                // Update notice (Phase 12)
                if updateService.hasUpdate, let ver = updateService.latestVersion {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text("New version v\(ver) available")
                            .font(.caption)
                            .foregroundColor(.green)
                        Spacer()
                        Button("View") { updateService.openReleasePage() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundColor(.blue)
                            .help("Download and install the latest version")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(6)
                    .padding(.horizontal, 8)
                }

                }
            }
            .frame(minHeight: 360, maxHeight: 620)
            .layoutPriority(1)

        Divider().opacity(0.3)

        // Version and quit controls fixed at the bottom
        HStack {
            Text("FreeDisplay v\(updateService.currentVersion)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Spacer()
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "xmark")
                        .accessibilityHidden(true)
                    Text("Quit")
                }
                .font(.body)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(quitHovered ? Color.primary.opacity(0.06) : .clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(quitHovered ? .red : .secondary)
            .onHover { quitHovered = $0 }
            .help("Quit FreeDisplay")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        } // end VStack
        .frame(width: 340)
        .padding(.vertical, 8)
        .onReceive(displayManager.$displays) { newDisplays in
            let validIDs = Set(newDisplays.map { $0.displayID })
            expandedDisplayIDs = expandedDisplayIDs.intersection(validIDs)
        }
        .task {
            displayManager.refreshDisplays()
            if settings.checkUpdatesOnLaunch {
                await updateService.checkForUpdates()
            }
        }
    }
}

// MARK: - SettingsView (Phase 12: embedded in MenuBarView)

struct SettingsView: View {
    @EnvironmentObject private var displayManager: DisplayManager
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Launch at Login
            Toggle(isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    if newValue {
                        LaunchService.shared.enable()
                    } else {
                        LaunchService.shared.disable()
                    }
                    settings.launchAtLogin = newValue
                }
            )) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "power", color: .green)
                        .accessibilityHidden(true)
                    Text("Launch at Login")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Start FreeDisplay when you log in")

            // First launch prompt: suggest launch at login
            if !settings.launchAtLoginPrompted {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text("Consider enabling launch at login")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Got it") {
                        settings.launchAtLoginPrompted = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .onAppear {
                    // Mark as prompted so it only shows once
                    // User dismisses manually via "Got it" button
                }
            }

            // Show combined brightness
            Toggle(isOn: $settings.showCombinedBrightness) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "sun.min.fill", color: .yellow)
                        .accessibilityHidden(true)
                    Text("Show combined brightness control")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Show one brightness slider for all displays")

            // Software brightness fallback
            Toggle(isOn: Binding(
                get: { settings.allowSoftwareBrightness },
                set: { newValue in
                    settings.allowSoftwareBrightness = newValue
                    if !newValue {
                        BrightnessService.shared.disableSoftwareBrightness(for: displayManager.displays)
                    }
                }
            )) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "sun.haze.fill", color: .orange)
                        .accessibilityHidden(true)
                    Text("Allow software brightness")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("When off, FreeDisplay only uses hardware/system brightness and never dims with gamma software fallback")

            // Keyboard brightness shortcuts
            Toggle(isOn: $settings.brightnessShortcutsEnabled) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "keyboard", color: .purple)
                        .accessibilityHidden(true)
                    Text("Keyboard brightness shortcuts")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Use custom global shortcuts to adjust the display under the cursor")

            if settings.brightnessShortcutsEnabled {
                ShortcutRecorderRow(
                    title: "Increase brightness",
                    systemImage: "sun.max.fill",
                    color: .yellow,
                    shortcut: Binding(
                        get: { settings.brightnessIncreaseShortcut },
                        set: { settings.brightnessIncreaseShortcut = $0 }
                    )
                )
                ShortcutRecorderRow(
                    title: "Decrease brightness",
                    systemImage: "sun.min.fill",
                    color: .orange,
                    shortcut: Binding(
                        get: { settings.brightnessDecreaseShortcut },
                        set: { settings.brightnessDecreaseShortcut = $0 }
                    )
                )
            }

            // Check for updates at launch
            Toggle(isOn: $settings.checkUpdatesOnLaunch) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "arrow.clockwise.circle", color: .blue)
                        .accessibilityHidden(true)
                    Text("Check for updates at launch")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Automatically check for new versions at launch")
        }
        .padding(.vertical, 6)
    }
}

struct ShortcutRecorderRow: View {
    let title: String
    let systemImage: String
    let color: Color
    @Binding var shortcut: KeyboardShortcutSpec?

    @State private var isRecording = false
    @State private var previewText = "Set"
    @State private var capturedShortcut: KeyboardShortcutSpec?
    @State private var localMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            MenuItemIcon(systemName: systemImage, color: color)
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
            Spacer(minLength: 8)
            Button(action: startRecording) {
                Text(buttonTitle)
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 92, maxWidth: 160)
            }
            .controlSize(.small)
            .help("Click, press a key combination, then release the main key")

            Button(action: { shortcut = nil }) {
                Image(systemName: "xmark.circle")
                    .accessibilityLabel("Clear \(title) shortcut")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .opacity(shortcut == nil ? 0.35 : 1)
            .disabled(shortcut == nil)
            .help("Clear shortcut")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .onDisappear { stopRecording() }
    }

    private var buttonTitle: String {
        if isRecording { return previewText }
        return Self.displayString(for: shortcut) ?? "Set"
    }

    private func startRecording() {
        stopRecording()
        capturedShortcut = nil
        previewText = "Press keys..."
        isRecording = true

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            handleRecordingEvent(event)
            return nil
        }
    }

    private func stopRecording() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        isRecording = false
        capturedShortcut = nil
    }

    private func handleRecordingEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let flags = Self.normalizedModifierFlags(event.modifierFlags)
            previewText = flags.isEmpty ? "Press keys..." : Self.modifierString(flags)
        case .keyDown:
            if event.keyCode == Self.escapeKeyCode {
                stopRecording()
                return
            }

            let flags = Self.normalizedModifierFlags(event.modifierFlags)
            if flags.isEmpty && !Self.allowsBareKey(event.keyCode) {
                previewText = "Add modifier"
                return
            }

            let captured = KeyboardShortcutSpec(
                keyCode: Int(event.keyCode),
                modifierFlags: UInt64(flags.rawValue)
            )
            capturedShortcut = captured
            previewText = Self.displayString(for: captured) ?? "Press keys..."
        case .keyUp:
            guard let capturedShortcut, Int(event.keyCode) == capturedShortcut.keyCode else { return }
            shortcut = capturedShortcut
            stopRecording()
        default:
            break
        }
    }

    private static let escapeKeyCode: UInt16 = 53

    private static func normalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
    }

    private static func allowsBareKey(_ keyCode: UInt16) -> Bool {
        (96...126).contains(keyCode)
    }

    private static func displayString(for shortcut: KeyboardShortcutSpec?) -> String? {
        guard let shortcut else { return nil }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(shortcut.modifierFlags))
        let modifierText = modifierString(flags)
        let keyText = keyName(for: shortcut.keyCode)
        return modifierText.isEmpty ? keyText : "\(modifierText) \(keyText)"
    }

    private static func modifierString(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Option") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Command") }
        return parts.joined(separator: " ")
    }

    private static func keyName(for keyCode: Int) -> String {
        let names: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space",
            50: "`", 51: "Delete", 53: "Escape", 65: ".", 67: "*", 69: "+",
            71: "Clear", 75: "/", 76: "Enter", 78: "-", 81: "=", 82: "0",
            83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7",
            91: "8", 92: "9", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
            100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16",
            107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help",
            115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4",
            119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "Left",
            124: "Right", 125: "Down", 126: "Up"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}

// MARK: - DisplayRowView

struct DisplayRowView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @State private var isHovered: Bool = false

    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                    .rotationEffect(Angle(degrees: isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    .accessibilityHidden(true)

                MenuItemIcon(systemName: display.isBuiltin ? "laptopcomputer" : "display", color: .blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let mode = display.currentDisplayMode {
                        Text(mode.resolutionString)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                if display.isMain {
                    Text("Main")
                        .font(.caption2)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.12))
                        .cornerRadius(3)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }
            .help("Expand display controls")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0))
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open in System Settings", systemImage: "display")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(display.name, forType: .string)
            } label: {
                Label("Copy Display Name", systemImage: "doc.on.doc")
            }
        }
        .accessibilityLabel("Display: \(display.name)\(display.isMain ? ", main display" : "")\(isExpanded ? ", expanded" : ", collapsed")")
        .accessibilityHint("Click to expand controls")
        .accessibilityAddTraits(.isButton)
    }
}
