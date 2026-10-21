//
//  SpeechCoordinator.swift
//  test
//
//  Spoken output for Wearer Mode. Uses AVSpeechSynthesizer with de-duplication
//  and priority so warnings are heard without flooding the user. Ducks other
//  audio but mixes with it, and does not fight VoiceOver.
//

import AVFoundation
import Observation
import QuartzCore

enum SpeechPriority { case normal, high }

@MainActor
@Observable
final class SpeechCoordinator {
    var enabled = true
    private(set) var lastSpokenText = ""

    private let synth = AVSpeechSynthesizer()
    private var lastText = ""
    private var lastTime: TimeInterval = 0
    private var audioConfigured = false

    func configureAudioIfNeeded() {
        guard !audioConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio,
                                 options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
        audioConfigured = true
    }

    /// Speaks `text`, skipping exact repeats within `minRepeat` seconds. High
    /// priority interrupts current speech; normal priority yields if already talking.
    func speak(_ text: String, priority: SpeechPriority = .normal, minRepeat: Double = 3) {
        guard enabled, !text.isEmpty else { return }
        let now = CACurrentMediaTime()
        if text == lastText, now - lastTime < minRepeat { return }

        switch priority {
        case .high:
            synth.stopSpeaking(at: .immediate)
        case .normal:
            if synth.isSpeaking { return }
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.prefersAssistiveTechnologySettings = true
        synth.speak(utterance)
        lastText = text
        lastTime = now
        lastSpokenText = text
    }

    func stopAll() { synth.stopSpeaking(at: .immediate) }
}
