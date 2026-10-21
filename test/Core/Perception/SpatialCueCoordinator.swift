//
//  SpatialCueCoordinator.swift
//  test
//
//  Directional audio cue. The iPhone has ONE haptic actuator (can't localize
//  left/right), but audio CAN be panned — so on earbuds a short tone panned to the
//  hazard's bearing gives a real sense of direction (the approach used by
//  orientation apps like Microsoft Soundscape). Pan ∝ bearing; volume/rate ∝ urgency.
//
//  On the mono speaker the pan collapses, so this augments — never replaces —
//  speech + haptics.
//

import AVFoundation
import Observation
import QuartzCore

@MainActor
@Observable
final class SpatialCueCoordinator {
    var enabled = true

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var tone: AVAudioPCMBuffer?
    private var configured = false
    private var lastCue: TimeInterval = 0
    private let minInterval = 0.1   // cadence is governed by FeedbackCoordinator

    init() { buildTone() }

    private func buildTone() {
        let sampleRate = 44_100.0
        let seconds = 0.12
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let freq = 880.0
        if let ch = buffer.floatChannelData?[0] {
            for n in 0..<Int(frames) {
                // Sine with a short attack/decay envelope to avoid clicks.
                let t = Double(n) / sampleRate
                let env = sin(Double.pi * Double(n) / Double(frames))   // 0→1→0
                ch[n] = Float(sin(2 * .pi * freq * t) * env * 0.9)
            }
        }
        tone = buffer
    }

    private func ensureRunning() {
        guard !configured else {
            if !engine.isRunning { try? engine.start() }
            return
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: tone?.format)
        try? engine.start()
        player.play()
        configured = true
    }

    /// Plays a directional blip. `bearingDeg` + = right; `urgency` 0…1.
    func cue(bearingDeg: Float, urgency: Float) {
        guard enabled, let tone else { return }
        let now = CACurrentMediaTime()
        guard now - lastCue > minInterval else { return }
        lastCue = now
        ensureRunning()
        player.pan = max(-1, min(1, bearingDeg / 60))        // ±60° maps to full L/R
        player.volume = 0.25 + 0.75 * max(0, min(1, urgency))
        player.scheduleBuffer(tone, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    func stop() {
        player.stop()
        if engine.isRunning { engine.pause() }
    }
}
