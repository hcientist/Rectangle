/// CursorPieMenu.swift

import Cocoa
import Carbon.HIToolbox
import MASShortcut

/// A radial menu shown at the cursor. Flick the mouse toward a wedge, click it, or press an arrow
/// key to jump to the center of the neighboring display in that direction. Esc or a click elsewhere cancels.
final class CursorPieMenu {
    var onOpenChange: ((Bool) -> Void)?
    var isOpen: Bool { panel != nil }

    private static let size: CGFloat = 280
    private static let deadZone: CGFloat = 28
    private static let flickRadius: CGFloat = 120

    private var panel: NSPanel?
    private var view: CursorPieView?
    private var timer: Timer?
    private var anchor = NSPoint.zero
    private var targets: [CursorDirection: CursorDisplay] = [:]
    private var tempShortcuts: [MASShortcut] = []
    private var clickMonitor: Any?

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard !isOpen else { return }
        let displays = CursorDisplays.all()
        guard let source = CursorDisplays.display(at: CursorDisplays.cursorLocation, in: displays) else { return }
        targets = [:]
        for direction in CursorDirection.allCases {
            targets[direction] = CursorDisplays.neighbor(of: source, direction, in: displays)
        }

        anchor = NSEvent.mouseLocation
        let size = Self.size
        let panel = NSPanel(
            contentRect: NSRect(x: anchor.x - size / 2, y: anchor.y - size / 2, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let view = CursorPieView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.labels = targets.mapValues(\.name)
        view.onClick = { [weak self] in
            guard let self else { return }
            if let direction = self.view?.highlighted { self.commit(direction) } else { self.close() }
        }
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        self.view = view

        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.track() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Bare arrows and Esc only belong to the menu while it is open.
        for direction in CursorDirection.allCases {
            registerTemporary(keyCode: direction.keyCode) { [weak self] in self?.commit(direction) }
        }
        registerTemporary(keyCode: kVK_Escape) { [weak self] in self?.close() }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }

        onOpenChange?(true)
    }

    func close() {
        guard isOpen else { return }
        timer?.invalidate()
        timer = nil
        tempShortcuts.forEach { MASShortcutMonitor.shared()?.unregisterShortcut($0) }
        tempShortcuts.removeAll()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
        onOpenChange?(false)
    }

    private func registerTemporary(keyCode: Int, action: @escaping () -> Void) {
        let shortcut = MASShortcut(keyCode: keyCode, modifierFlags: [])
        if MASShortcutMonitor.shared()?.register(shortcut, withAction: action) == true {
            tempShortcuts.append(shortcut)
        }
    }

    private func track() {
        let m = NSEvent.mouseLocation
        let dx = m.x - anchor.x, dy = m.y - anchor.y
        let distance = hypot(dx, dy)

        var direction: CursorDirection?
        if distance >= Self.deadZone {
            direction = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .up : .down)
            if let d = direction, targets[d] == nil { direction = nil }
        }
        if view?.highlighted != direction {
            view?.highlighted = direction
            view?.needsDisplay = true
        }
        if let direction, distance >= Self.flickRadius {
            commit(direction)
        }
    }

    private func commit(_ direction: CursorDirection) {
        guard let target = targets[direction] else { return }
        close()
        CursorDisplays.warp(to: target.center)
    }
}

private final class CursorPieView: NSView {
    var labels: [CursorDirection: String] = [:]
    var highlighted: CursorDirection?
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let outer = bounds.width / 2 - 4
        let inner: CGFloat = 30
        let gap: CGFloat = 2

        for direction in CursorDirection.allCases {
            let mid = direction.angle
            let path = NSBezierPath()
            path.appendArc(withCenter: c, radius: outer, startAngle: mid - 45 + gap, endAngle: mid + 45 - gap)
            path.appendArc(withCenter: c, radius: inner, startAngle: mid + 45 - gap, endAngle: mid - 45 + gap, clockwise: true)
            path.close()

            let available = labels[direction] != nil
            let fill: NSColor = direction == highlighted
                ? .controlAccentColor
                : NSColor(white: 0.1, alpha: available ? 0.85 : 0.45)
            fill.setFill()
            path.fill()
            NSColor(white: 1, alpha: 0.15).setStroke()
            path.lineWidth = 1
            path.stroke()

            let radians = mid * .pi / 180
            let r = (inner + outer) / 2 + 6
            let labelCenter = NSPoint(x: c.x + r * cos(radians), y: c.y + r * sin(radians))
            drawLabel(direction.arrow, labels[direction] ?? "—", at: labelCenter, dimmed: !available)
        }
    }

    private func drawLabel(_ arrow: String, _ name: String, at center: NSPoint, dimmed: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let color = NSColor(white: 1, alpha: dimmed ? 0.4 : 0.95)
        let text = NSMutableAttributedString(
            string: arrow + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: color, .paragraphStyle: paragraph])
        text.append(NSAttributedString(
            string: name,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: color, .paragraphStyle: paragraph]))
        let width: CGFloat = 92
        let height = text.boundingRect(with: NSSize(width: width, height: 100), options: [.usesLineFragmentOrigin]).height
        text.draw(with: NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
