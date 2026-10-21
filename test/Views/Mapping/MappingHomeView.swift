import ARKit
import SwiftUI

/// Live reconstruction and the local library share one mapping coordinator.
/// Automatic foreground sensing continues while the library is visible.
struct MappingHomeView: View {
    @Environment(ARSessionManager.self) private var ar
    @Environment(MappingCoordinator.self) private var mapping
    @State private var section: MappingSection = .live
    @State private var mapName = ""
    @State private var showSaveName = false
    @State private var showNewMap = false
    @State private var pendingDelete: SavedMapMetadata?
    @State private var pendingRename: SavedMapMetadata?
    @State private var renameText = ""
    @State private var preview: MapPreview?
    @State private var referenceImageData: Data?

    private enum MappingSection: String, CaseIterable, Identifiable {
        case live = "Live Map", text = "Text & Signs", library = "Saved Places"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mapping view", selection: $section) {
                    ForEach(MappingSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(12)
                .disabled(mapping.isBusy)

                if let error = mapping.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.warn)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .accessibilityLabel("Mapping error: \(error)")
                }
                if mapping.isBusy {
                    ProgressView("Working with your map…")
                        .font(.footnote)
                        .padding(.bottom, 8)
                }

                switch section {
                case .live: liveMap
                case .text: TextRecognitionPanel(controller: mapping.textRecognition)
                case .library: library
                }
            }
            .background(Theme.background)
            .navigationTitle(section == .live ? "Map Your Space" : section.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await mapping.refreshLibrary()
            }
            .alert("Name this place", isPresented: $showSaveName) {
                TextField("Place name", text: $mapName)
                Button("Save") { Task { await mapping.saveMap(name: mapName) } }
                    .disabled(mapName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saves colored surfaces, photos, visited paths, destination labels, text marks, and localization data on this device.")
            }
            .confirmationDialog("Start a new map?", isPresented: $showNewMap, titleVisibility: .visible) {
                Button("Start New Map", role: .destructive) {
                    mapping.startNewMap()
                    referenceImageData = nil
                }
            } message: {
                Text("Unsaved scanning will be discarded. Your saved places remain in the library.")
            }
            .alert("Rename place", isPresented: Binding(
                get: { pendingRename != nil },
                set: { if !$0 { pendingRename = nil } })) {
                TextField("Place name", text: $renameText)
                Button("Rename") {
                    if let place = pendingRename {
                        Task { await mapping.renameMap(id: place.id, name: renameText) }
                    }
                    pendingRename = nil
                }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { pendingRename = nil }
            }
            .confirmationDialog("Delete saved place?", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete Place", role: .destructive) {
                    if let place = pendingDelete {
                        Task { await mapping.deleteMap(id: place.id) }
                    }
                    pendingDelete = nil
                }
            } message: {
                Text("This permanently removes the saved surfaces and localization data from this device.")
            }
            .sheet(item: $preview) { item in
                SavedPlaceDetailView(archive: item.archive) {
                    referenceImageData = item.archive.referenceImageData
                    preview = nil
                    // Select live first; resumeMap then installs the saved world
                    // map using the same session and a fresh generation.
                    section = .live
                    Task { await mapping.resumeMap(id: item.id) }
                }
            }
        }
    }

    private var liveMap: some View {
        VStack(spacing: 10) {
            if ar.supportsWorldTracking && ar.supportsMesh {
                MappingLiveSurfaceView()
                    .overlay { LiveTextMarkers(controller: mapping.textRecognition) }
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topLeading) {
                        Label(ar.runState == .running ? "LIVE RECONSTRUCTION" : ar.runState.rawValue.uppercased(),
                              systemImage: ar.runState == .running ? "record.circle" : "pause.circle")
                            .font(.caption.bold())
                            .padding(10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(10)
                    }
            } else {
                ContentUnavailableView("Live mapping needs LiDAR", systemImage: "camera.viewfinder",
                    description: Text("Run on your iPhone 15 Pro Max with camera access enabled. Saved places can still be viewed here."))
            }

            ScrollView {
                VStack(spacing: 10) {
                    mappingStatus
                    if ar.isRelocalizing { relocalizationHelp }
                    NavigationPanel(controller: mapping.navigation)
                    if let message = mapping.statusMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    controls
                    Text("Mapping, color capture, and local OCR run automatically while the app is active. Walk connected paths and label your destinations to enable return directions. Keep the phone facing the way you are traveling.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var mappingStatus: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text(mapping.activeMap?.name ?? "Automatically mapping this place")
                    .font(.headline)
                Text(mapping.automaticState).font(.footnote).foregroundStyle(.secondary)
                if let saved = mapping.lastSavedAt {
                    Text("Last saved \(saved.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if mapping.canDisplayRestoredGeometry {
                    Label("Saved place recognized", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(Theme.good)
                }
                HStack {
                    Stat(label: "Tracking", value: ar.trackingShort,
                         tint: ar.trackingIsNormal ? Theme.good : Theme.warn)
                    Stat(label: "Map quality", value: ar.worldMappingDescription)
                    Stat(label: "Surfaces", value: ar.meshFaceCount.formatted())
                }
                Label(ar.canSaveWorldMap ? "Automatic saving is ready" : "Scanning until tracking and map quality are ready",
                      systemImage: ar.canSaveWorldMap ? "checkmark.circle.fill" : "viewfinder")
                    .font(.caption)
                    .foregroundStyle(ar.canSaveWorldMap ? Theme.good : Theme.warn)
                if ar.meshVertexCount >= MapLimits.maxVertices * 4 / 5 || ar.meshFaceCount >= MapLimits.maxTriangles * 4 / 5 {
                    Text("The current segment is getting large. Automatic mapping will save it before continuing in a new segment.")
                        .font(.caption).foregroundStyle(Theme.warn)
                }
                if let error = ar.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(Theme.warn)
                }
            }
        }
    }

    private var relocalizationHelp: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Label("Finding your saved place", systemImage: "location.magnifyingglass")
                    .font(.headline)
                Text(ar.relocalizationGuidance)
                    .font(.footnote)
                if let data = mapping.referenceImageData ?? referenceImageData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 140)
                        .accessibilityLabel("Reference photo from the saved place")
                }
                Button("Cancel Revisit") {
                    mapping.cancelRelocalization()
                    referenceImageData = nil
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Button {
                if let place = mapping.activeMap {
                    Task { await mapping.saveMap(name: place.name) }
                } else {
                    mapName = "Place \(Date.now.formatted(date: .abbreviated, time: .shortened))"
                    showSaveName = true
                }
            } label: {
                Label(mapping.activeMap == nil ? "Name & Save Now" : "Save Now", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!ar.canSaveWorldMap || mapping.isBusy || !ar.supportsMesh)

            HStack {
                Button {
                    if ar.runState == .running { mapping.pauseAutomaticMapping() } else { mapping.resumeAutomaticMapping() }
                } label: {
                    Label(ar.runState == .running ? "Pause Mapping" : "Resume Mapping",
                          systemImage: ar.runState == .running ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!ar.supportsWorldTracking || !ar.supportsMesh || mapping.isBusy)
                Button { showNewMap = true } label: {
                    Label("New Map", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!ar.supportsWorldTracking || !ar.supportsMesh || mapping.isBusy)
            }
            .buttonStyle(.bordered)
        }
    }

    private var library: some View {
        Group {
            if mapping.maps.isEmpty {
                ContentUnavailableView("Your places will appear here", systemImage: "map",
                    description: Text("Scan a space while the app is open. Usable maps save automatically. Open a saved place to explore its colors, photos, text marks, or revisit it in person."))
            } else {
                List(mapping.maps) { place in
                    HStack {
                        Button {
                            Task {
                                if let archive = await mapping.loadMap(id: place.id) {
                                    preview = MapPreview(archive: archive)
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "map.fill").font(.title2).foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(place.name).font(.headline).foregroundStyle(.primary)
                                    Text("\(place.faceCount.formatted()) faces · \(place.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Menu {
                            Button("Rename", systemImage: "pencil") {
                                renameText = place.name
                                pendingRename = place
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = place }
                        } label: {
                            Image(systemName: "ellipsis.circle").padding(8)
                        }
                        .accessibilityLabel("Options for \(place.name)")
                    }
                    .disabled(mapping.isBusy)
                    .listRowBackground(Theme.panel)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .refreshable { await mapping.refreshLibrary() }
    }
}

private struct MapPreview: Identifiable {
    let archive: MapArchive
    var id: UUID { archive.metadata.id }
}

private struct SavedPlaceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ARSessionManager.self) private var ar
    @State private var confirmRevisit = false
    let archive: MapArchive
    let onResume: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                SavedMapSceneView(geometry: archive.geometry)
                    .frame(minHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Text("\(archive.metadata.vertexCount.formatted()) vertices · \(archive.metadata.faceCount.formatted()) faces")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Explore this saved scan from any location. To navigate to its labeled destinations, return to this place and use Revisit to align the map.")
                            .font(.footnote)
                        if let graph = archive.geometry.navigation {
                            Text("Saved destinations: \(graph.labels.map(\.name).joined(separator: ", "))")
                                .font(.footnote)
                        }
                        DisclosureGroup("Text marks and directional signs") {
                            SavedTextObservationsView(annotations: archive.geometry.textAnnotations,
                                                      signage: archive.geometry.directionalSignage)
                        }
                        if let data = archive.referenceImageData, let image = UIImage(data: data) {
                            HStack(spacing: 12) {
                                Image(uiImage: image).resizable().scaledToFit().frame(width: 120, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .accessibilityLabel("Original camera viewpoint")
                                Text("Use this reference view to help the camera recognize the place.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
                Button { confirmRevisit = true } label: {
                    Label("Revisit & Continue Mapping", systemImage: "location.viewfinder")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ar.supportsWorldTracking || !ar.supportsMesh)
            }
            .padding(12)
            .background(Theme.background)
            .navigationTitle(archive.metadata.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Revisit this place?", isPresented: $confirmRevisit, titleVisibility: .visible) {
                Button("Revisit & Continue Mapping", action: onResume)
            } message: {
                Text("The current unsaved scan will be replaced. Return to this place and match its reference photo to continue mapping.")
            }
        }
    }
}

private struct MappingLiveSurfaceView: View {
    @Environment(ARSessionManager.self) private var ar
    @Environment(MappingCoordinator.self) private var mapping
    @State private var holder: MeshSceneHolder?

    var body: some View {
        ZStack {
            Color.black
            if let holder { MeshARView(holder: holder) }
        }
        .onAppear { if holder == nil { holder = MeshSceneHolder(manager: ar) } }
        .task {
            var lastGeneration = -1
            while !Task.isCancelled {
                if lastGeneration != ar.sessionGeneration {
                    holder?.refresh(anchors: [], mode: .solid)
                    holder?.showSavedGeometry(nil)
                    lastGeneration = ar.sessionGeneration
                }
                if ar.runState == .running, let frame = ar.session.currentFrame {
                    if ar.trackingIsNormal && !ar.isRelocalizing && frame.timestamp == ar.lastFrameTimestamp {
                        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
                        holder?.refresh(anchors: anchors, mode: .solid)
                        holder?.showSavedGeometry(mapping.canDisplayRestoredGeometry ? mapping.restoredGeometry : nil,
                                                  excluding: Set(anchors.map(\.identifier)).union(ar.removedMeshAnchorIDs),
                                                  version: mapping.activeMap?.updatedAt)
                        holder?.setCameraPose(frame.camera.transform)
                    } else {
                        // ARWorldMap can restore mesh anchors too. Neither path
                        // may draw them against an unlocalized camera pose.
                        holder?.refresh(anchors: [], mode: .solid)
                        holder?.showSavedGeometry(nil)
                    }
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }
}
