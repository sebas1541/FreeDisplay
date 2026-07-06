import AppKit
import CoreGraphics
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var wakeObserver: NSObjectProtocol?
    private let displayManager = DisplayManager()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settingsPopover = NSPopover()
    private var transientStatusMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent duplicate launches: if another instance is running, quit immediately
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        if runningApps.count > 1 {
            print("[FreeDisplay] Another instance is already running, exiting.")
            NSApp.terminate(nil)
            return
        }

        // Start intercepting brightness keys to route them to the display under the cursor.
        BrightnessKeyService.shared.start()
        configureStatusItem()
        configureDefaultsAndWakeHandling()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        BrightnessKeyService.shared.stop()
        // GammaService already handles CGDisplayRestoreColorSyncSettings via willTerminateNotification observer.
        VirtualDisplayService.shared.destroyAll()
    }

    // MARK: - Status Item

    private func configureStatusItem() {
        settingsPopover.behavior = .transient
        settingsPopover.contentSize = NSSize(width: 360, height: 640)
        settingsPopover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(displayManager)
        )

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "FreeDisplay")
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            showQuickMenu(from: sender)
            return
        }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            showQuickMenu(from: sender)
        }
    }

    private func showQuickMenu(from button: NSStatusBarButton) {
        settingsPopover.performClose(nil)
        let displays = quickMenuDisplays()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let item = NSMenuItem()
        item.view = FDQuickMenuView(displays: displays)
        menu.addItem(item)

        presentStatusMenu(menu, from: button)
    }

    private func quickMenuDisplays() -> [DisplayInfo] {
        displayManager.refreshDisplays()
        let displays = displayManager.displays.filter {
            !VirtualDisplayService.shared.isVirtualDisplay($0.displayID)
        }

        for display in displays {
            display.currentDisplayMode = DisplayMode.currentMode(for: display.displayID) ?? display.currentDisplayMode
            if display.availableModes.isEmpty {
                display.availableModes = DisplayMode.availableModes(for: display.displayID)
            }
        }

        return displays
    }

    private func showSettingsPopover() {
        displayManager.refreshDisplays()
        guard let button = statusItem.button else { return }
        settingsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showContextMenu() {
        settingsPopover.performClose(nil)

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(
            title: "More Settings...",
            action: #selector(openMoreSettings),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit FreeDisplay",
            action: #selector(quit),
            keyEquivalent: "q"
        ))
        menu.items.forEach { $0.target = self }

        presentStatusMenu(menu, from: statusItem.button)
    }

    private func presentStatusMenu(_ menu: NSMenu, from button: NSStatusBarButton?) {
        menu.delegate = self
        transientStatusMenu = menu
        statusItem.menu = menu
        button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === transientStatusMenu else { return }
        statusItem.menu = nil
        transientStatusMenu = nil
    }

    @objc private func openMoreSettings() {
        DispatchQueue.main.async { [weak self] in
            self?.showSettingsPopover()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Display Lifecycle

    private func configureDefaultsAndWakeHandling() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "fd.arrangement.externalAbove") == nil {
            defaults.set(true, forKey: "fd.arrangement.externalAbove")
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            displayManager.arrangeExternalAboveBuiltin()
        }
    }

    private func handleWake() {
        Task { @MainActor in
            // Give WindowServer 2 seconds to stabilize after wake before touching display state.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            displayManager.refreshDisplays()
            try? await Task.sleep(nanoseconds: 500_000_000)
            for display in displayManager.displays {
                // Apply software brightness factor first so GammaService can read the up-to-date factor.
                BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
                GammaService.shared.reapplyIfNeeded(for: display.displayID)
                // Re-apply any custom resolution that macOS may have reset on wake.
                ResolutionService.shared.reapplySavedModeIfNeeded(for: display.displayID)
            }
        }
    }
}

// MARK: - MonitorControl-style Quick Menu

private final class FDQuickMenuView: NSView {
    private let contentWidth: CGFloat = 278
    private let inset: CGFloat = 10
    private let spacing: CGFloat = 9

    init(displays: [DisplayInfo]) {
        let blockHeight: CGFloat = SettingsService.shared.hideBrightnessInQuickMenu ? 80 : 112
        let height: CGFloat
        if displays.isEmpty {
            height = 68
        } else {
            height = 2 * inset + CGFloat(displays.count) * blockHeight + CGFloat(max(0, displays.count - 1)) * spacing
        }

        super.init(frame: NSRect(x: 0, y: 0, width: contentWidth, height: min(height, 520)))
        wantsLayer = true
        setup(displays: displays, blockHeight: blockHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    private func setup(displays: [DisplayInfo], blockHeight: CGFloat) {
        if displays.isEmpty {
            let label = FDClickThroughTextField(labelWithString: "No displays detected")
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.frame = bounds.insetBy(dx: inset, dy: 22)
            addSubview(label)
            return
        }

        var y = inset
        for display in displays {
            let block = FDQuickDisplayBlockView(display: display)
            block.frame = NSRect(
                x: inset,
                y: y,
                width: contentWidth - 2 * inset,
                height: blockHeight
            )
            addSubview(block)
            y += blockHeight + spacing
        }
    }
}

private final class FDQuickDisplayBlockView: NSView {
    private let display: DisplayInfo
    private let titleLabel = FDClickThroughTextField(labelWithString: "")
    private let brightnessSlider = FDQuickSlider()
    private let brightnessIcon = FDClickThroughImageView()
    private let brightnessValueLabel = FDClickThroughTextField(labelWithString: "")
    private let modeSlider = FDQuickSlider()
    private let modeIcon = FDClickThroughImageView()
    private let modeValueLabel = FDClickThroughTextField(labelWithString: "")
    private var modes: [DisplayMode] = []
    private var appliedModeID: Int32 = 0
    private var isSwitchingMode = false
    private var lastBrightnessSend = Date.distantPast
    private let hideBrightness: Bool

    init(display: DisplayInfo) {
        self.display = display
        self.hideBrightness = SettingsService.shared.hideBrightnessInQuickMenu
        super.init(frame: .zero)
        wantsLayer = true
        setupViews()
        if !hideBrightness {
            syncBrightness()
        }
        syncModes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor(white: 1, alpha: 0.055).setFill()
        path.fill()

        NSColor(white: 1, alpha: 0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func layout() {
        super.layout()

        let sliderX: CGFloat = 26
        let sliderWidth = bounds.width - sliderX * 2
        let sliderHeight: CGFloat = 28
        let titleY: CGFloat = 14
        let brightnessY: CGFloat = 44
        let modeY: CGFloat = hideBrightness ? 44 : 76

        titleLabel.frame = NSRect(x: sliderX, y: titleY, width: sliderWidth, height: 20)
        brightnessSlider.frame = NSRect(x: sliderX, y: brightnessY, width: sliderWidth, height: sliderHeight)
        modeSlider.frame = NSRect(x: sliderX, y: modeY, width: sliderWidth, height: sliderHeight)

        brightnessIcon.frame = NSRect(x: sliderX + 7, y: brightnessY + 6, width: 15, height: 15)
        modeIcon.frame = NSRect(x: sliderX + 7, y: modeY + 6, width: 15, height: 15)

        brightnessValueLabel.frame = NSRect(
            x: sliderX + sliderWidth - 55,
            y: brightnessY + 5,
            width: 48,
            height: 18
        )
        modeValueLabel.frame = NSRect(
            x: sliderX + sliderWidth - 99,
            y: modeY + 5,
            width: 92,
            height: 18
        )
    }

    private func setupViews() {
        titleLabel.stringValue = display.name
        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        configureOverlayIcon(modeIcon, symbolName: "rectangle.on.rectangle")
        configureOverlayLabel(modeValueLabel)
        configureModeSlider()
        addSubview(modeSlider)
        addSubview(modeIcon)
        addSubview(modeValueLabel)

        guard !hideBrightness else { return }

        configureOverlayIcon(brightnessIcon, symbolName: "sun.max.fill")
        configureOverlayLabel(brightnessValueLabel)
        configureBrightnessSlider()

        addSubview(brightnessSlider)
        addSubview(brightnessIcon)
        addSubview(brightnessValueLabel)
    }

    private func configureOverlayIcon(_ icon: NSImageView, symbolName: String) {
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.contentTintColor = NSColor.black.withAlphaComponent(0.62)
        icon.imageAlignment = .alignCenter
    }

    private func configureOverlayLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
    }

    /// Value labels sit on top of the slider bar itself, which is always a hardcoded white/dark
    /// track regardless of system appearance — a dynamic system color (e.g. secondaryLabelColor)
    /// can end up nearly invisible in dark mode when the fill happens to reach the label's
    /// position. Outlining the text keeps it legible over either the white fill or the dark track.
    private static let overlayTextParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        return style
    }()

    private func setOverlayText(_ text: String, on label: NSTextField) {
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black.withAlphaComponent(0.6),
            .strokeWidth: -3.0,
            .paragraphStyle: Self.overlayTextParagraphStyle
        ])
    }

    private func configureBrightnessSlider() {
        brightnessSlider.minValue = 0
        brightnessSlider.maxValue = 100
        brightnessSlider.isContinuous = true
        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged(_:))
        brightnessSlider.trackingEnded = { [weak self] in
            self?.sendBrightness(force: true)
        }
    }

    private func configureModeSlider() {
        modeSlider.minValue = 0
        modeSlider.maxValue = 0
        modeSlider.isContinuous = true
        modeSlider.target = self
        modeSlider.action = #selector(modeSliderChanged(_:))
        modeSlider.trackingEnded = { [weak self] in
            self?.applySelectedMode()
        }
    }

    private func syncBrightness() {
        let value = display.brightness.clamped(to: 0...100)
        brightnessSlider.doubleValue = value
        setOverlayText("\(Int(value.rounded()))%", on: brightnessValueLabel)
        brightnessSlider.needsDisplay = true
    }

    private func syncModes() {
        modes = Self.hidpiModes(for: display)
        let maxIndex = max(0, modes.count - 1)
        modeSlider.minValue = 0
        modeSlider.maxValue = Double(maxIndex)
        modeSlider.isEnabled = !modes.isEmpty
        modeSlider.setTickCount(modes.count)

        guard !modes.isEmpty else {
            modeSlider.doubleValue = 0
            setOverlayText("No HiDPI", on: modeValueLabel)
            appliedModeID = 0
            modeSlider.needsDisplay = true
            return
        }

        let index = selectedModeIndex()
        modeSlider.doubleValue = Double(index)
        appliedModeID = display.currentDisplayMode?.id ?? modes[index].id
        updateModeLabel(index: index)
        modeSlider.needsDisplay = true
    }

    @objc private func brightnessChanged(_ sender: FDQuickSlider) {
        sendBrightness(force: false)
    }

    private func sendBrightness(force: Bool) {
        let value = brightnessSlider.doubleValue.clamped(to: 0...100)
        setOverlayText("\(Int(value.rounded()))%", on: brightnessValueLabel)

        if !force, Date().timeIntervalSince(lastBrightnessSend) < 0.016 {
            display.brightness = value
            return
        }

        lastBrightnessSend = Date()
        display.brightness = value
        Task { @MainActor in
            await BrightnessService.shared.setBrightness(value, for: display)
        }
    }

    @objc private func modeSliderChanged(_ sender: FDQuickSlider) {
        guard !modes.isEmpty else { return }
        updateModeLabel(index: selectedSliderIndex())
    }

    private func applySelectedMode() {
        guard !modes.isEmpty, !isSwitchingMode else { return }

        let index = selectedSliderIndex()
        let mode = modes[index]
        guard mode.id != appliedModeID else { return }

        isSwitchingMode = true
        appliedModeID = mode.id
        setOverlayText(mode.resolutionString, on: modeValueLabel)

        let displayID = display.displayID
        Task { @MainActor in
            var success = await ResolutionService.shared.setDisplayMode(mode, for: displayID)
            if !success {
                try? await Task.sleep(nanoseconds: 200_000_000)
                success = await ResolutionService.shared.setDisplayMode(mode, for: displayID)
            }

            if success {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let refreshedMode = await Task.detached(priority: .userInitiated) {
                    DisplayMode.currentMode(for: displayID)
                }.value
                display.currentDisplayMode = refreshedMode ?? mode
                appliedModeID = display.currentDisplayMode?.id ?? mode.id
                syncModes()
            } else {
                syncModes()
            }

            isSwitchingMode = false
        }
    }

    private func selectedSliderIndex() -> Int {
        guard !modes.isEmpty else { return 0 }
        return Int(modeSlider.doubleValue.rounded()).clamped(to: 0...(modes.count - 1))
    }

    private func selectedModeIndex() -> Int {
        guard !modes.isEmpty else { return 0 }
        if let current = display.currentDisplayMode,
           let exact = modes.firstIndex(where: { $0.id == current.id }) {
            return exact
        }

        if let current = display.currentDisplayMode,
           let sameResolution = modes.firstIndex(where: {
               $0.width == current.width && $0.height == current.height
           }) {
            return sameResolution
        }

        return max(0, modes.count - 1)
    }

    private func updateModeLabel(index: Int) {
        guard modes.indices.contains(index) else {
            setOverlayText("No HiDPI", on: modeValueLabel)
            return
        }
        setOverlayText(modes[index].resolutionString, on: modeValueLabel)
    }

    private static func hidpiModes(for display: DisplayInfo) -> [DisplayMode] {
        let (nativeWidth, nativeHeight) = display.nativeResolution
        let nativeAspect = nativeHeight > 0 ? Double(nativeWidth) / Double(nativeHeight) : 0

        let filtered = display.availableModes.filter {
            guard $0.isHiDPI, $0.width >= 1024, $0.height >= 576 else { return false }
            guard nativeAspect > 0 else { return true }
            let aspect = Double($0.width) / Double($0.height)
            // Only offer modes that preserve the display's native aspect ratio — scaled modes
            // with a different ratio would letterbox/stretch rather than cleanly resize.
            return abs(aspect - nativeAspect) < 0.02
        }

        var bestByResolution: [String: DisplayMode] = [:]
        for mode in filtered {
            let key = "\(mode.width)x\(mode.height)"
            if let existing = bestByResolution[key] {
                let shouldReplace =
                    mode.refreshRate > existing.refreshRate ||
                    (mode.refreshRate == existing.refreshRate && mode.pixelWidth > existing.pixelWidth)
                if shouldReplace {
                    bestByResolution[key] = mode
                }
            } else {
                bestByResolution[key] = mode
            }
        }

        return bestByResolution.values.sorted {
            if $0.width != $1.width { return $0.width < $1.width }
            if $0.height != $1.height { return $0.height < $1.height }
            return $0.refreshRate < $1.refreshRate
        }
    }
}

private final class FDQuickSlider: NSSlider {
    var trackingEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = FDQuickSliderCell()
        sliderType = .linear
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setTickCount(_ count: Int) {
        (cell as? FDQuickSliderCell)?.tickCount = count
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        trackingEnded?()
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled else { return }
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        let range = maxValue - minValue
        let step = range <= 1 ? 1 : max(1, range / 100)
        doubleValue = (doubleValue + Double(delta) * step).clamped(to: minValue...maxValue)
        sendAction(action, to: target)
        trackingEnded?()
    }
}

private final class FDQuickSliderCell: NSSliderCell {
    var tickCount = 0
    private var isTrackingSlider = false

    override func barRect(flipped: Bool) -> NSRect {
        guard let controlView else {
            return super.barRect(flipped: flipped)
        }

        let height: CGFloat = 22
        return NSRect(
            x: 0,
            y: (controlView.bounds.height - height) / 2,
            width: controlView.bounds.width,
            height: height
        )
    }

    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        isTrackingSlider = true
        return super.startTracking(at: startPoint, in: controlView)
    }

    override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView, mouseIsUp flag: Bool) {
        isTrackingSlider = false
        super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
    }

    override func drawKnob(_ knobRect: NSRect) {
        // Drawn inside drawBar so the knob sits flush with the rounded track.
    }

    override func drawBar(inside aRect: NSRect, flipped: Bool) {
        let min = self.minValue
        let range = max(self.maxValue - min, 0.0001)
        let progress = CGFloat(((self.doubleValue - min) / range).clamped(to: 0...1))
        let rect = aRect.insetBy(dx: 0.5, dy: 0)
        let radius = rect.height / 2

        let background = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.systemGray.withAlphaComponent(0.24).setFill()
        background.fill()

        let fillWidth = rect.height + (rect.width - rect.height) * progress
        let filledRect = NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
        let filled = NSBezierPath(roundedRect: filledRect, xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(0.82).setFill()
        filled.fill()

        drawTicks(in: rect)

        let knobX = rect.minX + (rect.width - rect.height) * progress
        let knobRect = NSRect(x: knobX, y: rect.minY, width: rect.height, height: rect.height)
        for offset in 1...3 {
            let shadow = NSBezierPath(
                roundedRect: knobRect.offsetBy(dx: CGFloat(-offset * 2), dy: 0),
                xRadius: radius,
                yRadius: radius
            )
            NSColor.black.withAlphaComponent(0.025).setFill()
            shadow.fill()
        }

        let knob = NSBezierPath(roundedRect: knobRect, xRadius: radius, yRadius: radius)
        (isTrackingSlider ? NSColor(white: 0.9, alpha: 1) : NSColor.white).setFill()
        knob.fill()
        NSColor.systemGray.withAlphaComponent(0.45).setStroke()
        knob.lineWidth = 0.75
        knob.stroke()

        NSColor.systemGray.withAlphaComponent(0.45).setStroke()
        background.lineWidth = 1
        background.stroke()
    }

    private func drawTicks(in rect: NSRect) {
        guard tickCount > 1 else { return }

        // Every step gets a tick (including both ends), each drawn as a small dark ring with a
        // light center so it stays visible whether it lands on the white fill or the dark track.
        let usableWidth = rect.width - rect.height
        for index in 0..<tickCount {
            let progress = CGFloat(index) / CGFloat(tickCount - 1)
            let x = rect.minX + rect.height / 2 + usableWidth * progress

            let outer = NSBezierPath(ovalIn: NSRect(x: x - 2.5, y: rect.midY - 2.5, width: 5, height: 5))
            NSColor.black.withAlphaComponent(0.2).setFill()
            outer.fill()

            let inner = NSBezierPath(ovalIn: NSRect(x: x - 1.25, y: rect.midY - 1.25, width: 2.5, height: 2.5))
            NSColor.white.withAlphaComponent(0.6).setFill()
            inner.fill()
        }
    }
}

private final class FDClickThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class FDClickThroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
