import Foundation

nonisolated struct PerceptionPipelines: OptionSet, Sendable {
    let rawValue: Int
    static let vision = Self(rawValue: 1 << 0)
    static let fusion = Self(rawValue: 1 << 1)
    static let spatial = Self(rawValue: 1 << 2)
    static let proximity = Self(rawValue: 1 << 3)
    static let depth = Self(rawValue: 1 << 4)
    static let hazards = Self(rawValue: 1 << 5)
    static let fused: Self = [.vision, .fusion, .spatial]
    static let guidance: Self = [.vision, .fusion, .spatial, .proximity, .hazards]
    static let mapping: Self = [.vision, .depth, .fusion, .spatial, .hazards]
}

/// A view has its own stable ID, so either SwiftUI transition ordering is safe.
/// Engines already enabled before the first demand remain manually owned.
nonisolated struct PerceptionPipelineDemand {
    nonisolated struct Changes {
        var start: PerceptionPipelines = []
        var stop: PerceptionPipelines = []
    }
    private var consumers: [UUID: PerceptionPipelines] = [:]
    private var startedForConsumers: PerceptionPipelines = []

    mutating func acquire(_ pipelines: PerceptionPipelines, for consumer: UUID,
                          running: PerceptionPipelines) -> Changes {
        consumers[consumer] = pipelines
        let start = pipelines.subtracting(running)
        startedForConsumers.formUnion(start)
        return Changes(start: start, stop: unneededOwnedPipelines())
    }

    mutating func release(_ consumer: UUID) -> Changes {
        consumers[consumer] = nil
        return Changes(stop: unneededOwnedPipelines())
    }

    private mutating func unneededOwnedPipelines() -> PerceptionPipelines {
        let required = consumers.values.reduce(into: PerceptionPipelines()) { $0.formUnion($1) }
        let stop = startedForConsumers.subtracting(required)
        startedForConsumers.subtract(stop)
        return stop
    }
}
