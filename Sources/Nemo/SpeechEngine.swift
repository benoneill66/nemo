import Foundation
import AVFoundation

/// Status shared by both speech backends.
enum SpeechEngineStatus: Equatable {
    case stopped
    case needsAuth(String)
    case unavailable(String)
    case listening
}

/// A pluggable transcription backend. Two implementations exist:
///   • `DictationEngine` — macOS 26 `SpeechAnalyzer`/`SpeechTranscriber`, the engine behind
///     the system's enhanced dictation: higher accuracy, punctuation, true long-form.
///   • `TranscriptionEngine` — the `SFSpeechRecognizer` fallback for older systems.
@MainActor
protocol SpeechEngine: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    /// A finalized chunk of speech, with an optional voice fingerprint of the audio behind it
    /// (nil when diarization is off or there wasn't enough voiced audio to characterize).
    var onSegment: ((_ text: String, _ start: Date, _ end: Date, _ voice: VoiceFingerprint?) -> Void)? { get set }
    var onStatus: ((SpeechEngineStatus) -> Void)? { get set }
    /// Normalized 0…1 microphone loudness, emitted continuously while listening, to drive a
    /// live level meter / waveform in the UI. Optional — not every backend need set it.
    var onLevel: ((Float) -> Void)? { get set }
    /// Short label for the UI, e.g. "Enhanced dictation".
    var displayName: String { get }
    func start()
    func stop()
}

/// Normalized 0…1 microphone level for a captured buffer: RMS mapped through a perceptual
/// dB range (roughly −50 dB…0 dB → 0…1) so quiet speech still moves a meter. Pure and
/// thread-safe — safe to call from a realtime audio tap.
func micLevel(from buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
    let frames = Int(buffer.frameLength)
    let samples = data[0]
    var sum: Float = 0
    for i in 0..<frames { let s = samples[i]; sum += s * s }
    let rms = sqrtf(sum / Float(frames))
    let db = 20 * log10f(max(rms, 1e-7))
    return max(0, min(1, (db + 50) / 50))
}

/// Picks the best engine available, honoring an optional `"engine"` override in config.json
/// ("auto" | "dictation" | "legacy").
@MainActor
func makeSpeechEngine() -> SpeechEngine {
    let pref = Config.engine
    if pref != "legacy", #available(macOS 26.0, *), DictationEngine.isSupported {
        return DictationEngine()
    }
    return TranscriptionEngine()
}
