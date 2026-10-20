//
//  PerceptionTypes.swift
//  test
//
//  Shared value types for the AI Perception layer. These are deliberately
//  independent of the Ultralytics SDK and of ARKit view code, so the engines,
//  fusion, and UI can depend on them without pulling in those modules. Changing
//  a type here must be matched by its fixture test (see testTests, Phase 9).
//

import CoreGraphics
import CoreML
import CoreVideo
import simd

// MARK: - Sensor frame snapshot

/// An immutable snapshot of the data we need from one ARFrame. We copy references
/// (not the whole ARFrame) and only ever keep the latest one in flight, so ARKit's
/// buffer pool is never starved. Marked @unchecked Sendable because the pixel
/// buffers are only read, never mutated, after capture.
struct SensorFrame: @unchecked Sendable {
    let capturedImage: CVPixelBuffer
    let depthMap: CVPixelBuffer?
    let confidenceMap: CVPixelBuffer?
    let smoothedDepthMap: CVPixelBuffer?
    let intrinsics: simd_float3x3
    let imageResolution: CGSize
    let cameraTransform: simd_float4x4
    let timestamp: TimeInterval
    let trackingIsNormal: Bool
}

// MARK: - Model configuration

/// The three instance-segmentation variants we benchmark.
enum ModelVariant: String, CaseIterable, Identifiable, Sendable {
    case nano = "yolo26n-seg"
    case small = "yolo26s-seg"
    case medium = "yolo26m-seg"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .nano: return "YOLO26n-seg"
        case .small: return "YOLO26s-seg"
        case .medium: return "YOLO26m-seg"
        }
    }
    var approxSizeMB: Int {
        switch self {
        case .nano: return 8
        case .small: return 24
        case .medium: return 52
        }
    }
    /// Provenance shown in the model manager.
    var provenance: String { "Ultralytics official · v8.3.0 release · Core ML int8 · AGPL-3.0" }
}

/// Maps our UI option to Core ML's compute-unit selection (ANE preferred by default).
enum ComputeUnitOption: String, CaseIterable, Identifiable, Sendable {
    case all = "All (ANE+GPU+CPU)"
    case cpuAndNeuralEngine = "CPU + Neural Engine"
    case cpuAndGPU = "CPU + GPU"
    case cpuOnly = "CPU only"

    var id: String { rawValue }
    var mlComputeUnits: MLComputeUnits {
        switch self {
        case .all: return .all
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .cpuAndGPU: return .cpuAndGPU
        case .cpuOnly: return .cpuOnly
        }
    }
}

enum ModelLoadState: Equatable, Sendable {
    case notLoaded
    case loading
    case loaded
    case missing          // model file not bundled
    case sdkUnavailable   // UltralyticsYOLO package not added yet
    case failed(String)
}

// MARK: - Detection result (our own, SDK-agnostic)

/// One detected instance mapped out of the SDK result into our own types.
/// @unchecked Sendable: carries an immutable CGImage (not formally Sendable).
struct DetectedObject: Identifiable, @unchecked Sendable {
    let id: Int
    let label: String
    let confidence: Float
    /// Bounding box in normalized image coordinates (0...1, origin top-left).
    let boxNormalized: CGRect
    /// Per-instance mask as a grayscale CGImage (probabilities), if available.
    let mask: CGImage?
}

/// The output of one inference pass, with real measured timings.
struct DetectionResult: @unchecked Sendable {
    var objects: [DetectedObject] = []
    var classNames: [String] = []
    /// Combined instance mask for a quick overlay (per-instance masks live on objects).
    var combinedMask: CGImage?
    var frameTimestamp: TimeInterval = 0
    /// Timings in milliseconds.
    var preprocessMs: Double = 0
    var inferenceMs: Double = 0
    var postprocessMs: Double = 0
    /// Our own wall-clock end-to-end (capture → result) in ms.
    var endToEndMs: Double = 0
    var modelVariant: ModelVariant = .nano
    /// True if the model ran but produced an empty/degenerate mask tensor
    /// (a known YOLO26 Core ML export pitfall) — surfaced, never faked.
    var maskDegenerate: Bool = false
}

// MARK: - Depth refinement

enum DepthFilterMode: String, CaseIterable, Identifiable, Sendable {
    case raw = "Raw"
    case smoothed = "Smoothed"
    case confidenceMedian = "Conf. median"
    case jointBilateral = "Joint bilateral"
    case temporal = "Temporal"
    case combined = "Combined"
    var id: String { rawValue }
}

/// Live-adjustable filter parameters.
struct FilterParams: Sendable, Equatable {
    var kernelRadius: Int = 2
    var spatialSigma: Float = 2.0
    var colorSigma: Float = 0.1
    var discontinuityThreshold: Float = 0.15   // metres
    var temporalStrength: Float = 0.5          // 0 = none, 1 = max
    var minConfidence: Int = 1                 // ARConfidenceLevel raw (0/1/2)
}

// MARK: - Spatial / proximity

enum SpatialRegion: String, Sendable { case left, center, right }

/// Honest occupancy semantics — unobserved is never treated as free.
enum OccupancyClass: String, Sendable {
    case observedFree, occupied, unknown, lowConfidence
}

/// A fused 3D observation of a recognized object.
struct ObjectObservation: Identifiable, Sendable {
    let id: Int
    var label: String
    var confidence: Float
    var validDepthCoverage: Float      // 0...1 fraction of mask with valid depth
    var depthConfidence: Float         // 0...1 mean confidence of used pixels
    var nearestMeters: Float           // robust near estimate (low percentile)
    var medianMeters: Float
    var positionCamera: SIMD3<Float>   // camera-relative metres
    var positionWorld: SIMD3<Float>?   // world metres when tracking supports it
    var azimuthDegrees: Float          // angular direction, +right
    var region: SpatialRegion
    var boxNormalized: CGRect
    var timestamp: TimeInterval
    var ageSeconds: Double = 0
    var uncertain: Bool                // insufficient valid depth → mark, don't trust
}

enum ProximityState: String, Sendable, CaseIterable {
    case clear = "CLEAR"
    case caution = "CAUTION"
    case near = "NEAR"
    case critical = "CRITICAL"
    case uncertain = "UNCERTAIN"
}

/// A single proximity decision, fully instrumented for the event inspector.
struct ProximityEvent: Identifiable, Sendable {
    let id: UUID
    var state: ProximityState
    var distanceMeters: Float?
    var region: SpatialRegion?
    var depthConfidence: Float?
    var triggeringLabel: String?       // may be nil — geometry alone can trigger
    var isSimulated: Bool              // Training/Demo mock vs real sensor
    var inputTimestamp: TimeInterval
    var decidedAt: TimeInterval
    var hapticEnqueuedAt: TimeInterval?
    var patternName: String?
    var processingLatencyMs: Double
}
