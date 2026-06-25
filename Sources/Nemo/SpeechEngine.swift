import Foundation

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
    /// Short label for the UI, e.g. "Enhanced dictation".
    var displayName: String { get }
    func start()
    func stop()
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
