//
//  LiveAICameraView.swift
//  test
//
//  Phase 1 — live camera + real YOLO26 instance segmentation overlay:
//  masks, labels, confidence, bounding boxes, plus model manager controls and
//  actual measured inference / end-to-end latency. Consumes the shared ARSession
//  (no second camera). Overlay alignment is awaiting on-device verification.
//

import SwiftUI

struct LiveAICameraView: View {
    @Environment(ARSessionManager.self) private var ar
    @Environment(PerceptionSystem.self) private var perception

    private var vision: VisionInferenceEngine { perception.vision }
    @State private var pipelineConsumer = UUID()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if ar.supportsWorldTracking {
                cameraWithOverlay
            }
            VStack(spacing: 8) {
                if ar.supportsWorldTracking {
                    detectionsBar
                } else {
                    Panel {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Live AI needs a camera device", systemImage: "camera.viewfinder")
                                .font(.headline)
                            Text("Run on your iPhone 15 Pro Max for live camera detections and segmentation. Model settings remain available here.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("vision.cameraUnavailable")
                }
                Spacer()
                controls
            }
            .padding(10)
        }
        .onAppear {
            vision.refreshModelPresence()
            perception.acquire(.vision, for: pipelineConsumer)
        }
        .onDisappear { perception.release(pipelineConsumer) }
    }

    // MARK: - Camera + detection overlay

    private var cameraWithOverlay: some View {
        PerceptionCameraOverlay(manager: ar, mask: vision.latestResult?.combinedMask,
                                maskOpacity: vision.maskOpacity,
                                frameTimestamp: vision.latestResult?.frameTimestamp ?? 0) { transform, size in
            if let transform, let result = vision.latestResult {
                ForEach(result.objects) { obj in
                    if let rect = CameraOverlayGeometry.box(obj.boxNormalized, transform: transform) {
                        boxOverlay(obj, rect: rect)
                    }
                }
            }
        }
    }

    private func boxOverlay(_ obj: DetectedObject, rect: CGRect) -> some View {
        let color = Self.classColor(for: obj.label)
        let labelText = "\(obj.label) \(Int(obj.confidence * 100))%"
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(color, lineWidth: 2.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            Text(labelText)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(color.opacity(0.9))
                .foregroundStyle(.black)
                .fixedSize()
                // Anchor the label to the box's top-left, clamped on-screen.
                .position(x: rect.minX + 44, y: max(10, rect.minY - 9))
        }
    }

    private struct ClassGroup: Identifiable {
        var id: String { label }
        let label: String
        let count: Int
        let conf: Float
    }

    /// Groups the current detections by class with count + top confidence.
    private func detectionGroups() -> [ClassGroup] {
        let objects = vision.latestResult?.objects ?? []
        var map: [String: (count: Int, conf: Float)] = [:]
        for o in objects {
            let cur = map[o.label] ?? (0, 0)
            map[o.label] = (cur.count + 1, Swift.max(cur.conf, o.confidence))
        }
        return map
            .map { ClassGroup(label: $0.key, count: $0.value.count, conf: $0.value.conf) }
            .sorted { $0.count == $1.count ? $0.conf > $1.conf : $0.count > $1.count }
    }

    /// Live readout of what the model currently sees, grouped by class.
    private var detectionsBar: some View {
        let groups = detectionGroups()
        return Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("DETECTING").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(groups.isEmpty ? "—" : "\(groups.count) classes")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                if groups.isEmpty {
                    Text(modelStatusText)
                        .font(.caption)
                        .foregroundStyle(modelStatusIsError ? Theme.bad : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(groups) { g in
                                HStack(spacing: 4) {
                                    Circle().fill(Self.classColor(for: g.label)).frame(width: 8, height: 8)
                                    Text(g.label).font(.system(size: 11, weight: .semibold))
                                    if g.count > 1 {
                                        Text("×\(g.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Text("\(Int(g.conf * 100))%")
                                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(Self.classColor(for: g.label).opacity(0.2), in: Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    /// Specific, actionable reason the overlay has no detections — never a vague
    /// "model not running". Tells the user (and us) exactly what to fix.
    private var modelStatusText: String {
        switch vision.loadState {
        case .loaded:
            return ar.runState == .running ? "Model ready — point at people / objects…"
                                            : "Session paused — tap Start on the Camera tab"
        case .loading:
            return "Loading \(vision.selectedVariant.displayName)…"
        case .notLoaded:
            return "Starting model…"
        case .missing:
            return "Model file not in this build — rebuild & reinstall (models live in test/Models)."
        case .sdkUnavailable:
            return "UltralyticsYOLO package not linked in this build — rebuild & reinstall."
        case .failed(let message):
            return "Model load failed: \(message)"
        }
    }

    private var modelStatusIsError: Bool {
        switch vision.loadState {
        case .missing, .sdkUnavailable, .failed: return true
        default: return false
        }
    }

    /// Deterministic per-class color so each label keeps a stable, distinct hue.
    static func classColor(for label: String) -> Color {
        var hasher = Hasher(); hasher.combine(label)
        let hue = Double(abs(hasher.finalize()) % 360) / 360.0
        return Color(hue: hue, saturation: 0.75, brightness: 0.95)
    }

    // MARK: - Controls / model manager

    private var controls: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Stat(label: "Inference", value: String(format: "%.1f ms", vision.measuredInferenceMs),
                         tint: Theme.accent)
                    Stat(label: "End-to-end", value: String(format: "%.1f ms", vision.measuredEndToEndMs))
                    Stat(label: "Rate", value: String(format: "%.1f Hz", vision.measuredRateHz))
                    Stat(label: "Objects", value: "\(vision.latestResult?.objects.count ?? 0)")
                }

                Picker("Model", selection: Binding(
                    get: { vision.selectedVariant },
                    set: { vision.switchModel(to: $0) })) {
                    ForEach(ModelVariant.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                loadStatusRow

                HStack {
                    Text("Conf").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { vision.confidenceThreshold },
                                          set: { vision.confidenceThreshold = $0 }), in: 0.1...0.9)
                    Text(String(format: "%.2f", vision.confidenceThreshold))
                        .font(Theme.mono).frame(width: 40)
                }
                HStack {
                    Text("Mask").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { vision.maskOpacity },
                                          set: { vision.maskOpacity = $0 }), in: 0...1)
                    Text(String(format: "%.0f%%", vision.maskOpacity * 100))
                        .font(Theme.mono).frame(width: 40)
                }
                HStack {
                    Text("Rate").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { vision.targetHz },
                                          set: { vision.targetHz = $0 }), in: 1...30, step: 1)
                    Text(String(format: "%.0f Hz", vision.targetHz))
                        .font(Theme.mono).frame(width: 50)
                }
                Picker("Compute", selection: Binding(
                    get: { vision.computeOption },
                    set: { vision.computeOption = $0; vision.loadSelectedModel() })) {
                    ForEach(ComputeUnitOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .font(.caption)

                Text(vision.selectedVariant.provenance)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .tint(Theme.accent)
        }
    }

    @ViewBuilder private var loadStatusRow: some View {
        HStack(spacing: 6) {
            switch vision.loadState {
            case .loaded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                Text("Model loaded").font(.caption)
            case .loading:
                ProgressView().scaleEffect(0.7)
                Text("Loading…").font(.caption)
            case .missing:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.bad)
                Text("Model file not bundled").font(.caption).foregroundStyle(Theme.bad)
            case .sdkUnavailable:
                Image(systemName: "shippingbox.fill").foregroundStyle(Theme.warn)
                Text("Add the UltralyticsYOLO Swift Package in Xcode").font(.caption).foregroundStyle(Theme.warn)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
                Text(msg).font(.caption2).foregroundStyle(Theme.bad).lineLimit(2)
            case .notLoaded:
                Image(systemName: "circle").foregroundStyle(.secondary)
                Text("Idle").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if vision.latestResult?.maskDegenerate == true {
                Text("⚠︎ empty mask tensor").font(.caption2).foregroundStyle(Theme.warn)
            }
        }
    }
}
