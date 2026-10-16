import AppKit

/// A small work/break timer card. It stays hidden until the pointer rests in
/// the right edge of the primary display, where the old sidebar used to be.
@MainActor
final class FocusPanelController: NSObject {
    static let hoverWidth: CGFloat = 280
    private static let hoverDelay: TimeInterval = 0.35
    private static let size = NSSize(width: 248, height: 152)
    private static let margin: CGFloat = 16

    var phase: BreakPhase = .paused {
        didSet { refresh() }
    }

    private let schedule: DimmerSchedule
    private let onToggle: () -> Void
    private var panel: NSPanel?
    private var poll: Timer?
    private var hoverStarted: Date?
    private var isShowing = false
    private var isPinned = false

    private let caption = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let progress = CatTrack()
    private let toggleButton = NSButton(title: "", target: nil, action: nil)

    init(schedule: DimmerSchedule, onToggle: @escaping () -> Void) {
        self.schedule = schedule
        self.onToggle = onToggle
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(positionPanel),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func start() {
        buildPanel()
        // Reading the pointer position needs no privacy permission, whereas a
        // global mouse monitor received nothing when launched as a login item.
        poll = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPointer() }
        }
        poll?.tolerance = 0.05
        RunLoop.main.add(poll!, forMode: .common)
    }

    /// Keeps the card open regardless of the pointer, for visual checks.
    func pin() {
        isPinned = true
        show()
    }

    private func show() {
        guard let panel, !isShowing else { return }
        isShowing = true
        refresh()
        positionPanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel, isShowing else { return }
        isShowing = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                // The pointer may have come back during the fade-out.
                if self?.isShowing == false { panel.orderOut(nil) }
            }
        }
    }

    private func pollPointer() {
        let inside = pointerInHoverArea
        if isShowing {
            // While visible: count down and notice when the pointer leaves.
            if isPinned || inside { refresh() } else { hide() }
        } else if !inside {
            hoverStarted = nil
        } else if let hoverStarted {
            // A short dwell so sweeping across the edge does not flash the card.
            if Date().timeIntervalSince(hoverStarted) >= Self.hoverDelay { show() }
        } else {
            hoverStarted = Date()
        }
    }

    private var hoverArea: NSRect? {
        // The first screen is the display with the menu bar, independent of focus.
        // visibleFrame leaves out the menu bar so its status items stay usable.
        guard let frame = NSScreen.screens.first?.visibleFrame else { return nil }
        let width = min(Self.hoverWidth, frame.width)
        return NSRect(x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
    }

    private var pointerInHoverArea: Bool {
        hoverArea?.contains(NSEvent.mouseLocation) ?? false
    }

    private func refresh() {
        switch phase {
        case .paused:
            caption.stringValue = "PAUSED"
            time.stringValue = Self.clock(schedule.interval)
            time.textColor = .tertiaryLabelColor
            detail.stringValue = "Screen breaks are off"
            progress.fraction = 0
            progress.mood = .sitting
            toggleButton.title = "Resume"
        case .focus(let until):
            let remaining = max(0, until.timeIntervalSinceNow)
            caption.stringValue = "FOCUS"
            time.stringValue = Self.clock(remaining)
            time.textColor = .labelColor
            detail.stringValue = "until a \(Int(schedule.visibleDuration))-second break"
            progress.fraction = 1 - remaining / schedule.interval
            progress.mood = .walking
            toggleButton.title = "Pause"
        case .onBreak(let until):
            let remaining = max(0, until.timeIntervalSinceNow)
            caption.stringValue = "BREAK"
            time.stringValue = Self.clock(remaining)
            time.textColor = .labelColor
            detail.stringValue = "Look away from the screen"
            progress.fraction = 1 - remaining / schedule.visibleDuration
            progress.mood = .sleeping
            toggleButton.title = "Pause"
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @objc private func toggle() {
        onToggle()
        refresh()
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        // Above the break overlay, so hovering during a break shows time left.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let card = NSVisualEffectView()
        card.material = .popover
        card.blendingMode = .behindWindow
        card.state = .active
        card.maskImage = Self.roundedMask(radius: 14)
        panel.contentView = card

        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        time.font = .monospacedDigitSystemFont(ofSize: 38, weight: .light)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        toggleButton.bezelStyle = .rounded
        toggleButton.controlSize = .small
        toggleButton.target = self
        toggleButton.action = #selector(toggle)

        for view in [caption, toggleButton, time, detail, progress] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            caption.centerYAnchor.constraint(equalTo: toggleButton.centerYAnchor),
            toggleButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            toggleButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            time.leadingAnchor.constraint(equalTo: caption.leadingAnchor, constant: -2),
            time.topAnchor.constraint(equalTo: toggleButton.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            detail.topAnchor.constraint(equalTo: time.bottomAnchor, constant: -2),
            progress.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            progress.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            progress.heightAnchor.constraint(equalToConstant: CatTrack.height),
        ])
        self.panel = panel
        refresh()
    }

    @objc private func positionPanel() {
        guard let panel, let frame = NSScreen.screens.first?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - Self.size.width - Self.margin,
            y: frame.maxY - Self.size.height - Self.margin
        ))
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A hairline progress bar with a small cat. During focus the cat walks
/// toward the break; during a break it naps at the end; paused, it sits.
private final class CatTrack: NSView {
    enum Mood { case sitting, walking, sleeping }

    static let height: CGFloat = 26
    private static let catSize: CGFloat = 20
    private static let lineHeight: CGFloat = 3

    var fraction: Double = 0 {
        didSet { if fraction != oldValue { needsDisplay = true; needsLayout = true } }
    }

    var mood: Mood = .sitting {
        didSet { if mood != oldValue { needsDisplay = true; needsLayout = true; animate() } }
    }

    private let cat = CALayer()
    private let snore = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        cat.bounds = NSRect(x: 0, y: 0, width: Self.catSize, height: Self.catSize)
        // Rotate around the paws so the walk reads as a waddle, not a spin.
        cat.anchorPoint = NSPoint(x: 0.5, y: 0)
        snore.string = "z"
        snore.fontSize = 10
        snore.alignmentMode = .center
        snore.bounds = NSRect(x: 0, y: 0, width: 10, height: 14)
        snore.opacity = 0
        layer?.addSublayer(cat)
        layer?.addSublayer(snore)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        cat.contentsScale = scale
        snore.contentsScale = scale
        updateCatImage()
        updateSnoreColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSnoreColor()
    }

    private func updateSnoreColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            snore.foregroundColor = NSColor.secondaryLabelColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cat.position = NSPoint(x: catCenterX, y: Self.lineHeight)
        snore.position = NSPoint(x: catCenterX + Self.catSize / 2, y: Self.lineHeight + Self.catSize)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: 0, width: bounds.width, height: Self.lineHeight)
        let radius = Self.lineHeight / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        var filled = track
        filled.size.width *= min(max(fraction, 0), 1)
        guard filled.width > 0 else { return }
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    private var catCenterX: CGFloat {
        let half = Self.catSize / 2
        // Napping happens at the finish line; otherwise the cat marks progress.
        let along = mood == .sleeping ? 1 : min(max(fraction, 0), 1)
        return half + along * max(bounds.width - Self.catSize, 0)
    }

    private func updateCatImage() {
        let scale = cat.contentsScale
        // Apple's cat faces left; mirror it so it walks toward the break.
        let image = NSImage(size: cat.bounds.size, flipped: false) { rect in
            let flip = NSAffineTransform()
            flip.translateX(by: rect.width, yBy: 0)
            flip.scaleX(by: -1, yBy: 1)
            flip.concat()
            let text = NSAttributedString(string: "🐈", attributes: [.font: NSFont.systemFont(ofSize: rect.height * 0.8)])
            let size = text.size()
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2 - 1))
            return true
        }
        cat.contents = image.layerContents(forContentsScale: scale)
    }

    private func animate() {
        cat.removeAllAnimations()
        snore.removeAllAnimations()
        switch mood {
        case .sitting:
            break
        case .walking:
            let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
            bob.values = [0, 1.5, 0, 1.5, 0]
            let waddle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            waddle.values = [0.06, -0.06, 0.06].map { $0 as NSNumber }
            let step = CAAnimationGroup()
            step.animations = [bob, waddle]
            step.duration = 0.9
            step.repeatCount = .infinity
            cat.add(step, forKey: "walk")
        case .sleeping:
            let breathe = CABasicAnimation(keyPath: "transform.scale.y")
            breathe.fromValue = 1
            breathe.toValue = 0.92
            breathe.duration = 1.4
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            cat.add(breathe, forKey: "breathe")
            let rise = CAKeyframeAnimation(keyPath: "transform.translation")
            rise.values = [NSValue(size: .zero), NSValue(size: NSSize(width: 6, height: 10))]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 0]
            let float = CAAnimationGroup()
            float.animations = [rise, fade]
            float.duration = 1.8
            float.repeatCount = .infinity
            snore.add(float, forKey: "snore")
        }
    }
}
