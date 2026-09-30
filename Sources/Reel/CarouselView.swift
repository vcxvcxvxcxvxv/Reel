import AppKit
import Carbon.HIToolbox
import QuartzCore

/// The picker: a horizontal strip of wallpaper slices. The centre tile is big, tiles shrink
/// towards the edges (smoothstep) and get pulled inwards (t⁴) — hyprquickpaper's maths —
/// driven by a display link that only runs while something is actually moving.
///
/// Smoothness rules:
/// • all motion is integrated once per display frame, never in event handlers, so input that
///   arrives at uneven times still produces perfectly even movement;
/// • holding an arrow key glides continuously instead of stepping on each key repeat;
/// • the trackpad is followed with a tiny frame-synced smoothing, and flicks carry their real
///   velocity into the snap;
/// • nothing is re-rendered while moving — layers are only repositioned.
final class CarouselView: NSView {
    var onApply: ((URL, CGRect) -> Void)?
    var onClosed: (() -> Void)?

    private let config: Config
    private let library: WallpaperLibrary
    private let items: [WallpaperLibrary.Item]
    private let backingScale: CGFloat
    private var metrics: Metrics
    private var spec: ThumbSpec

    private let backdrop = CAGradientLayer()
    private let stage = CALayer()
    private let titleLayer = CATextLayer()
    private var highlight: Highlight?
    private var tiles: [Int: Tile] = [:]
    private var pool: [Tile] = []
    private var emptyState: NSStackView?
    private var titleIndex = -1
    private var titleModeIndex = ""

    private var offset: CGFloat = 0
    private var velocity: CGFloat = 0
    private var target: CGFloat = 0
    private var snappy = false

    private var tracking = false
    private var trackGoal: CGFloat = 0
    private var samples: [(time: TimeInterval, position: CGFloat)] = []
    private var lastScrollWall: CFTimeInterval = 0
    private var awaitingMomentum = false
    private var snapToken = 0

    private var holdDirection = 0
    private var holdStart: CFTimeInterval = 0
    private var holding = false

    private var selected = 0
    private var mouseDriven = false

    private var appear: CGFloat = 0
    private var appearVelocity: CGFloat = 0
    private var appearTarget: CGFloat = 1
    private var closing = false
    private var finished = false
    private var chosen: Int?

    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var prefetchedRange: ClosedRange<Int>?
    private var lastPrefetchDirection = 0
    private var activeRange: ClosedRange<Int>?
    private var backdropOpacity: Float = -1

    private let trackFollowTime: CGFloat = 0.0018
    private let keyboardResponse: CGFloat = 0.10
    private let keyboardHoldDelay: CFTimeInterval = 0.050

    init(frame: NSRect, screen: NSScreen, config: Config, library: WallpaperLibrary,
         items: [WallpaperLibrary.Item], startIndex: Int) {
        self.config = config
        self.library = library
        self.items = items
        self.backingScale = screen.backingScaleFactor
        let m = Metrics(config: config, screen: screen)
        self.metrics = m
        self.spec = m.thumbSpec(config: config, backingScale: screen.backingScaleFactor)
        super.init(frame: frame)

        wantsLayer = true
        layer?.masksToBounds = true

        let dim = config.backdropDim
        backdrop.type = .radial
        backdrop.startPoint = CGPoint(x: 0.5, y: 0.5)
        backdrop.endPoint = CGPoint(x: 1, y: 1)
        backdrop.colors = [CGColor(gray: 0, alpha: dim * 0.7),
                           CGColor(gray: 0, alpha: dim == 0 ? 0 : min(0.92, dim * 1.5 + 0.15))]
        backdrop.opacity = 0
        backdrop.frame = bounds
        layer?.addSublayer(backdrop)

        stage.frame = bounds
        layer?.addSublayer(stage)

        titleLayer.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLayer.fontSize = 13
        titleLayer.foregroundColor = CGColor(gray: 1, alpha: 0.9)
        titleLayer.alignmentMode = .center
        titleLayer.truncationMode = .middle
        titleLayer.contentsScale = backingScale
        titleLayer.bounds = CGRect(x: 0, y: 0, width: max(180, m.baseSize.width * 1.5), height: 18)
        titleLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        titleLayer.shadowOpacity = 0.7
        titleLayer.shadowRadius = 4
        titleLayer.shadowOffset = .zero
        titleLayer.opacity = 0
        titleLayer.zPosition = 1000
        titleLayer.isHidden = !config.showTitle
        stage.addSublayer(titleLayer)

        if config.outlineEnabled {
            highlight = Highlight(config: config, size: m.baseSize, backingScale: backingScale)
        }

        selected = clampIndex(startIndex)
        offset = CGFloat(selected) * m.step
        target = offset

        if items.isEmpty { buildEmptyState() }
        preload()

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func start() {
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        if #available(macOS 14.0, *) {
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        }
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func dismiss() {
        guard !closing else { return }
        beginClosing()
    }

    private func beginClosing() {
        closing = true
        tracking = false
        awaitingMomentum = false
        holdDirection = 0
        holding = false
        appearTarget = 0
        window?.ignoresMouseEvents = true
        wake()
    }

    private func wake() { link?.isPaused = false }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        stage.frame = bounds
        CATransaction.commit()
    }

    private func preload() {
        guard items.count <= 40 else { return }
        for item in items where library.cachedThumbnail(item, spec: spec) == nil {
            library.requestThumbnail(item, spec: spec) { _ in }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = CGFloat(lastTick == 0 ? 1.0 / 60 : min(max(now - lastTick, 1.0 / 240), 1.0 / 30))
        lastTick = now
        let wall = CACurrentMediaTime()

        if holdDirection != 0 && wall - holdStart > keyboardHoldDelay {
            glide(dt: dt, held: wall - holdStart - keyboardHoldDelay)
        } else if tracking {
            let timeout: CFTimeInterval = awaitingMomentum ? 0.11 : 0.28
            if wall - lastScrollWall > timeout {
                finishTracking(velocity: trackpadVelocity(now: wall))
            } else {
                let previous = offset
                let alpha = 1 - exp(-dt / trackFollowTime)
                offset += (trackGoal - offset) * alpha
                velocity = (offset - previous) / dt
            }
        }
        if !tracking && !holding {
            let response = snappy ? keyboardResponse : 0.27
            Spring.step(&offset, &velocity, target: target, response: response, damping: 1.0, dt: dt, epsilon: 0.03)
        }

        let response = closing ? 0.27 : 0.50
        Spring.step(&appear, &appearVelocity, target: appearTarget, response: response, damping: 1.0, dt: dt, epsilon: 0.0005)

        if !closing {
            if mouseDriven, let win = window {
                hover(at: convert(win.mouseLocationOutsideOfEventStream, from: nil))
            } else if tracking || holding {
                selected = nearestIndex(offset)
            }
        }

        let settledTiles = layoutTiles(dt: dt)

        if closing {
            if !finished && appear < 0.012 {
                finished = true
                stop()
                onClosed?()
            }
            return
        }

        if !tracking && !holding && holdDirection == 0 && abs(offset - target) < 0.0001 && abs(velocity) < 0.0001
            && abs(appear - appearTarget) < 0.0001 && abs(appearVelocity) < 0.0001 && settledTiles {
            link.isPaused = true
            lastTick = 0
        }
    }

    private func glide(dt: CGFloat, held: CFTimeInterval) {
        guard !items.isEmpty, holdDirection != 0 else { return }
        let t = min(CGFloat(held), 1.5)
        let speed = min(13.0, 5.0 + 10.0 * (1 - exp(-t * 2.2)))
        offset = max(0, min(maxOffset, offset + CGFloat(holdDirection) * metrics.step * speed * dt))
        velocity = CGFloat(holdDirection) * metrics.step * speed
        selected = nearestIndex(offset)
        target = CGFloat(selected) * metrics.step
        updatePrefetchDirection(holdDirection)
    }

    private func nearestIndex(_ value: CGFloat) -> Int {
        guard metrics.step > 0 else { return 0 }
        return clampIndex(Int((value / metrics.step).rounded()))
    }

    private var maxOffset: CGFloat {
        CGFloat(max(0, items.count - 1)) * metrics.step
    }

    private func clampIndex(_ i: Int) -> Int {
        guard !items.isEmpty else { return 0 }
        return min(items.count - 1, max(0, i))
    }

    private func moveSelection(to index: Int) {
        guard !items.isEmpty else { return }
        mouseDriven = false
        tracking = false
        snappy = true
        selected = clampIndex(index)
        target = CGFloat(selected) * metrics.step
        wake()
    }

    private func finishTracking(velocity v: CGFloat) {
        tracking = false
        awaitingMomentum = false
        snappy = false
        let projected = trackGoal + v * 0.14
        let i = nearestIndex(projected)
        target = CGFloat(i) * metrics.step
        let outside = trackGoal < 0 || trackGoal > maxOffset
        velocity = outside ? v * 0.22 : v
        if !mouseDriven { selected = i }
        samples.removeAll(keepingCapacity: true)
        wake()
    }

    private func endHold() {
        holdDirection = 0
        guard holding else { return }
        holding = false
        snappy = true
        let projected = offset + velocity * 0.12
        let i = clampIndex(Int((projected / metrics.step).rounded()))
        selected = i
        target = CGFloat(i) * metrics.step
        wake()
    }

    private func trackpadVelocity(now: TimeInterval) -> CGFloat {
        let recent = samples.filter { now - $0.time <= 0.08 }
        guard recent.count >= 2, let first = recent.first, let last = recent.last, last.time > first.time else { return 0 }
        let meanT = recent.reduce(0) { $0 + $1.time } / Double(recent.count)
        let meanP = recent.reduce(0) { $0 + $1.position } / CGFloat(recent.count)
        var num: CGFloat = 0, den: CGFloat = 0
        for s in recent {
            let dt = CGFloat(s.time - meanT)
            num += dt * (s.position - meanP)
            den += dt * dt
        }
        guard den > 0 else { return 0 }
        return max(-9000, min(9000, num / den))
    }

    private func applySelected() {
        guard !closing, items.indices.contains(selected) else { return }
        let rect = tiles[selected]?.hitFrame
            ?? CGRect(x: bounds.midX - 60, y: bounds.midY - 60, width: 120, height: 120)
        let screenRect = window.map { $0.convertToScreen(convert(rect, to: nil)) } ?? rect
        chosen = selected
        beginClosing()
        onApply?(items[selected].url, screenRect)
    }

    override func mouseMoved(with event: NSEvent) {
        guard !closing else { return }
        mouseDriven = true
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard !closing else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let i = tileIndex(at: point) {
            selected = i
            applySelected()
        } else {
            dismiss()
        }
    }

    override func rightMouseUp(with event: NSEvent) { dismiss() }

    override func keyDown(with event: NSEvent) {
        guard !closing else { return }
        let key = Int(event.keyCode)
        let shift = event.modifierFlags.contains(.shift)
        switch key {
        case kVK_LeftArrow, kVK_ANSI_H, kVK_ANSI_A, kVK_RightArrow, kVK_ANSI_L, kVK_ANSI_D:
            guard !event.isARepeat else { return }
            let direction = [kVK_RightArrow, kVK_ANSI_L, kVK_ANSI_D].contains(key) ? 1 : -1
            if shift {
                moveSelection(to: selected + direction * 5)
            } else {
                moveSelection(to: selected + direction)
                holdDirection = direction
                holdStart = CACurrentMediaTime()
                holding = true
            }
        case kVK_Home, kVK_UpArrow:
            moveSelection(to: 0)
        case kVK_End, kVK_DownArrow:
            moveSelection(to: items.count - 1)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            applySelected()
        case kVK_Escape, kVK_ANSI_W, kVK_ANSI_Q:
            dismiss()
        default:
            break
        }
    }

    override func keyUp(with event: NSEvent) {
        let key = Int(event.keyCode)
        let direction = [kVK_RightArrow, kVK_ANSI_L, kVK_ANSI_D].contains(key) ? 1
            : [kVK_LeftArrow, kVK_ANSI_H, kVK_ANSI_A].contains(key) ? -1 : 0
        if direction != 0 && direction == holdDirection { endHold() }
    }

    override func scrollWheel(with event: NSEvent) {
        guard !closing, !items.isEmpty else { return }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let d = abs(dx) > abs(dy) ? dx : dy

        guard event.hasPreciseScrollingDeltas else {
            guard d != 0 else { return }
            let i = clampIndex(nearestIndex(target) + (d > 0 ? -1 : 1))
            let keepHover = mouseDriven
            moveSelection(to: i)
            mouseDriven = keepHover
            return
        }

        let now = CACurrentMediaTime()
        lastScrollWall = now

        if !event.momentumPhase.isEmpty {
            mouseDriven = false
            tracking = true
            awaitingMomentum = true
            snappy = false
        }

        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            mouseDriven = false
            tracking = true
            awaitingMomentum = false
            snappy = false
            trackGoal = offset
            velocity = 0
            samples.removeAll(keepingCapacity: true)
            snapToken += 1
        }

        if event.phase.contains(.began) || event.phase.contains(.changed) {
            mouseDriven = false
            tracking = true
            var delta = -d
            if (trackGoal < 0 && delta < 0) || (trackGoal > maxOffset && delta > 0) { delta *= 0.25 }
            trackGoal += delta
            samples.append((time: event.timestamp, position: trackGoal))
            if samples.count > 20 { samples.removeFirst(samples.count - 20) }
        }

        if event.momentumPhase.contains(.began) || event.momentumPhase.contains(.changed) {
            mouseDriven = false
            tracking = true
            var delta = -d
            if (trackGoal < 0 && delta < 0) || (trackGoal > maxOffset && delta > 0) { delta *= 0.25 }
            trackGoal += delta
            samples.append((time: event.timestamp, position: trackGoal))
            if samples.count > 20 { samples.removeFirst(samples.count - 20) }
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { awaitingMomentum = true }

        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            finishTracking(velocity: trackpadVelocity(now: event.timestamp))
        }

        if event.phase.isEmpty && event.momentumPhase.isEmpty {
            snappy = false
            target = max(0, min(maxOffset, target - d))
            snapToken += 1
            let token = snapToken
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 90_000_000)
                guard let self, self.snapToken == token, !self.closing else { return }
                let i = self.nearestIndex(self.target)
                self.target = CGFloat(i) * self.metrics.step
                if !self.mouseDriven { self.selected = i }
                self.wake()
            }
        }
        wake()
    }

    private func updatePrefetchDirection(_ direction: Int) {
        guard direction != 0 else { return }
        lastPrefetchDirection = direction
    }

    private func buildEmptyState() {
        let title = NSTextField(labelWithString: "No wallpapers yet")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = .white
        let hint = NSTextField(labelWithString: "Add images to this folder, or pick another one in Reel's Settings:")
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = NSColor(white: 0.7, alpha: 1)
        let path = NSTextField(labelWithString: config.folder.path)
        path.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        path.textColor = NSColor(white: 0.88, alpha: 1)
        path.isSelectable = true
        let stack = NSStackView(views: [title, hint, path])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.alphaValue = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
        emptyState = stack
    }
}
