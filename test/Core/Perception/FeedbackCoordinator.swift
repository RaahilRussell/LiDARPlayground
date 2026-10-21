//
//  FeedbackCoordinator.swift
//  test
//
//  Unifies haptic + audio output into a single GRADED, CONTINUOUS signal that
//  "lines up" with how urgent a hazard is — like a parking sensor — instead of a
//  one-shot buzz only at CRITICAL.
//
//   • Pulse CADENCE scales with urgency (slow ticks when mild → rapid when imminent)
//   • Pulse STRENGTH (intensity + sharpness) scales with urgency
//   • A panned audio blip accompanies each pulse (direction on earbuds)
//   • CAUTION (e.g. walking alongside something) = gentle, slow; CRITICAL = fast, strong
//   • UNCERTAIN = a distinct soft, slow double-feel (not a proximity ramp)
//
//  Urgency is computed upstream from distance + time-to-collision + whether the
//  hazard is on your path, so lateral/non-closing objects stay gentle.
//

import Observation
import QuartzCore

@MainActor
@Observable
final class FeedbackCoordinator {
    var enabled = true

    private unowned let haptics: HapticCoordinator
    private unowned let spatialCue: SpatialCueCoordinator
    private var lastPulse: TimeInterval = 0

    init(haptics: HapticCoordinator, spatialCue: SpatialCueCoordinator) {
        self.haptics = haptics
        self.spatialCue = spatialCue
    }

    /// Called every driver tick with the current fused outcome.
    func update(state: ProximityState, urgency: Float, bearingDeg: Float,
                inPath: Bool = true, now: TimeInterval) {
        guard enabled else { return }
        let u = max(0, min(1, urgency))

        switch state {
        case .clear:
            return
        case .uncertain:
            // Distinct, calm "I'm not sure" cue — slow and soft, never a ramp.
            if now - lastPulse > 2.0 {
                haptics.pulse(intensity: 0.25, sharpness: 0.1)
                lastPulse = now
            }
            return
        case .caution, .near, .critical:
            break
        }

        if !inPath {
            // Side-by-side awareness is useful, but it must never sound like a
            // continuous collision alarm. Give a sparse, soft directional marker.
            let interval = Double(3.0 - 1.0 * u)
            guard now - lastPulse >= interval else { return }
            lastPulse = now
            haptics.pulse(intensity: 0.18 + 0.18 * u, sharpness: 0.12 + 0.18 * u)
            spatialCue.cue(bearingDeg: bearingDeg, urgency: min(0.45, u))
            return
        }

        // Path cadence: 0.9 s apart when mild → ~0.12 s when imminent.
        let interval = Double(0.9 - 0.78 * u)
        guard now - lastPulse >= interval else { return }
        lastPulse = now

        haptics.pulse(intensity: 0.35 + 0.65 * u, sharpness: 0.25 + 0.7 * u)
        spatialCue.cue(bearingDeg: bearingDeg, urgency: u)
    }

    func stop() {
        lastPulse = 0
        spatialCue.stop()
    }
}
