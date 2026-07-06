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

// MARK: - QuickDisplayPanelView

struct QuickDisplayPanelView: View {
    @EnvironmentObject private var displayManager: DisplayManager
    @ObservedObject private var virtualDisplayService = VirtualDisplayService.shared

    private var visibleDisplays: [DisplayInfo] {
        displayManager.displays.filter { !virtualDisplayService.isVirtualDisplay($0.displayID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if visibleDisplays.isEmpty {
                        HStack(spacing: 8) {
                            MenuItemIcon(systemName: "display.trianglebadge.exclamationmark", color: .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("No displays detected")
                                    .font(.body)
                                Text("Rescans when opened")
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
                        .padding(.vertical, 10)
                    } else {
                        ForEach(visibleDisplays) { display in
                            QuickDisplayControlView(display: display)
                        }
                    }
                }
                .padding(9)
            }
            .frame(maxHeight: 500)
        }
        .frame(width: 250)
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            displayManager.refreshDisplays()
        }
    }
}

struct QuickDisplayControlView: View {
    @ObservedObject var display: DisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(display.name)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 14)

            QuickBrightnessSliderView(display: display)
            QuickHiDPIResolutionSliderView(display: display)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.18), lineWidth: 1)
        )
        .padding(.bottom, 9)
    }
}

struct QuickBrightnessSliderView: View {
    @ObservedObject var display: DisplayInfo
    @State private var localBrightness: Double = 50
    @State private var isDragging = false
    @State private var lastDDCWrite: Date = .distantPast

    var body: some View {
        QuickPillSlider(
            value: $localBrightness,
            range: 5...100,
            step: 1,
            icon: "sun.max.fill",
            valueText: "\(Int(localBrightness))%",
            showsTicks: false,
            onEditingChanged: { editing in
                isDragging = editing
                if !editing {
                    Task { @MainActor in
                        BrightnessService.shared.setBrightnessSmooth(localBrightness, for: display)
                    }
                    lastDDCWrite = Date()
                }
            }
        )
        .accessibilityLabel("Brightness")
        .accessibilityValue("\(Int(localBrightness))%")
        .onChange(of: localBrightness) { _, newValue in
            guard isDragging else { return }
            let now = Date()
            let isDDC = BrightnessService.shared.isDDCAvailable(for: display.displayID) == true
            if isDDC && now.timeIntervalSince(lastDDCWrite) < 0.02 {
                display.brightness = newValue
                return
            }
            lastDDCWrite = now
            display.brightness = newValue
            Task { @MainActor in
                await BrightnessService.shared.setBrightness(newValue, for: display)
            }
        }
        .onAppear { localBrightness = display.brightness }
        .onChange(of: display.brightness) { _, newValue in
            if !isDragging && abs(newValue - localBrightness) >= 1 {
                localBrightness = newValue
            }
        }
    }
}

struct QuickHiDPIResolutionSliderView: View {
    @ObservedObject var display: DisplayInfo
    @State private var selectedIndex: Double = 0
    @State private var appliedModeID: Int32 = 0
    @State private var isSwitching = false

    private var modes: [DisplayMode] {
        let filtered = display.availableModes.filter {
            $0.isHiDPI && $0.width >= 1024 && $0.height >= 576
        }
        var seen = Set<String>()
        return filtered
            .filter { mode in
                let key = "\(mode.width)x\(mode.height)"
                return seen.insert(key).inserted
            }
            .sorted {
                if $0.width != $1.width { return $0.width < $1.width }
                if $0.height != $1.height { return $0.height < $1.height }
                return $0.refreshRate < $1.refreshRate
            }
    }

    private var selectedMode: DisplayMode? {
        guard !modes.isEmpty else { return nil }
        let index = min(max(Int(selectedIndex.rounded()), 0), modes.count - 1)
        return modes[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            QuickPillSlider(
                value: $selectedIndex,
                range: 0...Double(max(modes.count - 1, 0)),
                step: 1,
                icon: "rectangle.on.rectangle",
                valueText: selectedMode.map(modeTitle) ?? "No HiDPI",
                showsTicks: modes.count > 1,
                onEditingChanged: { editing in
                    guard !editing, let mode = selectedMode else { return }
                    switchTo(mode)
                }
            )
            .opacity(modes.isEmpty ? 0.45 : 1)
            .disabled(isSwitching || modes.isEmpty)
        }
        .onAppear {
            syncSelection()
        }
        .onChange(of: display.currentDisplayMode?.id) { _, newID in
            if let newID, appliedModeID != newID {
                syncSelection()
            }
        }
    }

    private func modeTitle(_ mode: DisplayMode) -> String {
        mode.resolutionString
    }

    private func syncSelection() {
        guard !modes.isEmpty else {
            selectedIndex = 0
            appliedModeID = 0
            return
        }

        if let current = display.currentDisplayMode,
           let exact = modes.firstIndex(where: { $0.id == current.id }) {
            selectedIndex = Double(exact)
            appliedModeID = current.id
            return
        }

        if let current = display.currentDisplayMode,
           let sameResolution = modes.firstIndex(where: {
               $0.width == current.width && $0.height == current.height
           }) {
            selectedIndex = Double(sameResolution)
            appliedModeID = current.id
            return
        }

        selectedIndex = Double(max(modes.count - 1, 0))
        appliedModeID = modes[Int(selectedIndex)].id
    }

    private func switchTo(_ mode: DisplayMode) {
        guard mode.id != appliedModeID else { return }
        isSwitching = true
        let displayID = display.displayID
        Task { @MainActor in
            var success = await ResolutionService.shared.setDisplayMode(mode, for: displayID)
            if !success {
                try? await Task.sleep(nanoseconds: 200_000_000)
                success = await ResolutionService.shared.setDisplayMode(mode, for: displayID)
            }
            if success {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let refreshedMode = await Task.detached(priority: .userInitiated) {
                    DisplayMode.currentMode(for: displayID)
                }.value
                display.currentDisplayMode = refreshedMode ?? mode
                appliedModeID = (refreshedMode ?? mode).id
            } else {
                syncSelection()
            }
            isSwitching = false
        }
    }
}

struct QuickPillSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let icon: String
    let valueText: String
    let showsTicks: Bool
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let height: CGFloat = 28
            let knobSize: CGFloat = 28
            let trackHeight: CGFloat = 22
            let iconSize: CGFloat = 24
            let minX: CGFloat = 0
            let width = max(proxy.size.width, knobSize)
            let trackWidth = width
            let progress = CGFloat((value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1))
                .clamped(to: 0...1)
            let knobX = minX + progress * (trackWidth - knobSize)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(0.24), lineWidth: 1)
                    )
                    .frame(width: trackWidth, height: trackHeight)
                    .offset(y: (height - trackHeight) / 2)

                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: max(iconSize, knobX + knobSize), height: trackHeight)
                    .offset(y: (height - trackHeight) / 2)
                    .opacity(0.82)

                if showsTicks {
                    HStack(spacing: 0) {
                        ForEach(0..<Int(max(range.upperBound - range.lowerBound, 0)) + 1, id: \.self) { index in
                            Circle()
                                .fill(Color.primary.opacity(0.18))
                                .frame(width: 3, height: 3)
                            if index < Int(max(range.upperBound - range.lowerBound, 0)) {
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(width: trackWidth, height: height)
                }

                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
                    .frame(width: iconSize, height: iconSize)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                    )
                    .offset(x: 2, y: (height - iconSize) / 2)

                Circle()
                    .fill(isDragging ? Color(white: 0.86) : Color.white)
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 1)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: knobX)

                Text(valueText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(progress > 0.62 ? .black.opacity(0.55) : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: 86, alignment: .trailing)
                    .offset(x: width - 90, y: 7)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        updateValue(from: gesture.location.x, width: trackWidth)
                    }
                    .onEnded { gesture in
                        updateValue(from: gesture.location.x, width: trackWidth)
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 28)
    }

    private func updateValue(from x: CGFloat, width: CGFloat) {
        let progress = Double((x / max(width, 1)).clamped(to: 0...1))
        let raw = range.lowerBound + (range.upperBound - range.lowerBound) * progress
        let stepped = (raw / step).rounded() * step
        value = min(max(stepped, range.lowerBound), range.upperBound)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - SettingsView (Phase 12: embedded in MenuBarView)

struct SettingsView: View {
    @EnvironmentObject private var displayManager: DisplayManager
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var brightnessKeys = BrightnessKeyService.shared

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

                if brightnessKeys.inputMonitoringStatus != kIOHIDAccessTypeGranted {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text("Shortcuts won't fire until Input Monitoring access is granted — the OS keeps handling the key combo otherwise.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Open Settings") {
                            BrightnessKeyService.shared.start()
                            BrightnessKeyService.openInputMonitoringSettings()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
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
        flags.intersection([.command, .option, .control, .shift])
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
