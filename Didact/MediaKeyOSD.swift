
import AppKit

@MainActor
final class MediaKeyOSD {
    private let panel: NSPanel
    private let iconView = NSImageView()
    private let bar = SegmentBarView()
    private var hideTimer: Timer?
    private var fadeTimer: Timer?
    private var fadeStep = 0

    init() {
        let size = NSSize(width: 180, height: 56)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(iconView)
        effect.addSubview(bar)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            iconView.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            bar.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            bar.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            bar.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    func show(role: Control.Role, value: Int, min: Int, max: Int, muted: Bool, on screen: NSScreen) {
        let symbol: String
        switch role {
        case .brightness:
            symbol = "sun.max.fill"
        case .volume, .mute:
            symbol = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        }
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)

        let span = Swift.max(1, max - min)
        let fraction = Double(Swift.min(Swift.max(value, min), max) - min) / Double(span)
        bar.filled = muted ? 0 : Int((fraction * 16.0).rounded())

        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                     y: screen.visibleFrame.minY + 80))
        hideTimer?.invalidate()
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadeStep = 0
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTimer = Timer.scheduledTimer(timeInterval: 1.1, target: self,
                                         selector: #selector(fadeOut),
                                         userInfo: nil, repeats: false)
    }

    @objc private func fadeOut() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard panel.isVisible else { return }
        fadeStep = 0
        fadeTimer = Timer.scheduledTimer(timeInterval: 0.02, target: self,
                                         selector: #selector(fadeTick),
                                         userInfo: nil, repeats: true)
    }

    @objc private func fadeTick() {
        fadeStep += 1
        panel.alphaValue = Swift.max(0, 1 - CGFloat(fadeStep) / 10)
        if fadeStep >= 10 {
            fadeTimer?.invalidate()
            fadeTimer = nil
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    func hideImmediately() {
        hideTimer?.invalidate()
        hideTimer = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadeStep = 0
        panel.orderOut(nil)
        panel.alphaValue = 1
    }
}

private final class SegmentBarView: NSView {
    var filled: Int = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = 16
        let gap: CGFloat = 2
        let width = (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count)
        for index in 0..<count {
            let rect = NSRect(x: CGFloat(index) * (width + gap), y: 0,
                              width: width, height: bounds.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            let colour = index < filled
                ? NSColor.labelColor
                : NSColor.labelColor.withAlphaComponent(0.22)
            colour.setFill()
            path.fill()
        }
    }
}
