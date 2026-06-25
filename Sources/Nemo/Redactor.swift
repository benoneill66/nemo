import Foundation

/// On-device redaction of obviously-sensitive spoken content before it's persisted or sent to the
/// LLM (plan 06). Conservative by design — it reduces obvious leaks (spoken passwords, card/account
/// numbers, key-shaped tokens), not a guarantee. The strongest control remains the timed pause.
enum Redactor {
    static let mask = "‹redacted›"

    /// Patterns that mask the *value*, keeping surrounding words readable. Order matters
    /// (trigger-word phrases first so "my password is hunter2" → "my password is ‹redacted›").
    private static let patterns: [String] = [
        // "<password|passcode|pin|secret|api key|code> is/= <value>"
        #"(?i)\b(password|passcode|pass code|pin|secret|api key|api-key|access code|security code)\b(\s*(is|are|=|:)\s*)\S+"#,
        // Long digit runs (card/account numbers), optionally space/dash grouped — 12+ digits.
        #"\b(?:\d[ -]?){12,}\b"#,
        // SSN-shaped 3-2-4.
        #"\b\d{3}-\d{2}-\d{4}\b"#,
        // API-key-shaped tokens: long mixed alphanumeric runs (24+), or sk-/key- prefixed.
        #"\b(?:sk|key|tok|ghp|xox[baprs])[-_][A-Za-z0-9]{12,}\b"#,
        #"\b[A-Za-z0-9]{32,}\b"#,
    ]

    /// Returns the scrubbed text and whether anything was masked. Idempotent: re-scrubbing masked
    /// text leaves the mask untouched.
    static func scrub(_ text: String) -> (clean: String, didRedact: Bool) {
        var s = text
        var didRedact = false
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            let matches = re.matches(in: s, range: range)
            guard !matches.isEmpty else { continue }
            didRedact = true
            // First pattern keeps the trigger phrase, masking only the value (capture group 1+2).
            if pattern.contains("password") {
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                                withTemplate: "$1$2\(mask)")
            } else {
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                                withTemplate: mask)
            }
        }
        return (s, didRedact)
    }
}
