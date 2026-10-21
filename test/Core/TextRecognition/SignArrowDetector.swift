import Foundation
import CoreGraphics

/// Conservative local arrow heuristics. Unicode arrows are explicit evidence;
/// contours require the shaft, wider head, and tapered tip of a filled arrow.
/// Ambiguous/multi-headed/diagonal shapes deliberately produce no direction.
nonisolated enum SignArrowDetector {
    static func glyphDirections(in text: String) -> [SignArrowDirection] {
        let glyphs: [(SignArrowDirection, String)] = [(.up, "↑⬆⇧⇑"), (.down, "↓⬇⇩⇓"),
                                                     (.left, "←⬅⇦⇐"), (.right, "→➡⇨⇒")]
        return glyphs.compactMap { direction, symbols in
            text.contains(where: { symbols.contains($0) }) ? direction : nil
        }
    }

    static func classify(polygon: [CGPoint]) -> SignArrowDirection? {
        guard (7...40).contains(polygon.count), polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(),
              x1 - x0 > 0.005, y1 - y0 > 0.005 else { return nil }
        let width = x1 - x0, height = y1 - y0
        let p = polygon.map { CGPoint(x: ($0.x - x0) / width, y: ($0.y - y0) / height) }
        // Coordinates are top-left image coordinates: positive Y points down.
        var candidates: [SignArrowDirection] = []
        if width / height >= 1.15 && width / height <= 5 {
            if hasRightArrowProfile(p) { candidates.append(.right) }
            if hasRightArrowProfile(p.map { CGPoint(x: 1 - $0.x, y: $0.y) }) { candidates.append(.left) }
        }
        if height / width >= 1.15 && height / width <= 5 {
            if hasRightArrowProfile(p.map { CGPoint(x: $0.y, y: $0.x) }) { candidates.append(.down) }
            if hasRightArrowProfile(p.map { CGPoint(x: 1 - $0.y, y: $0.x) }) { candidates.append(.up) }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private static func hasRightArrowProfile(_ points: [CGPoint]) -> Bool {
        var widths: [CGFloat] = []
        var centers: [CGFloat] = []
        for sample in 0..<10 {
            let x = CGFloat(sample) * 0.1 + 0.05
            var intersections: [CGFloat] = []
            for index in points.indices {
                let a = points[index], b = points[(index + 1) % points.count]
                if (a.x <= x && b.x > x) || (b.x <= x && a.x > x) {
                    intersections.append(a.y + (CGFloat(x) - a.x) * (b.y - a.y) / (b.x - a.x))
                }
            }
            // A closed filled-arrow silhouette has one continuous cross-section.
            guard intersections.count == 2, let low = intersections.min(), let high = intersections.max() else { return false }
            widths.append(high - low); centers.append((high + low) / 2)
        }
        guard widths.count == 10 else { return false }
        let shaft = widths[1...3].reduce(0, +) / 3
        let head = widths[5...7].max() ?? 0
        return (0.12...0.55).contains(shaft) && head > shaft * 1.65 && head > 0.65 &&
            widths[0] > shaft * 0.75 && widths[9] < shaft * 0.75 &&
            widths[8] < head * 0.8 &&
            widths[1...3].allSatisfy { abs($0 - shaft) < 0.12 } &&
            centers.allSatisfy { abs($0 - 0.5) < 0.13 }
    }

    /// Association needs proximity, a shared row/column, and one clear winner.
    static func nearestText(to arrow: CGRect, texts: [CGRect]) -> Int? {
        let scores: [(Int, CGFloat)] = texts.enumerated().compactMap { index, text in
            guard !text.intersects(arrow) else { return nil }
            let sameRow = abs(text.midY - arrow.midY) <= max(text.height, arrow.height) * 0.75
            let sameColumn = abs(text.midX - arrow.midX) <= max(text.width, arrow.width) * 0.65
            let dx = max(0, max(text.minX - arrow.maxX, arrow.minX - text.maxX))
            let dy = max(0, max(text.minY - arrow.maxY, arrow.minY - text.maxY))
            guard (sameRow && dx <= max(text.height, arrow.height) * 4) ||
                  (sameColumn && dy <= max(text.height, arrow.height) * 2) else { return nil }
            return (index, sqrt(dx * dx + dy * dy))
        }.sorted { $0.1 < $1.1 }
        guard let first = scores.first else { return nil }
        if scores.count > 1 && scores[1].1 < first.1 * 1.4 + 0.015 { return nil }
        return first.0
    }
}
