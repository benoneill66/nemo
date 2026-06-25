import Foundation
import AVFoundation

/// Text-to-speech for the optional "ask Claude out loud" path. Picks the best installed
/// English voice (honoring a configured override) and reads sanitized answers aloud.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var onFinish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        let clean = AssistantRunner.spoken(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { onFinish?(); return }
        let u = AVSpeechUtterance(string: clean)
        u.voice = Self.preferredVoice()
        u.rate = Self.preferredRate()
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }

    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        guard !voices.isEmpty else { return AVSpeechSynthesisVoice(language: "en-US") }
        if let want = Config.voice, !want.isEmpty {
            if let v = voices.first(where: { $0.identifier == want }) { return v }
            if let v = voices.first(where: { $0.name.caseInsensitiveCompare(want) == .orderedSame }) { return v }
            if let v = voices.first(where: { $0.name.localizedCaseInsensitiveContains(want) }) { return v }
        }
        let region = Locale.current.region?.identifier
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            if let region, v.language.hasSuffix(region) { return 0 }
            if v.language == "en-US" { return 1 }
            return 2
        }
        return voices.sorted {
            if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
            return rank($0) < rank($1)
        }.first
    }

    private static func preferredRate() -> Float {
        if let r = Config.rate { return Float(r) }
        return AVSpeechUtteranceDefaultSpeechRate * 0.96
    }
}
