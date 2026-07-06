import AppKit
import CoreGraphics
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var wakeObserver: NSObjectProtocol?
    private let displayManager = DisplayManager()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let quickPopover = NSPopover()
    private let settingsPopover = NSPopover()

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
        quickPopover.behavior = .transient
        quickPopover.contentSize = NSSize(width: 360, height: 560)
        quickPopover.contentViewController = NSHostingController(
            rootView: QuickDisplayPanelView()
                .environmentObject(displayManager)
        )

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
            showQuickPopover(relativeTo: sender)
            return
        }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            showQuickPopover(relativeTo: sender)
        }
    }

    private func showQuickPopover(relativeTo button: NSStatusBarButton) {
        settingsPopover.performClose(nil)
        displayManager.refreshDisplays()

        if quickPopover.isShown {
            quickPopover.performClose(nil)
        } else {
            quickPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showSettingsPopover() {
        quickPopover.performClose(nil)
        displayManager.refreshDisplays()
        guard let button = statusItem.button else { return }
        settingsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showContextMenu() {
        quickPopover.performClose(nil)
        settingsPopover.performClose(nil)

        let menu = NSMenu()
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

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
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
