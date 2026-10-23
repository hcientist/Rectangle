/// CursorDisplays.swift

import Cocoa
import Carbon.HIToolbox
import CoreGraphics

enum CursorDirection: CaseIterable {
    case left, right, up, down

    /// Angle in Cocoa space (y up), degrees.
    var angle: CGFloat {
        switch self {
        case .right: return 0
        case .up: return 90
        case .left: return 180
        case .down: return 270
        }
    }

    var arrow: String {
        switch self {
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        }
    }

    var keyCode: Int {
        switch self {
        case .left: return kVK_LeftArrow
        case .right: return kVK_RightArrow
        case .up: return kVK_UpArrow
        case .down: return kVK_DownArrow
        }
    }
}

/// A display in global Quartz coordinates (origin at top-left of the primary display, y grows downward).
struct CursorDisplay: Equatable {
    let id: CGDirectDisplayID
    let frame: CGRect

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    var name: String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }
        return screen?.localizedName ?? "Display \(id)"
    }
}

enum CursorDisplays {
    static func all() -> [CursorDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count))
            // Skip secondary members of a mirror set; they share bounds with their primary.
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .map { CursorDisplay(id: $0, frame: CGDisplayBounds($0)) }
    }

    static var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func display(at point: CGPoint, in displays: [CursorDisplay]) -> CursorDisplay? {
        if let hit = displays.first(where: { $0.frame.contains(point) }) { return hit }
        // The cursor can sit exactly on a max edge; fall back to the nearest display.
        return displays.min { distance(point, $0.frame) < distance(point, $1.frame) }
    }

    static func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Re-associating removes the ~250ms input freeze that follows a warp.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// The display adjacent to `source` in `direction`. When nothing lies that way and `wrap` is set,
    /// returns the farthest display in the opposite direction that shares the same row/column.
    static func neighbor(of source: CursorDisplay, _ direction: CursorDirection, in displays: [CursorDisplay], wrap: Bool = true) -> CursorDisplay? {
        let s = CursorProjection(source.frame, direction)
        let others = displays.filter { $0.id != source.id }.map { ($0, CursorProjection($0.frame, direction)) }

        let ahead = others.filter { $0.1.lo >= s.hi - 1 }
        if let best = ahead.min(by: { score($0.1, s) < score($1.1, s) }) {
            return best.0
        }
        guard wrap else { return nil }

        let behind = others.filter { $0.1.hi <= s.lo + 1 && $0.1.overlap(s) > 1 }
        return behind.min { a, b in
            a.1.lo != b.1.lo ? a.1.lo < b.1.lo : abs(a.1.mid - s.mid) < abs(b.1.mid - s.mid)
        }?.0
    }

    private static func score(_ p: CursorProjection, _ s: CursorProjection) -> CGFloat {
        (p.lo - s.hi) + 2 * p.gap(s) + 0.01 * abs(p.mid - s.mid)
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}

/// A rect projected onto a direction: `lo...hi` along the direction of travel (larger is further ahead),
/// `plo...phi` along the perpendicular axis.
private struct CursorProjection {
    let lo, hi, plo, phi: CGFloat

    init(_ r: CGRect, _ direction: CursorDirection) {
        switch direction {
        case .right: (lo, hi, plo, phi) = (r.minX, r.maxX, r.minY, r.maxY)
        case .left: (lo, hi, plo, phi) = (-r.maxX, -r.minX, r.minY, r.maxY)
        case .down: (lo, hi, plo, phi) = (r.minY, r.maxY, r.minX, r.maxX)
        case .up: (lo, hi, plo, phi) = (-r.maxY, -r.minY, r.minX, r.maxX)
        }
    }

    var mid: CGFloat { (plo + phi) / 2 }

    func overlap(_ o: CursorProjection) -> CGFloat { min(phi, o.phi) - max(plo, o.plo) }

    func gap(_ o: CursorProjection) -> CGFloat { max(0, -overlap(o)) }
}
