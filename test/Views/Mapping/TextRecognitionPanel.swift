import ARKit
import SwiftUI

struct TextRecognitionPanel: View {
    let controller: LocalTextRecognitionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Local text recognition", systemImage: "text.viewfinder").font(.headline)
                Text(controller.status).font(.footnote).foregroundStyle(.secondary)
                Text("Text is marked automatically. Arrows describe the sign image; they do not prove a walkable route or a different floor.")
                    .font(.caption).foregroundStyle(.secondary)
                if let image = controller.latestImageJPEG {
                    AnnotatedTextImage(data: image, annotations: controller.latestAnnotations,
                                       signage: controller.latestDirectionalSignage)
                    .frame(maxHeight: 280)
                }
                SavedTextObservationsView(annotations: controller.annotations, signage: controller.directionalSignage)
            }
            .padding(12)
        }
    }
}

struct SavedTextObservationsView: View {
    let annotations: [SavedTextAnnotation]
    let signage: [SavedDirectionalSignage]
    @State private var selection: SavedTextAnnotation?
    @State private var selectedSign: SavedDirectionalSignage?
    @State private var searchText = ""
    @State private var exportURL: URL?
    @State private var showExport = false
    @State private var exportError: String?
    @State private var exporting = false
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            TextField("Find text or a sign", text: $searchText).textFieldStyle(.roundedBorder)
            Button {
                exporting = true
                let texts = annotations, signs = signage
                exportTask = Task {
                    do {
                        let url = try await Task.detached(priority: .utility) {
                            let data = try TextObservationExport.encode(annotations: texts, signage: signs)
                            let url = FileManager.default.temporaryDirectory
                                .appendingPathComponent("text-and-signs-\(UUID().uuidString).json")
                            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                            return url
                        }.value
                        guard !Task.isCancelled else {
                            try? FileManager.default.removeItem(at: url)
                            exporting = false
                            return
                        }
                        exportURL = url
                        showExport = true; exportError = nil
                    } catch { exportError = error.localizedDescription }
                    exporting = false
                }
            } label: { Label(exporting ? "Preparing data…" : "Export text & directions", systemImage: "square.and.arrow.up") }
            .disabled(exporting || annotations.isEmpty)
            if let exportError { Text(exportError).font(.caption).foregroundStyle(.orange) }
            Text("Text marks (\(annotations.count))").font(.headline)
            if annotations.isEmpty {
                Text("Point the camera at printed text. Recognized text appears here automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(annotations.filter { searchText.isEmpty || $0.text.localizedCaseInsensitiveContains(searchText) }.sorted { $0.lastSeen > $1.lastSeen }) { annotation in
                Button { selection = annotation } label: {
                    HStack(alignment: .top) {
                        Image(systemName: annotation.worldPosition == nil ? "photo" : "mappin.circle.fill")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(annotation.text).font(.body).foregroundStyle(.primary)
                            Text(annotation.worldPosition == nil ? "Image mark · location unconfirmed" : "Marked on the 3D map")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(Int(annotation.confidence * 100))% OCR confidence · \(annotation.observationCount) sightings")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .padding(10).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            Text("Directional signs (\(signage.count))").font(.headline).padding(.top, 8)
            if signage.isEmpty { Text("Nearby arrow detections will be listed separately here.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(signage.filter { searchText.isEmpty || $0.text.localizedCaseInsensitiveContains(searchText) }.sorted { $0.lastSeen > $1.lastSeen }) { sign in
                Button { selectedSign = sign } label: { HStack(alignment: .top) {
                    Text(sign.direction.symbol).font(.title2.bold()).foregroundStyle(.yellow)
                    VStack(alignment: .leading) {
                        Text(sign.text).font(.body)
                        Text("Arrow \(sign.direction.rawValue) in image · \(sign.source == .recognizedGlyph ? "text symbol" : "shape estimate") · \(Int(sign.confidence * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        }
        .sheet(item: $selection) { item in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(item.text).font(.title2)
                        if let data = item.evidenceJPEG {
                            AnnotatedTextImage(data: data, annotations: [item], signage: [])
                        }
                        Text("Recognized locally on \(item.lastSeen.formatted()). Review the image before using text or arrow estimates.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let position = item.worldPosition {
                            Text("Map position: \(position.x.formatted(.number.precision(.fractionLength(2)))), \(position.y.formatted(.number.precision(.fractionLength(2)))), \(position.z.formatted(.number.precision(.fractionLength(2)))) metres")
                                .font(.caption)
                        }
                    }.padding()
                }
                .navigationTitle("Text observation")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selection = nil } } }
            }
        }
        .sheet(item: $selectedSign) { sign in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(sign.text) · \(sign.direction.symbol)").font(.title2)
                        if let data = sign.evidenceJPEG {
                            AnnotatedTextImage(data: data, annotations: [], signage: [sign])
                        }
                        Text("Image-relative arrow: \(sign.direction.rawValue). Captured \(sign.lastSeen.formatted()). This is separate signage evidence, not a navigation edge.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding()
                }
                .navigationTitle("Directional sign")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedSign = nil } } }
            }
        }
        .sheet(isPresented: $showExport, onDismiss: {
            if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
            exportURL = nil
        }) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
        .onDisappear {
            if !showExport { exportTask?.cancel() }
        }
    }
}

struct AnnotatedTextImage: View {
    let data: Data
    let annotations: [SavedTextAnnotation]
    let signage: [SavedDirectionalSignage]

    var body: some View {
        if let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage).resizable().aspectRatio(contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        ForEach(annotations) { mark in
                            Rectangle().stroke(.yellow, lineWidth: 2)
                                .frame(width: CGFloat(mark.bounds.width) * proxy.size.width,
                                       height: CGFloat(mark.bounds.height) * proxy.size.height)
                                .position(x: mark.bounds.rect.midX * proxy.size.width,
                                          y: mark.bounds.rect.midY * proxy.size.height)
                        }
                        ForEach(signage) { sign in
                            Rectangle().stroke(.cyan, lineWidth: 2)
                                .frame(width: CGFloat(sign.arrowBounds.width) * proxy.size.width,
                                       height: CGFloat(sign.arrowBounds.height) * proxy.size.height)
                                .position(x: sign.arrowBounds.rect.midX * proxy.size.width,
                                          y: sign.arrowBounds.rect.midY * proxy.size.height)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Camera image with text marked in yellow and arrows in cyan")
        }
    }
}

struct LiveTextMarkers: View {
    @Environment(ARSessionManager.self) private var manager
    let controller: LocalTextRecognitionController

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                if let frame = manager.session.currentFrame, manager.isCurrentWorldFrame(frame) {
                    let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                        .first { $0.activationState == .foregroundActive }?.interfaceOrientation ?? .portrait
                    ForEach(controller.latestAnnotations) { annotation in
                        if let point = annotation.worldPosition {
                            let world = SIMD3<Float>(point.x, point.y, point.z)
                            let camera = frame.camera.transform.inverse * SIMD4<Float>(world, 1)
                            let screen = frame.camera.projectPoint(world, orientation: orientation, viewportSize: proxy.size)
                            if camera.z < 0, screen.x > 0, screen.x < proxy.size.width,
                               screen.y > 0, screen.y < proxy.size.height {
                                Text(annotation.text).font(.caption.bold()).lineLimit(2)
                                    .padding(5).foregroundStyle(.black).background(.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
                                    .frame(maxWidth: 140).position(screen)
                            }
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
