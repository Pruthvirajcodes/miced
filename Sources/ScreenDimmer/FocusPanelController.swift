import AppKit

/// A small always-on pill in the bottom-right corner of the main display.
/// Hovering grows it into a card with the timer, Focus/Break switch and pause.
@MainActor
final class FocusPanelController: NSObject {
    private static let pillSize = NSSize(width: 92, height: 30)
    private static let cardSize = NSSize(width: 252, height: 160)
    private static let margin: CGFloat = 12
    private static let expandDelay: TimeInterval = 0.12
    private static let collapseDelay: TimeInterval = 0.4

    private let clock: BreakClock
    private var panel: NSPanel?
    private var poll: Timer?
    private var isExpanded = false
    private var pointerChangedAt: Date?

    private let pill = NSView(frame: NSRect(origin: .zero, size: pillSize))
    private let pillIcon = NSTextField(labelWithString: "")
    private let pillTime = NSTextField(labelWithString: "")
    private let card = NSView(frame: NSRect(origin: .zero, size: cardSize))
    private let modePicker = NSSegmentedControl(labels: ["Focus", "Break"], trackingMode: .selectOne,
                                                target: nil, action: nil)
    private let pauseButton = NSButton()
    private let time = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let track = CatTrack()

    init(clock: BreakClock) {
        self.clock = clock
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(positionPanel),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func start() {
        buildPanel()
        positionPanel()
        panel?.orderFrontRegardless()
        // Reading the pointer position needs no privacy permission, whereas a
        // global mouse monitor received nothing when launched as a login item.
        poll = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPointer() }
        }
        poll?.tolerance = 0.05
        RunLoop.main.add(poll!, forMode: .common)
    }

    func refresh() {
        let left = formatClock(clock.remaining)
        let dim: NSColor = clock.isPaused ? .tertiaryLabelColor : .labelColor
        update(pillIcon, clock.isResting ? "💤" : "🐈")
        update(pillTime, left)
        update(time, left)
        update(detail, clock.isPaused ? "Paused"
            : clock.isResting ? "Look away from the screen"
            : "until a \(Int(clock.schedule.visibleDuration))-second break")
        pillTime.textColor = dim
        time.textColor = dim
        modePicker.selectedSegment = clock.phase == .rest ? 1 : 0
        let action = clock.isPaused ? "Resume" : "Pause"
        if pauseButton.toolTip != action {
            pauseButton.toolTip = action
            pauseButton.image = NSImage(systemSymbolName: clock.isPaused ? "play.fill" : "pause.fill",
                                        accessibilityDescription: action)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        }
        track.fraction = 1 - clock.remaining / clock.duration
        track.mood = clock.isPaused ? .sitting : clock.isResting ? .sleeping : .walking
    }

    private func update(_ field: NSTextField, _ text: String) {
        if field.stringValue != text { field.stringValue = text }
    }

    private func pollPointer() {
        refresh()
        guard let panel else { return }
        // A little slack around the open card so it does not snap shut at the edge.
        let hotArea = isExpanded ? panel.frame.insetBy(dx: -8, dy: -8) : panel.frame
        let inside = hotArea.contains(NSEvent.mouseLocation)
        guard inside != isExpanded else { pointerChangedAt = nil; return }
        guard let since = pointerChangedAt else { pointerChangedAt = Date(); return }
        if Date().timeIntervalSince(since) >= (inside ? Self.expandDelay : Self.collapseDelay) {
            pointerChangedAt = nil
            setExpanded(inside)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard let panel else { return }
        isExpanded = expanded
        // Hidden while collapsed, so the cat's animation is not drawn unseen.
        card.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame(expanded: expanded), display: true)
            pill.animator().alphaValue = expanded ? 0 : 1
            card.animator().alphaValue = expanded ? 1 : 0
        } completionHandler: {
            Task { @MainActor in self.card.isHidden = !self.isExpanded }
        }
    }

    private func frame(expanded: Bool) -> NSRect {
        let size = expanded ? Self.cardSize : Self.pillSize
        // The first screen is the display with the menu bar, independent of focus.
        let visible = NSScreen.screens.first?.visibleFrame ?? .zero
        return NSRect(x: visible.maxX - size.width - Self.margin, y: visible.minY + Self.margin,
                      width: size.width, height: size.height)
    }

    @objc private func positionPanel() {
        panel?.setFrame(frame(expanded: isExpanded), display: true)
    }

    @objc private func togglePause() { clock.togglePause() }

    @objc private func pickMode() {
        let wantsBreak = modePicker.selectedSegment == 1
        if wantsBreak == clock.isResting { return }
        if !wantsBreak && clock.isPaused { clock.resume() }
        else if wantsBreak { clock.startBreak() }
        else { clock.startFocus() }
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: frame(expanded: false),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        // Above the break overlay, so the time left stays visible during a break.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.pillSize))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.maskImage = Self.roundedMask(radius: Self.pillSize.height / 2)
        panel.contentView = root

        // Both layouts stay pinned to the bottom-right corner while the panel
        // grows up and to the left; the mask clips whichever is larger.
        for (view, size) in [(card, Self.cardSize), (pill, Self.pillSize)] {
            view.frame = NSRect(x: Self.pillSize.width - size.width, y: 0, width: size.width, height: size.height)
            view.autoresizingMask = [.minXMargin, .maxYMargin]
            root.addSubview(view)
        }
        card.alphaValue = 0
        card.isHidden = true

        pillIcon.font = .systemFont(ofSize: 13)
        pillTime.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        for view in [pillIcon, pillTime] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(view)
        }

        modePicker.controlSize = .small
        modePicker.target = self
        modePicker.action = #selector(pickMode)
        pauseButton.isBordered = false
        pauseButton.contentTintColor = .secondaryLabelColor
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        time.font = .monospacedDigitSystemFont(ofSize: 38, weight: .light)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        for view in [modePicker, pauseButton, time, detail, track] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }

        NSLayoutConstraint.activate([
            pillIcon.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 11),
            pillIcon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            pillTime.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -13),
            pillTime.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            modePicker.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            modePicker.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            pauseButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            pauseButton.centerYAnchor.constraint(equalTo: modePicker.centerYAnchor),
            pauseButton.widthAnchor.constraint(equalToConstant: 24),
            time.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            time.topAnchor.constraint(equalTo: modePicker.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            detail.topAnchor.constraint(equalTo: time.bottomAnchor, constant: -2),
            track.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            track.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            track.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            track.heightAnchor.constraint(equalToConstant: CatTrack.height),
        ])
        self.panel = panel
        refresh()
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
