//
//  NavigationMapView.swift
//  test
//
//  Developer view of Wearer Mode: the live obstacle map drawn top-down with the
//  user's heading pointing up, the walking corridor, the opening rays used for
//  "clearer to your left/right", and every alert transition with its latency.
//

import SwiftUI

struct NavigationMapView: View {
    @Environment(PerceptionSystem.self) private var perception
    private var navigation: NavigationEngine { perception.navigation }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                controls
                status
                mapCard
                transitionsCard
            }
            .padding(12)
        }
        .background(Theme.background)
    }

    // MARK: - Controls

    private var controls: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(navigation.running ? "Stop guidance" : "Start guidance") { navigation.toggle() }
                        .buttonStyle(.borderedProminent)
                        .tint(navigation.running ? Theme.bad : Theme.good)
                    Button("Describe") { navigation.describeSurroundings() }
                        .buttonStyle(.bordered).tint(Theme.accent)
                        .disabled(!navigation.running)
                    Spacer()
                }
                Toggle("Cane user (ground obstacles capped at NOTICE)", isOn: Binding(
                    get: { navigation.profile.caneUser }, set: { navigation.profile.caneUser = $0 }))
                HStack {
                    Toggle("Speech", isOn: Binding(get: { navigation.profile.speech },
                                                   set: { navigation.profile.speech = $0 }))
                    Toggle("Haptics", isOn: Binding(get: { navigation.profile.haptics },
                                                    set: { navigation.profile.haptics = $0 }))
                }
            }
            .font(.footnote)
            .tint(Theme.accent)
        }
    }

    // MARK: - Status

    private var status: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Stat(label: "Level", value: navigation.decision.level.title, tint: levelColor(navigation.decision.level))
                    Stat(label: "Sensing", value: navigation.sensing.rawValue,
                         tint: navigation.sensing == .ok ? Theme.good : Theme.warn)
                    Stat(label: "Speed", value: String(format: "%.2f m/s", navigation.speed))
                }
                HStack {
                    Stat(label: "Ahead", value: aheadText)
                    Stat(label: "Label", value: navigation.aheadLabel ?? "—")
                    Stat(label: "Phone height", value: phoneHeight)
                }
                HStack {
                    Stat(label: "Cells", value: "\(navigation.map.cells.count)")
                    Stat(label: "Compute", value: navigation.computeMs.map { String(format: "%.1f ms", $0) } ?? "—")
                    Stat(label: "Capture→decision", value: navigation.captureToDecisionMs.map { String(format: "%.0f ms", $0) } ?? "—")
                }
                if !navigation.lastSpoken.isEmpty {
                    Text("Last spoken: “\(navigation.lastSpoken)”")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var aheadText: String {
        guard let o = navigation.assessment?.ahead else { return "none" }
        return String(format: "%@ %.2f m", o.kind.rawValue, o.distance)
    }

    private var phoneHeight: String {
        guard let floorY = navigation.map.floorY, let user = navigation.user else { return "—" }
        return String(format: "%.2f m", user.position.y - floorY)
    }

    // MARK: - Map

    /// Metres shown ahead / behind / to each side.
    private let ahead: Float = 5, behind: Float = 1, side: Float = 3

    private var mapCard: some View {
        // Read observable state here, in body, so changes redraw the canvas.
        let map = navigation.map, user = navigation.user, assessment = navigation.assessment
        return Panel {
            VStack(alignment: .leading, spacing: 6) {
                Text("OBSTACLE MAP (heading up, 1 m grid)")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Canvas { context, size in
                    draw(in: &context, size: size, map: map, user: user, assessment: assessment)
                }
                    .aspectRatio(CGFloat(2 * side / (ahead + behind)), contentMode: .fit)
                    .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                Text("Green = floor seen · amber = ground obstacle · red = overhanging (cane misses) · white ring = obstacle in path · rays = free run per bearing (grey end = unmapped)")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize,
                      map: ObstacleMap, user: UserFrame?, assessment: PathAssessment?) {
        let scale = size.width / CGFloat(2 * side)
        func point(ahead a: Float, lateral l: Float) -> CGPoint {
            CGPoint(x: size.width / 2 + CGFloat(l) * scale, y: CGFloat(ahead - a) * scale)
        }

        // 1 m grid.
        var grid = Path()
        var m = -behind
        while m <= ahead {
            grid.move(to: point(ahead: m, lateral: -side)); grid.addLine(to: point(ahead: m, lateral: side))
            m += 1
        }
        var l = -side
        while l <= side {
            grid.move(to: point(ahead: -behind, lateral: l)); grid.addLine(to: point(ahead: ahead, lateral: l))
            l += 1
        }
        context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 0.5)

        guard let user else { return }
        let config = PathScannerConfig()
        let cellSide = CGFloat(map.config.cellSize) * scale

        for (key, state) in map.cells {
            let c = map.center(of: key)
            let (a, lat) = user.local(SIMD3<Float>(c.x, 0, c.y))
            guard a > -behind, a < ahead, abs(lat) < side else { continue }
            let color: Color
            if let bottom = state.bottom {
                if bottom >= config.headroom { color = .gray }
                else if bottom >= config.caneSweepHeight { color = Theme.bad }
                else { color = Theme.warn }
            } else {
                color = Theme.good.opacity(0.3)
            }
            let p = point(ahead: a, lateral: lat)
            context.fill(Path(CGRect(x: p.x - cellSide / 2, y: p.y - cellSide / 2, width: cellSide, height: cellSide)),
                         with: .color(color))
        }

        // Walking corridor.
        var corridor = Path()
        for x in [-config.corridorHalfWidth, config.corridorHalfWidth] {
            corridor.move(to: point(ahead: 0, lateral: x)); corridor.addLine(to: point(ahead: config.lookahead, lateral: x))
        }
        context.stroke(corridor, with: .color(Theme.accent.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

        // Opening rays.
        for o in assessment?.openings ?? [] {
            let r = o.bearingDegrees * .pi / 180
            let end = point(ahead: o.freeMeters * cos(r), lateral: o.freeMeters * sin(r))
            var ray = Path()
            ray.move(to: point(ahead: 0, lateral: 0)); ray.addLine(to: end)
            context.stroke(ray, with: .color(.white.opacity(0.25)), lineWidth: 1)
            let endColor: Color = o.end == .obstacle ? Theme.bad : (o.end == .clear ? Theme.good : .gray)
            context.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)), with: .color(endColor))
        }

        // Obstacle in path.
        if let o = assessment?.ahead {
            let (a, lat) = user.local(SIMD3<Float>(o.cellCenter.x, 0, o.cellCenter.y))
            let p = point(ahead: a, lateral: lat)
            context.stroke(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)),
                           with: .color(.white), lineWidth: 2)
        }

        // User.
        let u = point(ahead: 0, lateral: 0)
        var arrow = Path()
        arrow.move(to: CGPoint(x: u.x, y: u.y - 10))
        arrow.addLine(to: CGPoint(x: u.x - 6, y: u.y + 6))
        arrow.addLine(to: CGPoint(x: u.x + 6, y: u.y + 6))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(Theme.accent))
    }

    // MARK: - Transitions

    private var transitionsCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                Text("ALERT TRANSITIONS (newest first)")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                if navigation.transitions.isEmpty {
                    Text("None yet. Start guidance and walk toward something.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(navigation.transitions.prefix(15)) { t in
                    HStack(alignment: .firstTextBaseline) {
                        Text(t.sensing == .ok ? t.level.title : t.sensing.rawValue)
                            .font(.caption.bold())
                            .foregroundStyle(t.sensing == .ok ? levelColor(t.level) : Theme.warn)
                            .frame(width: 92, alignment: .leading)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(t.obstacle.map { String(format: "%@ %.2f m, %+.2f m lateral", $0.kind.rawValue, $0.distance, $0.lateral) } ?? "—")
                                .font(.caption2)
                            if let spoken = t.spoken {
                                Text("“\(spoken)”").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(t.captureToDecisionMs.map { String(format: "%.0f ms", $0) } ?? "")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func levelColor(_ level: AlertLevel) -> Color {
        switch level {
        case .clear: return Theme.good
        case .notice: return Theme.accent
        case .warning: return Theme.warn
        case .stop: return Theme.bad
        }
    }
}
