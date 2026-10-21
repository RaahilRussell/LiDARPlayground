import ARKit
import CoreImage
import ImageIO
import Observation
import QuartzCore
import UIKit
import Vision

@MainActor
@Observable
final class LocalTextRecognitionController {
    private(set) var annotations: [SavedTextAnnotation] = []
    private(set) var directionalSignage: [SavedDirectionalSignage] = []
    private(set) var latestAnnotations: [SavedTextAnnotation] = []
    private(set) var latestDirectionalSignage: [SavedDirectionalSignage] = []
    private(set) var latestImageJPEG: Data?
    private(set) var isRunning = false
    private(set) var status = "Text recognition starts with automatic mapping."
    private(set) var lastRecognitionDate: Date?
    private(set) var revision = 0
    private let manager: ARSessionManager
    private let provider: ARSensorProvider
    private var loop: Task<Void, Never>?
    private var generation = -1
    private var operation = UUID()
    private var lastTimestamp: TimeInterval = -1
    private var needsLocalization = false
    private var inFlight = false

    var needsSegmentRollover: Bool {
        annotations.count >= 18_000 || directionalSignage.count >= 18_000 ||
        annotations.reduce(0) { $0 + ($1.evidenceJPEG?.count ?? 0) } +
        directionalSignage.reduce(0) { $0 + ($1.evidenceJPEG?.count ?? 0) } > 40 * 1_024 * 1_024
    }

    init(manager: ARSessionManager) {
        self.manager = manager
        provider = ARSensorProvider(manager: manager)
    }

    func start() {
        guard loop == nil else { return }
        isRunning = true
        if generation == -1 { generation = manager.sessionGeneration }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let start = CACurrentMediaTime()
                await self?.tick()
                let delay = max(0.05, 1 - (CACurrentMediaTime() - start))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func pause() {
        isRunning = false
        operation = UUID()
        loop?.cancel(); loop = nil
        latestAnnotations = []; latestDirectionalSignage = []; latestImageJPEG = nil
        status = "Text recognition paused."
    }

    func beginNewPlace() {
        operation = UUID()
        generation = manager.sessionGeneration
        annotations = []; directionalSignage = []; latestAnnotations = []; latestDirectionalSignage = []; latestImageJPEG = nil
        lastTimestamp = -1; needsLocalization = false
        revision += 1
    }

    func restore(annotations: [SavedTextAnnotation], signage: [SavedDirectionalSignage]) {
        beginNewPlace()
        self.annotations = annotations
        directionalSignage = signage
        needsLocalization = true
    }

    private func tick() async {
        guard isRunning else { return }
        if generation != manager.sessionGeneration { beginNewPlace() }
        guard !inFlight else { return }
        guard !needsLocalization || manager.hasLocalizedMap,
              let frame = provider.snapshot(), frame.trackingIsNormal,
              frame.timestamp != lastTimestamp else {
            latestAnnotations = []; latestDirectionalSignage = []; latestImageJPEG = nil
            status = "Waiting for fresh camera tracking."
            return
        }
        lastTimestamp = frame.timestamp
        let capturedGeneration = generation, token = operation
        let orientation = Self.imageOrientation()
        inFlight = true
        defer { inFlight = false }
        do {
            let result = try await Task.detached(priority: .utility) {
                try TextRecognitionWorker.recognize(frame: frame, orientation: orientation)
            }.value
            guard !Task.isCancelled, isRunning, token == operation,
                  capturedGeneration == manager.sessionGeneration,
                  let currentFrame = manager.session.currentFrame, manager.isCurrentWorldFrame(currentFrame),
                  manager.isCurrentObservation(timestamp: frame.timestamp, maxAge: 3) else {
                if token == operation {
                    latestAnnotations = []; latestDirectionalSignage = []; latestImageJPEG = nil
                    status = "Waiting for current camera tracking; older text observations were discarded."
                }
                return
            }
            latestImageJPEG = result.imageJPEG
            lastRecognitionDate = Date()
            var latest: [SavedTextAnnotation] = []
            var mappedIDs: [UUID: UUID] = [:]
            for incoming in result.annotations {
                var observation = incoming
                if let index = annotations.firstIndex(where: { TextAnnotationMatching.isSamePhysicalText($0, incoming) }) {
                    observation.id = annotations[index].id
                    observation.firstSeen = annotations[index].firstSeen
                    observation.observationCount = min(Int.max - 1, annotations[index].observationCount) + 1
                    if observation.worldPosition == nil { observation.worldPosition = annotations[index].worldPosition }
                    annotations[index] = observation
                } else if annotations.count < 20_000 {
                    annotations.append(observation)
                } else {
                    status = "This segment's text index is full. New observations remain visible until the next map segment."
                    continue
                }
                mappedIDs[incoming.id] = observation.id
                latest.append(observation)
            }
            var latestSigns: [SavedDirectionalSignage] = []
            for incoming in result.signage {
                guard let textID = mappedIDs[incoming.textAnnotationID] else { continue }
                var sign = incoming
                sign.textAnnotationID = textID
                if let index = directionalSignage.firstIndex(where: {
                    $0.textAnnotationID == textID && $0.direction == sign.direction
                }) {
                    sign.id = directionalSignage[index].id
                    directionalSignage[index] = sign
                } else if directionalSignage.count < 20_000 {
                    directionalSignage.append(sign)
                }
                latestSigns.append(sign)
            }
            latestAnnotations = latest
            latestDirectionalSignage = latestSigns
            if !result.annotations.isEmpty { revision += 1 }
            if annotations.count < 20_000 {
                status = "On-device OCR · about 1 scan/second · \(annotations.count) text marks · \(directionalSignage.count) directional signs"
            }
        } catch {
            guard token == operation else { return }
            latestAnnotations = []; latestDirectionalSignage = []; latestImageJPEG = nil
            status = "Text recognition will retry: \(error.localizedDescription)"
        }
    }

    private static func imageOrientation() -> CGImagePropertyOrientation {
        let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.interfaceOrientation ?? .portrait
        switch orientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .down
        case .landscapeRight: return .up
        default: return .right
        }
    }
}

nonisolated struct TextRecognitionResult: Sendable {
    var annotations: [SavedTextAnnotation]
    var signage: [SavedDirectionalSignage]
    var imageJPEG: Data?
}

nonisolated enum TextRecognitionWorker {
    static func recognize(frame: SensorFrame, orientation: CGImagePropertyOrientation) throws -> TextRecognitionResult {
        let context = CIContext(options: [.cacheIntermediates: false])
        let oriented = CIImage(cvPixelBuffer: frame.capturedImage).oriented(orientation)
        let scale = min(1, 1600 / max(oriented.extent.width, oriented.extent.height))
        let scaled = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = context.createCGImage(scaled, from: scaled.extent) else {
            return TextRecognitionResult(annotations: [], signage: [], imageJPEG: nil)
        }
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true
        textRequest.minimumTextHeight = 0.008
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([textRequest])
        let now = Date()
        let p = frame.cameraTransform.columns.3
        let observedFrom = MapPosition(x: p.x, y: p.y, z: p.z)
        let forward = -frame.cameraTransform.columns.2
        let direction = MapPosition(x: forward.x, y: forward.y, z: forward.z)
        let previewScale = min(1, 640 / max(oriented.extent.width, oriented.extent.height))
        let preview = oriented.transformed(by: CGAffineTransform(scaleX: previewScale, y: previewScale))
        let jpeg = context.jpegRepresentation(of: preview, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                               options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.65])
        let evidence = (jpeg?.count ?? 0) <= 512 * 1_024 ? jpeg : nil
        var annotations: [SavedTextAnnotation] = []
        var signs: [SavedDirectionalSignage] = []
        for observation in (textRequest.results ?? []).prefix(160) {
            guard let text = observation.topCandidates(1).first,
                  text.confidence >= 0.35, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let b = observation.boundingBox
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !box.isNull, !box.isEmpty else { continue }
            let position = worldPosition(box: box, orientation: orientation, frame: frame)
            let mark = SavedTextAnnotation(text: String(text.string.prefix(2_000)), confidence: text.confidence,
                                          bounds: TextImageBounds(box), worldPosition: position, observedFrom: observedFrom,
                                          observedDirection: direction,
                                          firstSeen: now, lastSeen: now, evidenceJPEG: evidence)
            annotations.append(mark)
            for direction in SignArrowDetector.glyphDirections(in: text.string) {
                signs.append(SavedDirectionalSignage(textAnnotationID: mark.id, text: mark.text,
                    direction: direction, arrowBounds: mark.bounds, confidence: text.confidence,
                    source: .recognizedGlyph, lastSeen: now, worldPosition: position, evidenceJPEG: evidence))
            }
        }
        // Contours can find printed arrow icons that OCR does not recognize as
        // characters. Restrict associations to nearby text in this SAME image.
        if !annotations.isEmpty {
            for darkOnLight in [true, false] {
                let request = VNDetectContoursRequest()
                request.detectsDarkOnLight = darkOnLight
                request.maximumImageDimension = 512
                try? handler.perform([request])
                guard let contours = request.results?.first else { continue }
                for index in 0..<min(contours.contourCount, 1_000) {
                    guard let contour = try? contours.contour(at: index),
                          let polygon = try? contour.polygonApproximation(epsilon: 0.005) else { continue }
                    let points = polygon.normalizedPoints.map { CGPoint(x: CGFloat($0.x), y: CGFloat(1 - $0.y)) }
                    guard let direction = SignArrowDetector.classify(polygon: points),
                          let x0 = points.map(\.x).min(), let x1 = points.map(\.x).max(),
                          let y0 = points.map(\.y).min(), let y1 = points.map(\.y).max() else { continue }
                    let box = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                    guard box.width > 0.012, box.height > 0.012, box.width < 0.4, box.height < 0.4,
                          let textIndex = SignArrowDetector.nearestText(to: box, texts: annotations.map { $0.bounds.rect }) else { continue }
                    let mark = annotations[textIndex]
                    guard !signs.contains(where: { $0.textAnnotationID == mark.id && $0.direction == direction }) else { continue }
                    signs.append(SavedDirectionalSignage(textAnnotationID: mark.id, text: mark.text,
                        direction: direction, arrowBounds: TextImageBounds(box), confidence: min(mark.confidence, 0.7),
                        source: .contourShape, lastSeen: now, worldPosition: mark.worldPosition, evidenceJPEG: evidence))
                }
            }
        }
        return TextRecognitionResult(annotations: annotations, signage: signs, imageJPEG: evidence)
    }

    /// Inverse of image orientation, mapping top-left upright image coordinates
    /// back to the raw landscape camera/depth image.
    static func rawPoint(_ point: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        switch orientation {
        case .right: return CGPoint(x: point.y, y: 1 - point.x)
        case .left: return CGPoint(x: 1 - point.y, y: point.x)
        case .down: return CGPoint(x: 1 - point.x, y: 1 - point.y)
        default: return point
        }
    }

    static func worldPosition(box: CGRect, orientation: CGImagePropertyOrientation, frame: SensorFrame) -> MapPosition? {
        guard frame.trackingIsNormal, let depth = frame.depthMap, let confidence = frame.rawConfidenceMap else { return nil }
        let width = CVPixelBufferGetWidth(depth), height = CVPixelBufferGetHeight(depth)
        guard width > 0, height > 0, CVPixelBufferGetWidth(confidence) == width,
              CVPixelBufferGetHeight(confidence) == height,
              CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8 else { return nil }
        guard CVPixelBufferLockBaseAddress(depth, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess else { return nil }
        defer {
            CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
        }
        guard let d = CVPixelBufferGetBaseAddress(depth), let c = CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let dr = CVPixelBufferGetBytesPerRow(depth), cr = CVPixelBufferGetBytesPerRow(confidence)
        guard dr >= width * MemoryLayout<Float>.stride, cr >= width else { return nil }
        var values: [Float] = []
        var sampled = Set<Int>()
        for row in 0..<5 {
            for column in 0..<5 {
                let upright = CGPoint(x: box.minX + box.width * (0.25 + CGFloat(column) * 0.125),
                                      y: box.minY + box.height * (0.25 + CGFloat(row) * 0.125))
                let raw = rawPoint(upright, orientation: orientation)
                let x = min(width - 1, max(0, Int(raw.x * CGFloat(width))))
                let y = min(height - 1, max(0, Int(raw.y * CGFloat(height))))
                guard sampled.insert(y * width + x).inserted else { continue }
                let value = d.advanced(by: y * dr).assumingMemoryBound(to: Float.self)[x]
                let level = c.advanced(by: y * cr).assumingMemoryBound(to: UInt8.self)[x]
                if value.isFinite && value > 0.15 && value < 8 && (level == 1 || level == 2) { values.append(value) }
            }
        }
        guard values.count >= 4, values.count * 2 >= sampled.count else { return nil }
        values.sort()
        let median = values[values.count / 2]
        guard values[values.count * 3 / 4] - values[values.count / 4] < max(0.15, median * 0.12) else { return nil }
        let raw = rawPoint(CGPoint(x: box.midX, y: box.midY), orientation: orientation)
        let camera = SpatialFusionEngine.unprojectCamera(nx: Float(raw.x), ny: Float(raw.y), depth: median,
            intrinsics: frame.intrinsics, dw: width, dh: height, imageRes: frame.imageResolution)
        let world = frame.cameraTransform * SIMD4<Float>(camera, 1)
        let result = MapPosition(x: world.x, y: world.y, z: world.z)
        return result.isValid ? result : nil
    }
}
