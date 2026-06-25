import Foundation

/// Typed view over ~/.config/nemo/config.json for the always-listening features.
/// Everything has a sensible default so the app works with no config file at all.
enum Config {
    private static func raw() -> [String: Any] { Settings.raw() }

    private static func strings(_ key: String, default def: [String]) -> [String] {
        (raw()[key] as? [String])?.map { $0.lowercased() }.filter { !$0.isEmpty } ?? def
    }

    /// Spoken phrases that flag the surrounding speech as important.
    static var markers: [String] {
        strings("markers", default: [
            "important", "remember this", "remember that", "make a note", "note that",
            "note to self", "action item", "don't forget", "flag this", "mark this",
            "key point", "takeaway", "follow up"
        ])
    }

    /// Phrases that open / close a named meeting session.
    static var meetingStartPhrases: [String] {
        strings("meetingStart", default: ["start meeting", "begin meeting", "start a meeting", "start recording meeting"])
    }
    static var meetingStopPhrases: [String] {
        strings("meetingStop", default: ["end meeting", "stop meeting", "end the meeting", "finish meeting", "wrap up meeting"])
    }

    /// Optional wake phrases ("hey <word>") that route the spoken question to Claude and
    /// answer aloud. Set "wakeAnswer": false in config.json to disable the talk-back feature.
    static var wakeAnswerEnabled: Bool { (raw()["wakeAnswer"] as? Bool) ?? true }
    static var wakeWords: [String] {
        strings("wakeWords", default: ["nemo", "nimo", "neemo", "nemmo", "memo"])
    }

    /// How the consolidator is scheduled.
    static var consolidateMinutes: Double { (raw()["consolidateMinutes"] as? Double) ?? 5 }
    static var consolidateMinSegments: Int { (raw()["consolidateMinSegments"] as? Int) ?? 6 }

    /// Model used for memory consolidation / import (kept fast + cheap by default).
    static var memoryModel: String? { (raw()["memoryModel"] as? String) ?? "claude-sonnet-4-6" }

    /// Extra files/dirs of existing assistant memory to offer for import, beyond the
    /// auto-discovered Claude locations.
    static var importPaths: [String] {
        (raw()["importPaths"] as? [String]) ?? []
    }

    /// Transcription backend: "auto" (prefer enhanced dictation on macOS 26+), "dictation",
    /// or "legacy" (force the SFSpeechRecognizer path).
    static var engine: String { ((raw()["engine"] as? String) ?? "auto").lowercased() }

    /// Locale for transcription, e.g. "en-GB". Defaults to the system locale.
    static var locale: Locale? {
        guard let id = raw()["locale"] as? String, !id.isEmpty else { return nil }
        return Locale(identifier: id)
    }

    static var voice: String? { raw()["voice"] as? String }
    static var rate: Double? { raw()["rate"] as? Double }
    static var chime: Any? { raw()["chime"] }
}
