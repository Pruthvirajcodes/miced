import AppKit
import Foundation

@main
struct ScreenDimmerApp {
    static func main() {
        // launchd redirects stdout to a log file; keep it line-buffered.
        setlinebuf(stdout)
        let app = NSApplication.shared
        let delegate = AppDelegate()

        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Preferences {
        static let isDimmingEnabledKey = "isDimmingEnabled"
        // Existing installs stored settings under the bare executable name;
        // pin the domain so a bundle ID change never resets them.
        nonisolated(unsafe) static let store = UserDefaults(suiteName: "screen-dimmer") ?? .standard
    }

    private let schedule = DimmerSchedule(
        interval: 20 * 60,
        visibleDuration: 50
    )

    private let overlayController = ScreenOverlayController()
    private lazy var focusPanel = FocusPanelController(schedule: schedule) { [weak self] in
        self?.toggleDimming()
    }
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let toggleMenuItem = NSMenuItem()
    private let statusMenuItem = NSMenuItem()
    private var dimmingTask: Task<Void, Never>?
    private var isDimmingEnabled: Bool

    override init() {
        if Preferences.store.object(forKey: Preferences.isDimmingEnabledKey) == nil {
            isDimmingEnabled = true
        } else {
            isDimmingEnabled = Preferences.store.bool(forKey: Preferences.isDimmingEnabledKey)
        }

        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenuBar()
        overlayController.prepare()
        focusPanel.start()

        // A short preview exercises the real overlay without waiting 20 minutes.
        if CommandLine.arguments.contains("--preview-break") {
            overlayController.show()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.overlayController.hide()
            }
        }

        if isDimmingEnabled {
            startDimmingSchedule()
        }

        // Shows the hover card without hovering, for visual checks.
        if CommandLine.arguments.contains("--preview-panel") {
            focusPanel.pin()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopDimmingSchedule()
        overlayController.hide()
    }

    @objc
    private func toggleDimming() {
        isDimmingEnabled.toggle()
        Preferences.store.set(isDimmingEnabled, forKey: Preferences.isDimmingEnabledKey)

        if isDimmingEnabled {
            startDimmingSchedule()
        } else {
            stopDimmingSchedule()
            overlayController.hide()
        }

        updateMenuBar()
    }

    private func configureMenuBar() {
        statusItem.button?.title = "Dim"
        statusItem.button?.toolTip = "Screen Dimmer"

        toggleMenuItem.target = self
        toggleMenuItem.action = #selector(toggleDimming)

        statusMenuItem.isEnabled = false

        let menu = NSMenu()
        menu.addItem(toggleMenuItem)
        menu.addItem(.separator())
        menu.addItem(statusMenuItem)

        statusItem.menu = menu
        updateMenuBar()
    }

    private func updateMenuBar() {
        toggleMenuItem.title = isDimmingEnabled ? "Turn Dimming Off" : "Turn Dimming On"
        toggleMenuItem.state = isDimmingEnabled ? .on : .off
        statusMenuItem.title = isDimmingEnabled ? "Status: dimming enabled" : "Status: paused"
    }

    private func startDimmingSchedule() {
        guard dimmingTask == nil else {
            return
        }

        dimmingTask?.cancel()
        dimmingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                focusPanel.phase = .focus(until: Date(timeIntervalSinceNow: schedule.interval))
                try? await Task.sleep(for: .seconds(schedule.interval))

                guard !Task.isCancelled else {
                    return
                }

                overlayController.show()
                focusPanel.phase = .onBreak(until: Date(timeIntervalSinceNow: schedule.visibleDuration))

                try? await Task.sleep(for: .seconds(schedule.visibleDuration))

                guard !Task.isCancelled else {
                    return
                }

                overlayController.hide()
            }
        }
    }

    private func stopDimmingSchedule() {
        dimmingTask?.cancel()
        dimmingTask = nil
        focusPanel.phase = .paused
    }
}

struct DimmerSchedule {
    let interval: TimeInterval
    let visibleDuration: TimeInterval
}

enum BreakPhase {
    case paused
    case focus(until: Date)
    case onBreak(until: Date)
}

@MainActor
final class ScreenOverlayController {
    private var windows: [NSWindow] = []

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func prepare() {
        rebuildWindows(isVisible: false)
    }

    func show() {
        if windows.count != NSScreen.screens.count {
            rebuildWindows(isVisible: false)
        }

        windows.forEach { window in
            if let screen = window.screen {
                window.setFrame(screen.frame, display: true)
            }
            window.alphaValue = 0
            window.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            windows.forEach { $0.animator().alphaValue = 1 }
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            windows.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: { [windows] in
            Task { @MainActor in
                // A break that started during the fade-out keeps its windows.
                windows.filter { $0.alphaValue == 0 }.forEach { $0.orderOut(nil) }
            }
        }
    }

    @objc
    private func screensDidChange() {
        let wasVisible = windows.contains { $0.isVisible }
        rebuildWindows(isVisible: wasVisible)
    }

    private func rebuildWindows(isVisible: Bool) {
        windows.forEach { $0.close() }
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )

            let contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.black.cgColor

            window.contentView = contentView
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.alphaValue = isVisible ? 1 : 0

            if isVisible {
                window.orderFrontRegardless()
            }

            return window
        }
    }
}
