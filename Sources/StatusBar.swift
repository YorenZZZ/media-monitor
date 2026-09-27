import AppKit
import QuartzCore

/// Status item content: an icon plus the playing title, scrolling like a marquee when it does not fit.
/// Clicks pass through to the underlying NSStatusBarButton.
final class MarqueeStatusView: NSView {
    static let maxTextWidth: CGFloat = 150
    private static let iconSize: CGFloat = 16
    private static let gap: CGFloat = 36          // space between the end of the text and its repeat
    private static let speed: CGFloat = 28        // points per second
    private static let hold: CFTimeInterval = 1.6 // pause at the start of each loop

    private(set) var text: String?
    private(set) var playing = false
    private let iconLayer = CALayer()
    private let clipLayer = CALayer()
    private let scrollLayer = CALayer()
    private let fadeMask = CAGradientLayer()

    // While playing, the icon is the popover's equalizer bars, bouncing.
    private static let barCount = 4
    private static let barHeight: CGFloat = 13
    private let barLayers = (0..<MarqueeStatusView.barCount).map { _ in CALayer() }
    private var barTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(iconLayer)
        barLayers.forEach { iconLayer.addSublayer($0) }
        clipLayer.masksToBounds = true
        clipLayer.addSublayer(scrollLayer)
        layer?.addSublayer(clipLayer)
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
    }

    private func setBars(animating: Bool) {
        guard animating != (barTimer != nil) else { return }
        if animating {
            let timer = Timer(timeInterval: 1.0 / 24, repeats: true) { [weak self] _ in self?.layoutBars() }
            RunLoop.main.add(timer, forMode: .common)
            barTimer = timer
        } else {
            barTimer?.invalidate(); barTimer = nil
        }
    }

    /// Same motion as `EqualizerBars` in the popover.
    private func layoutBars() {
        let t = Date.timeIntervalSinceReferenceDate
        let spacing: CGFloat = 2
        let width = (Self.iconSize - spacing * CGFloat(Self.barCount - 1)) / CGFloat(Self.barCount)
        let bottom = (Self.iconSize + Self.barHeight) / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            let phase = t * (3.2 + Double(i) * 0.9) + Double(i) * 1.7
            let level = CGFloat(0.3 + 0.7 * abs(sin(phase) * cos(phase * 0.37)))
            let h = Self.barHeight * level
            bar.frame = CGRect(x: CGFloat(i) * (width + spacing), y: bottom - h, width: width, height: h)
            bar.cornerRadius = width / 2
        }
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    /// Width the status item needs for the current content.
    var preferredWidth: CGFloat {
        guard let text, !text.isEmpty else { return 26 }
        return 8 + Self.iconSize + 6 + min(textWidth(text), Self.maxTextWidth) + 8
    }

    func update(text newText: String?, playing newPlaying: Bool) {
        guard newText != text || newPlaying != playing else { return }
        text = newText; playing = newPlaying
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); rebuild() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); rebuild() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); rebuild() }
    override func layout() { super.layout(); rebuild() }

    private var font: NSFont { .systemFont(ofSize: 13, weight: .medium) }

    private func textWidth(_ s: String) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    private func rebuild() {
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Resolve labelColor for the menu bar's current (light/dark/tinted) appearance.
        var color = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }

        // Icon: bouncing bars while playing, a note otherwise.
        let hasText = !(text ?? "").isEmpty
        let iconX: CGFloat = hasText ? 8 : (bounds.width - Self.iconSize) / 2
        iconLayer.frame = CGRect(x: iconX, y: (bounds.height - Self.iconSize) / 2, width: Self.iconSize, height: Self.iconSize)
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = scale
        barLayers.forEach { $0.backgroundColor = color; $0.isHidden = !playing }
        if playing {
            iconLayer.contents = nil
            layoutBars()
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            iconLayer.contents = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(config).map { tinted($0, color: color, scale: scale) }
        }
        setBars(animating: playing && window != nil)

        // Text
        scrollLayer.removeAllAnimations()
        scrollLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        clipLayer.mask = nil
        guard let text, hasText else { clipLayer.frame = .zero; return }

        let width = textWidth(text)
        let visible = min(width, Self.maxTextWidth)
        let x = 8 + Self.iconSize + 6
        clipLayer.frame = CGRect(x: x, y: 0, width: visible, height: bounds.height)
        guard let image = renderText(text, width: width, color: color, scale: scale) else { return }
        let height = image.size.height
        let copies = width > Self.maxTextWidth ? 2 : 1
        for i in 0..<copies {
            let l = CALayer()
            l.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            l.contentsScale = scale
            l.frame = CGRect(x: CGFloat(i) * (width + Self.gap), y: (bounds.height - height) / 2, width: width, height: height)
            scrollLayer.addSublayer(l)
        }
        scrollLayer.frame = CGRect(x: 0, y: 0, width: width * 2 + Self.gap, height: bounds.height)

        guard copies == 2 else { return }
        // Soft edges so text slides in and out instead of being cut.
        fadeMask.frame = clipLayer.bounds
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fadeMask.locations = [0, 0.08, 0.9, 1]
        clipLayer.mask = fadeMask

        let distance = width + Self.gap
        let travel = CFTimeInterval(distance / Self.speed)
        let total = travel + Self.hold
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, 0, -distance]
        anim.keyTimes = [0, NSNumber(value: Self.hold / total), 1]
        anim.duration = total
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        scrollLayer.add(anim, forKey: "marquee")
    }

    private func renderText(_ s: String, width: CGFloat, color: CGColor, scale: CGFloat) -> NSImage? {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .labelColor]
        let size = NSSize(width: width, height: ceil(font.ascender - font.descender + 2))
        return NSImage(size: size, flipped: false) { _ in
            (s as NSString).draw(at: NSPoint(x: 0, y: 1), withAttributes: attributes)
            return true
        }
    }

    private func tinted(_ image: NSImage, color: CGColor, scale: CGFloat) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            (NSColor(cgColor: color) ?? .labelColor).set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

final class StatusBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 26)
    private let marquee = MarqueeStatusView(frame: .zero)
    private var pendingWidth: CGFloat?
    var isPopoverShown = false { didSet { if !isPopoverShown { applyPendingWidth() } } }

    var button: NSStatusBarButton? { statusItem.button }

    init(target: AnyObject, action: Selector) {
        guard let button = statusItem.button else { return }
        button.target = target
        button.action = action
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("媒体监视器")
        marquee.frame = button.bounds
        marquee.autoresizingMask = [.width, .height]
        button.addSubview(marquee)
    }

    func show(_ item: MediaItem?) {
        let text = item?.marqueeText
        if text != marquee.text { button?.toolTip = text }
        marquee.update(text: text, playing: item != nil)
        let width = marquee.preferredWidth
        guard width != statusItem.length else { pendingWidth = nil; return }
        // Resizing while the popover is open would drag the popover sideways with its anchor.
        if isPopoverShown { pendingWidth = width } else { statusItem.length = width }
    }

    private func applyPendingWidth() {
        if let w = pendingWidth { statusItem.length = w; pendingWidth = nil }
    }
}
