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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // Existing installs stored settings under the bare executable name;
    // pin the domain so a bundle ID change never resets them.
    private let store = UserDefaults(suiteName: "screen-dimmer") ?? .standard

    private lazy var clock = BreakClock(
        schedule: DimmerSchedule(interval: 20 * 60, visibleDuration: 50),
        store: store
    )
    private let overlayController = ScreenOverlayController()
    private lazy var focusPanel = FocusPanelController(clock: clock)
    private let threadFeed = T3ThreadFeed()
    private lazy var threadPanel = ThreadStatusPanelController(feed: threadFeed)
    private var isOverlayShown = false
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let pauseMenuItem = NSMenuItem()
    private let breakMenuItem = NSMenuItem()
    private let statusMenuItem = NSMenuItem()
    private let threadAccessMenuItem = NSMenuItem(title: "Re-enable T3 Thread Status", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenuBar()
        overlayController.prepare()
        focusPanel.start()
        threadPanel.start()
        clock.onChange = { [weak self] in self?.clockChanged() }
        clockChanged()
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayController.hide()
    }

    private func clockChanged() {
        let wantsOverlay = clock.isResting
        if wantsOverlay != isOverlayShown {
            isOverlayShown = wantsOverlay
            wantsOverlay ? overlayController.show() : overlayController.hide()
        }
        focusPanel.refresh()
        pauseMenuItem.title = clock.isPaused ? "Resume Breaks" : "Pause Breaks"
        breakMenuItem.title = clock.isResting ? "Back to Work" : "Take a Break Now"
    }

    private func configureMenuBar() {
        statusItem.button?.title = "Dim"
        statusItem.button?.toolTip = "Screen Dimmer"

        pauseMenuItem.target = self
        pauseMenuItem.action = #selector(togglePause)
        breakMenuItem.target = self
        breakMenuItem.action = #selector(toggleBreak)
        statusMenuItem.isEnabled = false
        threadAccessMenuItem.target = self
        threadAccessMenuItem.action = #selector(reenableThreadAccess)
        threadAccessMenuItem.toolTip = "T3 revoked miced's read-only session. Issue a new one."

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(pauseMenuItem)
        menu.addItem(breakMenuItem)
        menu.addItem(.separator())
        menu.addItem(statusMenuItem)
        menu.addItem(threadAccessMenuItem)

        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let left = formatClock(clock.remaining)
        statusMenuItem.title = clock.isPaused ? "Paused · \(left) of focus left"
            : clock.isResting ? "On a break · \(left)" : "Next break in \(left)"
        threadAccessMenuItem.isHidden = threadFeed.state != .revoked
    }

    @objc private func togglePause() { clock.togglePause() }
    @objc private func toggleBreak() { clock.isResting ? clock.startFocus() : clock.startBreak() }
    @objc private func reenableThreadAccess() { threadFeed.reenableAccess() }
}

struct DimmerSchedule {
    let interval: TimeInterval
    let visibleDuration: TimeInterval
}

func formatClock(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded(.up))
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// The focus/break cycle. Pausing keeps the focus countdown where it was, and
/// the state survives relaunches (login, reinstall, crash) via `store`.
@MainActor
final class BreakClock: NSObject {
    enum Phase { case focus, rest }

    private enum Keys {
        static let running = "isDimmingEnabled"
        static let pausedRemaining = "pausedRemaining"
        static let focusEndsAt = "focusEndsAt"
    }

    let schedule: DimmerSchedule
    var onChange: (() -> Void)?
    private(set) var phase = Phase.focus
    private(set) var isPaused = false
    private var deadline = Date()
    private var pausedRemaining: TimeInterval = 0
    private var timer: Timer?
    private var awaySince: Date?
    private let store: UserDefaults

    init(schedule: DimmerSchedule, store: UserDefaults) {
        self.schedule = schedule
        self.store = store
        super.init()

        if store.object(forKey: Keys.running) != nil && !store.bool(forKey: Keys.running) {
            isPaused = true
            let saved = store.double(forKey: Keys.pausedRemaining)
            pausedRemaining = saved > 0 ? min(saved, schedule.interval) : schedule.interval
        } else {
            let left = store.double(forKey: Keys.focusEndsAt) - Date().timeIntervalSince1970
            run(.focus, for: left > 0 && left <= schedule.interval ? left : schedule.interval)
        }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(self, selector: #selector(wentAway), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(self, selector: #selector(cameBack), name: name, object: nil)
        }
    }

    var isResting: Bool { phase == .rest && !isPaused }
    var remaining: TimeInterval { isPaused ? pausedRemaining : max(0, deadline.timeIntervalSinceNow) }
    var duration: TimeInterval { phase == .focus ? schedule.interval : schedule.visibleDuration }

    func togglePause() { isPaused ? resume() : pause() }

    func pause() {
        guard !isPaused else { return }
        // Pausing ends a break; a focus countdown keeps its place.
        pausedRemaining = phase == .focus ? remaining : schedule.interval
        phase = .focus
        isPaused = true
        timer?.invalidate()
        changed()
    }

    func resume() {
        guard isPaused else { return }
        run(.focus, for: pausedRemaining)
    }

    func startFocus() { run(.focus, for: schedule.interval) }
    func startBreak() { run(.rest, for: schedule.visibleDuration) }

    private func run(_ newPhase: Phase, for seconds: TimeInterval) {
        phase = newPhase
        isPaused = false
        deadline = Date(timeIntervalSinceNow: seconds)
        timer?.invalidate()
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.phaseEnded() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        changed()
    }

    private func phaseEnded() {
        // Nobody is looking at a sleeping display, so that break is skipped.
        if phase == .focus && awaySince == nil { startBreak() } else { startFocus() }
    }

    @objc private func wentAway() {
        if awaySince == nil { awaySince = Date() }
    }

    @objc private func cameBack() {
        guard let awaySince else { return }
        self.awaySince = nil
        // Time away from the screen counts as a break.
        if !isPaused && Date().timeIntervalSince(awaySince) >= schedule.visibleDuration { startFocus() }
    }

    private func changed() {
        store.set(!isPaused, forKey: Keys.running)
        store.set(isPaused ? pausedRemaining : 0, forKey: Keys.pausedRemaining)
        store.set(!isPaused && phase == .focus ? deadline.timeIntervalSince1970 : 0, forKey: Keys.focusEndsAt)
        onChange?()
    }
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
