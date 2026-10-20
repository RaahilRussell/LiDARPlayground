//
//  AIPlaceholders.swift
//  test
//
//  Placeholder screens for AI Perception tabs implemented in later phases.
//  Each is replaced by its real implementation as that phase lands.
//

import SwiftUI

struct BenchmarksView: View {
    var body: some View {
        ComingSoonView(title: "Benchmarks",
                       milestone: "n/s/m comparison, 60s profiler, frame-time graph, thermal, dropped frames — Phase 7.",
                       systemImage: "speedometer")
    }
}

struct PerceptionInspectorView: View {
    var body: some View {
        ComingSoonView(title: "Inspector",
                       milestone: "Raw frames, model outputs, spatial events, full latency breakdown, demo mode — Phase 8.",
                       systemImage: "scope")
    }
}
