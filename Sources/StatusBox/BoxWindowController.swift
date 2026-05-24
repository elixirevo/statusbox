import AppKit
import CoreGraphics

final class BoxWindowController {
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let settingsStore: SettingsStore
    var onForwardedClick: ((NSPoint, CGMouseButton) -> Void)?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func show(anchorFrame: NSRect, rangeRect: NSRect, screen: NSScreen, captureResult: ScreenCapture.CaptureResult) {
        close()

        let image = captureResult.image
        let scale = screen.backingScaleFactor
        let imagePointSize = image.map {
            NSSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale)
        } ?? NSSize(width: max(160, rangeRect.width), height: max(24, rangeRect.height))

        let padding: CGFloat = 10
        let maxWidth = min(screen.visibleFrame.width - 24, max(180, rangeRect.width + padding * 2))
        let width = min(maxWidth, max(180, imagePointSize.width + padding * 2))
        let rowHeight: CGFloat = max(28, CGFloat(settingsStore.settings.boxIconSize) + 10)
        let rows = CGFloat(max(1, settingsStore.settings.boxMaxRows))
        let height: CGFloat = min(rowHeight * rows + padding * 2, max(54, imagePointSize.height + padding * 2))

        let proposed = NSRect(
            x: anchorFrame.midX - width / 2,
            y: MenuBarGeometry.menuBarRect(for: screen).minY - height - 6,
            width: width,
            height: height
        )
        let frame = MenuBarGeometry.clamp(proposed, to: screen.visibleFrame.insetBy(dx: 8, dy: 8))

        let panel = FloatingPanel(contentRect: frame)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 3)
        panel.collectionBehavior = NSWindow.CollectionBehavior([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
        panel.backgroundColor = NSColor.clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let content = IconStripView(frame: NSRect(origin: .zero, size: frame.size))
        content.image = image
        content.placeholderText = captureResult.placeholderText
        content.rangeRect = rangeRect
        content.onClick = { [weak self] (point: NSPoint, button: CGMouseButton) in
            self?.close()
            self?.onForwardedClick?(point, button)
        }
        panel.contentView = content
        panel.makeKeyAndOrderFront(nil as Any?)
        self.panel = panel

        installDismissMonitors(panel: panel)
    }

    func close() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    private func installDismissMonitors(panel: NSPanel) {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            guard let panel else { return event }
            if event.window !== panel {
                self?.close()
            }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }
}

final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class IconStripView: NSView {
    var image: CGImage?
    var placeholderText = "메뉴 막대 이미지를 가져올 수 없습니다"
    var rangeRect: NSRect = .zero
    var onClick: ((NSPoint, CGMouseButton) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        bounds.fill()

        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()

        guard let image else {
            drawPlaceholder()
            return
        }

        let imageSize = NSSize(width: image.width, height: image.height)
        let scale = min((bounds.width - 20) / max(1, imageSize.width), (bounds.height - 20) / max(1, imageSize.height))
        let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = NSRect(
            x: bounds.midX - drawSize.width / 2,
            y: bounds.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: drawRect)
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        forward(event: event, button: .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        forward(event: event, button: .right)
    }

    private func forward(event: NSEvent, button: CGMouseButton) {
        guard rangeRect.width > 0, rangeRect.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let xRatio = max(0, min(1, point.x / max(1, bounds.width)))
        let yRatio = max(0, min(1, point.y / max(1, bounds.height)))
        let screenPoint = NSPoint(
            x: rangeRect.minX + xRatio * rangeRect.width,
            y: rangeRect.maxY - yRatio * rangeRect.height
        )
        onClick?(screenPoint, button)
    }

    private func drawPlaceholder() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .paragraphStyle: paragraph
        ]
        placeholderText.draw(in: bounds.insetBy(dx: 12, dy: bounds.height / 2 - 8), withAttributes: attrs)
    }
}
