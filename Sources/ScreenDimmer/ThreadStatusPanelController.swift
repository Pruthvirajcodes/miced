import AppKit

/// T3 Code threads that are still in motion, as separate floating cards in
/// the top-right corner of the main display: a status dot on the left
/// (blue working, gray waiting, whether on background work or on you) and the
/// thread name with a short status on the right. Finished threads are not
/// shown; with nothing in motion the corner stays empty.
///
/// Each card sits on a faint 20% tint, with no blur and no shared background;
/// the text carries its own dark outline so it reads on light and dark
/// content alike. The card under the pointer deepens slightly and shows its
/// project and what it waits on. A few seconds after the pointer leaves the
/// corner, the text and tint soften; the dots stay. Clicks pass through and it never takes focus.
@MainActor
final class ThreadStatusPanelController: NSObject {
    private static let maxCards = 8
    private static let margin: CGFloat = 10
    private static let pollInterval: TimeInterval = 1.0 / 20
    /// The pointer counts as near within this distance of a card.
    private static let nearDistance: CGFloat = 28
    private static let softenAfter: TimeInterval = 3
    private static let healthID = "miced.t3-health"

    private let feed: T3ThreadFeed
    private var panel: NSPanel?
    private let host = NSView()
    private var cards: [String: ThreadCard] = [:]
    /// Card ids, top to bottom.
    private var order: [String] = []
    private var rows: [ThreadCard.Content] = []
    private var poll: Timer?
    private var clock: Timer?
    private var hoveredID: String?
    private var nearAt = Date()
    private var isSoft = false

    init(feed: T3ThreadFeed) {
        self.feed = feed
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(positionPanel),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func start() {
        install()
        feed.onChange = { [weak self] in self?.show($0) }
        show(feed.state)
        feed.start()
    }

    /// Builds the panel and puts it on screen, without a feed.
    func install() {
        buildPanel()
        panel?.orderFrontRegardless()
        // Elapsed times tick over once a minute; half that keeps them close.
        let clock = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshText() }
        }
        clock.tolerance = 5
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
    }

    func show(_ state: T3ThreadFeed.State) {
        let next: [ThreadCard.Content]
        switch state {
        case .connecting:
            // Not knowing yet is not news; keep whatever is shown.
            return
        case .offline(let reason):
            next = [.init(id: Self.healthID, title: "T3 offline", project: nil, light: nil,
                          detail: reason, note: nil, since: nil)]
        case .revoked:
            next = [.init(id: Self.healthID, title: "T3 access revoked", project: nil, light: nil,
                          detail: "Re-enable it in the Dim menu", note: nil, since: nil)]
        case .live(let threads):
            next = threads.prefix(Self.maxCards).map {
                .init(id: $0.id, title: $0.title, project: $0.project, light: $0.light,
                      detail: $0.detail, note: $0.note, since: $0.since)
            }
        }
        // Changes worth a glance bring the text back to full strength.
        let news = next.map(\.signature) != rows.map(\.signature)
        rows = next
        reconcile()
        if news { wake() }
        updatePolling()
    }

    // MARK: Cards

    private func reconcile() {
        let ids = rows.map(\.id)
        for id in order where !ids.contains(id) {
            cards.removeValue(forKey: id)?.remove(animated: animates)
        }
        var inserted = 0
        for (index, content) in rows.enumerated() {
            let target = cardOrigin(index)
            if let card = cards[content.id] {
                card.content = content
                card.move(to: target, animated: animates)
            } else {
                let card = ThreadCard(content: content, scale: panel?.backingScaleFactor ?? 2)
                card.setEmphasis(hovered: false, soft: isSoft, animated: false)
                host.addSubview(card.view)
                // Several at once (the first snapshot) arrive one after another.
                card.insert(at: target, animated: animates, delay: Double(inserted) * 0.05)
                inserted += 1
                cards[content.id] = card
            }
        }
        order = ids
        if let hoveredID, cards[hoveredID] == nil { self.hoveredID = nil }
        panel?.setAccessibilityLabel(rows.isEmpty ? "No T3 threads in motion"
            : rows.map { "\($0.title): \($0.detail)" }.joined(separator: "; "))
    }

    private func refreshText() {
        for card in cards.values { card.refreshText() }
    }

    private func cardOrigin(_ index: Int) -> CGPoint {
        let height = host.bounds.height
        return CGPoint(x: Self.margin,
                       y: height - Self.margin - CGFloat(index + 1) * ThreadCard.size.height
                           - CGFloat(index) * ThreadCard.gap)
    }

    private var animates: Bool { !ThreadCard.reduceMotion }

    @objc private func motionPreferenceChanged() {
        for card in cards.values { card.updatePulse() }
    }

    // MARK: Pointer

    /// The panel ignores the mouse, so the pointer is polled, and only while
    /// cards are showing.
    private func updatePolling() {
        if cards.isEmpty {
            poll?.invalidate()
            poll = nil
        } else if poll == nil {
            let poll = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollPointer() }
            }
            poll.tolerance = 0.02
            RunLoop.main.add(poll, forMode: .common)
            self.poll = poll
        }
    }

    private func pollPointer() {
        guard let panel else { return }
        let screenPoint = NSEvent.mouseLocation
        let point = CGPoint(x: screenPoint.x - panel.frame.minX, y: screenPoint.y - panel.frame.minY)
        let frames = order.compactMap { id in cards[id].map { (id, $0.view.frame) } }
        let hovered = frames.first { $0.1.contains(point) }?.0
        let near = frames.contains { $0.1.insetBy(dx: -Self.nearDistance, dy: -Self.nearDistance).contains(point) }
        if near { nearAt = Date() }
        let soft = !near && Date().timeIntervalSince(nearAt) >= Self.softenAfter
        guard hovered != hoveredID || soft != isSoft else { return }
        hoveredID = hovered
        isSoft = soft
        applyEmphasis(animated: true)
    }

    private func wake() {
        nearAt = Date()
        if isSoft {
            isSoft = false
            applyEmphasis(animated: true)
        }
    }

    private func applyEmphasis(animated: Bool) {
        for (id, card) in cards {
            card.setEmphasis(hovered: id == hoveredID, soft: isSoft, animated: animated)
        }
    }

    // MARK: Panel

    private func frame() -> NSRect {
        let size = NSSize(
            width: ThreadCard.size.width + Self.margin * 2,
            height: CGFloat(Self.maxCards) * (ThreadCard.size.height + ThreadCard.gap) + Self.margin * 2
        )
        // The first screen is the display with the menu bar. With the menu bar
        // set to hide, the visible frame reaches the top edge.
        let visible = NSScreen.screens.first?.visibleFrame ?? .zero
        #if QA_HARNESS
        let offset = QAHarness.panelOffset
        #else
        let offset = CGPoint.zero
        #endif
        return NSRect(x: visible.maxX - size.width + offset.x, y: visible.maxY - size.height + offset.y,
                      width: size.width, height: size.height)
    }

    @objc private func positionPanel() {
        guard let panel else { return }
        let target = frame()
        if panel.frame != target { panel.setFrame(target, display: true) }
    }

    private func buildPanel() {
        let panel = NSPanel(contentRect: frame(), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Above normal and full-screen windows; a revealed menu bar and the
        // break overlay still draw over it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Each card is its own faint tint; a window shadow would outline them all.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true

        host.wantsLayer = true
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.setAccessibilityLabel("T3 thread status")
        self.panel = panel
    }
}

/// One floating card: a dot, the thread name, and a status line, on a faint
/// tint that leaves whatever is behind it visible. The status line cross-fades to the project
/// and what the thread waits on when hovered.
@MainActor
private final class ThreadCard {
    struct Content: Equatable {
        let id: String
        let title: String
        let project: String?
        /// Nil for the connection health card, which gets a hollow dot.
        let light: ThreadStatusRow.Light?
        let detail: String
        let note: String?
        let since: Date?

        /// The parts whose change means something to the user (not the clock).
        var signature: String { "\(id)|\(light.map { "\($0)" } ?? "-")|\(detail)" }
    }

    static let size = CGSize(width: 288, height: 46)
    static let gap: CGFloat = 6

    // Opacity of the dark tint behind each card: at rest, softened, and
    // under the pointer.
    private static let tintRest: Float = 0.20
    private static let tintSoft: Float = 0.12
    private static let tintHover: Float = 0.28
    private static let textSoft: Float = 0.55

    private static let emphasisDuration = 0.22
    private static let softenDuration = 0.4
    private static let moveDuration = 0.38
    private static let ease = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.24, 1)
    private static let easeInOut = CAMediaTimingFunction(name: .easeInEaseOut)

    let view = NSView(frame: CGRect(origin: .zero, size: size))
    private var layer: CALayer { view.layer! }
    /// Holds the dot and text as plain layers, animated directly.
    private let overlay = NSView(frame: CGRect(origin: .zero, size: size))
    private let fill = CALayer()
    private let dot = CALayer()
    private let title = CATextLayer()
    private let detail = CATextLayer()
    private let hoverDetail = CATextLayer()
    private let text = CALayer()
    /// Wrap `text`, each adding a wider, softer dark halo around the glyphs.
    private let halos = [CALayer(), CALayer()]

    var content: Content {
        didSet { if content != oldValue { update() } }
    }

    init(content: Content, scale: CGFloat) {
        self.content = content
        view.wantsLayer = true
        let radius: CGFloat = 12
        overlay.layer = CALayer()
        overlay.wantsLayer = true
        view.addSubview(overlay)
        let layer = overlay.layer!
        fill.frame = layer.bounds
        fill.cornerRadius = radius
        fill.cornerCurve = .continuous
        fill.backgroundColor = NSColor.black.cgColor
        fill.opacity = Self.tintRest
        layer.addSublayer(fill)
        let rim = CALayer()
        rim.frame = layer.bounds
        rim.cornerRadius = radius
        rim.cornerCurve = .continuous
        rim.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        rim.borderWidth = 0.5
        layer.addSublayer(rim)

        let dotSize: CGFloat = 9
        dot.frame = CGRect(x: 15, y: 27.5 - dotSize / 2, width: dotSize, height: dotSize)
        dot.cornerRadius = dotSize / 2
        // A dark hairline keeps light dots visible on light backgrounds.
        dot.shadowColor = NSColor.black.cgColor
        dot.shadowOpacity = 0.9
        dot.shadowRadius = 1.2
        dot.shadowOffset = .zero
        layer.addSublayer(dot)

        let textX: CGFloat = 34
        let textWidth = Self.size.width - textX - 14
        configure(title, font: .systemFont(ofSize: 13, weight: .semibold), alpha: 1, scale: scale)
        title.frame = CGRect(x: textX, y: 19, width: textWidth, height: 18)
        for line in [detail, hoverDetail] {
            configure(line, font: .systemFont(ofSize: 11.5, weight: .medium), alpha: 0.88, scale: scale)
            line.frame = CGRect(x: textX, y: 5, width: textWidth, height: 15)
        }
        hoverDetail.opacity = 0
        text.frame = layer.bounds
        for line in [title, detail, hoverDetail] { text.addSublayer(line) }
        // White glyphs with a tight dark outline and softer halos around it:
        // the text reads on white pages without a heavy box behind it.
        var inner = text
        for (shadow, (radius, opacity)) in zip([text] + halos, [(1.2, 1.0), (3.0, 1.0), (7.0, 0.6)] as [(CGFloat, Float)]) {
            shadow.frame = layer.bounds
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowRadius = radius
            shadow.shadowOpacity = opacity
            shadow.shadowOffset = .zero
            if shadow !== text { shadow.addSublayer(inner) }
            inner = shadow
        }
        layer.addSublayer(inner)
        update()
    }

    private func configure(_ layer: CATextLayer, font: NSFont, alpha: CGFloat, scale: CGFloat) {
        layer.font = font
        layer.fontSize = font.pointSize
        layer.foregroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        layer.truncationMode = .end
        layer.isWrapped = false
        layer.contentsScale = scale
        layer.actions = ["contents": NSNull()]
    }

    private func update() {
        title.string = content.title
        refreshText()
        let color: NSColor = switch content.light {
        case .working: NSColor(srgbRed: 0.30, green: 0.62, blue: 1.0, alpha: 1)
        // Needs you is waiting too: gray, sorted first, its status line says why.
        case .waiting, .needsYou, nil: NSColor(white: 0.80, alpha: 1)
        }
        let hollow = content.light == nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        dot.backgroundColor = hollow ? NSColor.clear.cgColor : color.cgColor
        dot.borderColor = color.cgColor
        dot.borderWidth = hollow ? 1.5 : 0
        CATransaction.commit()
        updatePulse()
    }

    func refreshText() {
        let elapsed = content.since.flatMap(Self.elapsed)
        detail.string = [content.detail, elapsed].compactMap { $0 }.joined(separator: " · ")
        let what = content.note ?? (elapsed.map { "\(content.detail) for \($0)" } ?? content.detail)
        hoverDetail.string = [content.project, what].compactMap { $0 }.joined(separator: " · ")
    }

    private static func elapsed(since: Date) -> String? {
        let minutes = Int(Date().timeIntervalSince(since) / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// A slow breath tells working apart at a glance. Not with Reduce Motion.
    func updatePulse() {
        let pulse = content.light == .working && !Self.reduceMotion
        if pulse, dot.animation(forKey: "pulse") == nil {
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = 1
            breath.toValue = 0.4
            breath.duration = 1.1
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = Self.easeInOut
            dot.add(breath, forKey: "pulse")
        } else if !pulse {
            dot.removeAnimation(forKey: "pulse")
        }
    }

    func setEmphasis(hovered: Bool, soft: Bool, animated: Bool) {
        let duration = animated ? (soft && !hovered ? Self.softenDuration : Self.emphasisDuration) : 0
        let timing = soft && !hovered ? Self.easeInOut : Self.ease
        let tint = hovered ? Self.tintHover : soft ? Self.tintSoft : Self.tintRest
        Self.animate(fill, "opacity", to: tint, duration: duration, timing: timing)
        Self.animate(text, "opacity", to: soft && !hovered ? Self.textSoft : 1, duration: duration, timing: timing)
        Self.animate(detail, "opacity", to: hovered ? 0 : 1, duration: duration, timing: timing)
        Self.animate(hoverDetail, "opacity", to: hovered ? 1 : 0, duration: duration, timing: timing)
    }

    static var reduceMotion: Bool {
        #if QA_HARNESS
        if let forced = QAHarness.reduceMotion { return forced }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The card's on-screen position and opacity right now, mid-animation or not.
    private var shown: (position: CGPoint, opacity: Float) {
        let shown = layer.presentation() ?? layer
        return (shown.position, shown.opacity)
    }

    /// Sets the view's real origin and opacity (AppKit owns the backing layer)
    /// without implicit animation, and returns the layer's new position.
    @discardableResult
    private func place(_ origin: CGPoint, alpha: CGFloat? = nil) -> CGPoint {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.setFrameOrigin(origin)
        if let alpha { view.alphaValue = alpha }
        CATransaction.commit()
        return layer.position
    }

    func move(to origin: CGPoint, animated: Bool) {
        guard view.frame.origin != origin else { return }
        let (from, opacity) = shown
        let to = place(origin)
        if animated {
            Self.run(layer, "position", from: from, to: to, duration: Self.moveDuration, timing: Self.ease)
            return
        }
        // Reduce Motion: dissolve out of the old place and into the new one.
        let dissolve = CAKeyframeAnimation(keyPath: "opacity")
        dissolve.values = [opacity, 0, 1]
        dissolve.keyTimes = [0, 0.5, 1]
        dissolve.duration = 0.3
        let jump = CAKeyframeAnimation(keyPath: "position")
        jump.values = [from, to]
        jump.keyTimes = [0, 0.5]
        jump.calculationMode = .discrete
        jump.duration = 0.3
        layer.add(dissolve, forKey: "opacity")
        layer.add(jump, forKey: "position")
    }

    /// Slides in a few points from the right edge while fading in. With
    /// Reduce Motion, only fades.
    func insert(at origin: CGPoint, animated: Bool, delay: Double) {
        let to = place(origin, alpha: 1)
        Self.run(layer, "opacity", from: Float(0), to: Float(1), duration: animated ? 0.3 : 0.2,
                 timing: Self.easeInOut, delay: animated ? delay : 0)
        if animated {
            Self.run(layer, "position", from: CGPoint(x: to.x + 14, y: to.y), to: to,
                     duration: Self.moveDuration, timing: Self.ease, delay: delay)
        }
    }

    func remove(animated: Bool) {
        let view = view
        let (from, opacity) = shown
        let duration = animated ? 0.28 : 0.15
        CATransaction.begin()
        CATransaction.setCompletionBlock { view.removeFromSuperview() }
        let to = place(CGPoint(x: view.frame.minX + (animated ? 14 : 0), y: view.frame.minY), alpha: 0)
        Self.run(layer, "opacity", from: opacity, to: Float(0), duration: duration, timing: Self.easeInOut)
        if animated {
            Self.run(layer, "position", from: from, to: to, duration: duration, timing: Self.easeInOut)
        }
        CATransaction.commit()
    }

    private static func run(_ layer: CALayer, _ key: String, from: Any, to: Any, duration: Double,
                            timing: CAMediaTimingFunction, delay: Double = 0) {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        if delay > 0 {
            animation.beginTime = CACurrentMediaTime() + delay
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: key)
    }

    private static func set(_ layer: CALayer, _ key: String, _ value: Any) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        CATransaction.commit()
    }

    /// Animates from wherever the layer is on screen now, so a change that
    /// interrupts another (the pointer passing quickly) never jumps.
    private static func animate(_ layer: CALayer, _ key: String, to value: Any, duration: Double,
                                timing: CAMediaTimingFunction) {
        let from = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        set(layer, key, value)
        guard duration > 0 else {
            layer.removeAnimation(forKey: key)
            return
        }
        run(layer, key, from: from as Any, to: value, duration: duration, timing: timing)
    }
}
