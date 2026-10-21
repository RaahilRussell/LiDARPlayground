//
//  HapticCoordinator.swift
//  test
//
//  Phase 5 — standalone Core Haptics engine + pattern library, independent of CV
//  inference. Handles engine interruption / reset / restart, plays one player per
//  event (no stacking), and enforces per-pattern cooldown + priority so warnings
//  never oscillate or flood the single haptic actuator.
//

import CoreHaptics
import Foundation
import Observation
import QuartzCore

enum HapticPattern: String, CaseIterable, Identifiable {
    case shortLight = "Short light pulse"
    case twoPulseWarning = "Two-pulse warning"
    case repeatedProximity = "Repeated proximity"
    case criticalProximity = "Critical proximity"
    case uncertainty = "Sensor uncertainty"
    var id: String { rawValue }

    /// Higher wins when events contend within the cooldown window.
    var priority: Int {
        switch self {
        case .uncertainty: return 0
        case .shortLight: return 1
        case .twoPulseWarning: return 2
        case .repeatedProximity: return 3
        case .criticalProximity: return 4
        }
    }
}

@MainActor
@Observable
final class HapticCoordinator {
    // Live-adjustable parameters.
    var enabled = true
    var intensity: Float = 0.8
    var sharpness: Float = 0.5
    var pulseDuration: Double = 0.08
    var repetitionInterval: Double = 0.18
    var minWarningDistance: Float = 1.5     // used by ProximityEvaluator config UI
    var cooldown: Double = 0.4

    private(set) var supportsHaptics: Bool = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private(set) var engineState: String = "not started"

    private var engine: CHHapticEngine?
    private var currentPlayer: CHHapticPatternPlayer?
    private var lastPlayTime: TimeInterval = 0
    private var lastPriority: Int = -1

    init() { prepareEngine() }

    // MARK: - Engine lifecycle

    func prepareEngine() {
        guard supportsHaptics else { engineState = "unsupported on this device"; return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            engine.stoppedHandler = { [weak self] reason in
                Task { @MainActor in self?.engineState = "stopped (\(reason.rawValue))" }
            }
            engine.resetHandler = { [weak self] in
                // The engine reset (e.g., after interruption) — restart it.
                Task { @MainActor in self?.restart() }
            }
            try engine.start()
            self.engine = engine
            engineState = "running"
        } catch {
            engineState = "failed: \(error.localizedDescription)"
        }
    }

    func restart() {
        do { try engine?.start(); engineState = "running" }
        catch { engineState = "restart failed: \(error.localizedDescription)" }
    }

    func stopEngine() {
        engine?.stop()
        engineState = "stopped"
    }

    // MARK: - Playback

    /// Plays a pattern honoring enable, cooldown, and priority. Returns the time it
    /// was enqueued (for the event inspector), or nil if suppressed.
    @discardableResult
    func play(_ pattern: HapticPattern, force: Bool = false) -> TimeInterval? {
        guard enabled, supportsHaptics else { return nil }
        let now = CACurrentMediaTime()
        if !force {
            let withinCooldown = (now - lastPlayTime) < cooldown
            // Suppress unless this event outranks the one that set the cooldown.
            if withinCooldown && pattern.priority <= lastPriority { return nil }
        }
        guard let engine else { prepareEngine(); return nil }
        do {
            let patternObj = try CHHapticPattern(events: events(for: pattern), parameters: [])
            let player = try engine.makePlayer(with: patternObj)
            try? currentPlayer?.stop(atTime: 0)   // one player at a time — never stack
            try player.start(atTime: 0)
            currentPlayer = player
            lastPlayTime = now
            lastPriority = pattern.priority
            return now
        } catch {
            engineState = "play failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Immediate single transient with NO cooldown/priority — the graded proximity
    /// pulse train controls its own cadence, so it bypasses the discrete-event gate.
    func pulse(intensity: Float, sharpness: Float) {
        guard enabled, supportsHaptics, let engine else { return }
        do {
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0, min(1, intensity))),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: max(0, min(1, sharpness)))
            ], relativeTime: 0)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            engineState = "pulse failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Pattern library

    private func events(for pattern: HapticPattern) -> [CHHapticEvent] {
        let i = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)
        let s = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
        func transient(at t: Double, intensity iv: Float? = nil, sharpness sv: Float? = nil) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: iv ?? intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sv ?? sharpness)
            ], relativeTime: t)
        }
        func continuous(at t: Double, duration: Double, intensity iv: Float, sharpness sv: Float) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: iv),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sv)
            ], relativeTime: t, duration: duration)
        }

        switch pattern {
        case .shortLight:
            return [CHHapticEvent(eventType: .hapticTransient, parameters: [i, s], relativeTime: 0)]
        case .twoPulseWarning:
            return [transient(at: 0), transient(at: repetitionInterval)]
        case .repeatedProximity:
            return (0..<4).map { transient(at: Double($0) * repetitionInterval) }
        case .criticalProximity:
            // Sharp, strong, sustained — clearly distinct from the others.
            return [continuous(at: 0, duration: max(0.2, pulseDuration * 4),
                               intensity: min(1, intensity + 0.2), sharpness: min(1, sharpness + 0.3))]
        case .uncertainty:
            // Soft, low-sharpness double "wobble" — deliberately unlike proximity.
            return [continuous(at: 0, duration: 0.15, intensity: intensity * 0.5, sharpness: 0.1),
                    continuous(at: 0.25, duration: 0.15, intensity: intensity * 0.5, sharpness: 0.1)]
        }
    }
}
