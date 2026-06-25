import Foundation

/// The piece that makes the memory *useful in the moment*: an on-device relevance engine
/// that watches the rolling transcript and scores existing memories against what's being
/// said right now. No LLM call — it runs on every finalized segment, instantly and for free,
/// matching on named entities, title words, and (weakly) content, weighted toward the
/// categories you'd actually want surfaced mid-conversation (action items, open questions,
/// decisions, preferences, people).
///
/// `AppState` owns the decay/merge lifecycle; this type is a pure, testable scorer.
enum Surfacer {

    /// One memory the engine thinks is relevant to the current moment, with why.
    struct Hit {
        var memory: Memory
        var score: Double
        var matched: [String]   // the terms that triggered it, for the "why"

        /// A short human reason, e.g. "Mentioned: Sarah, Q3 launch".
        var reason: String {
            matched.isEmpty ? "Related to what you're saying"
                            : "Mentioned: " + matched.prefix(3).joined(separator: ", ")
        }
    }

    /// Words too common to be a meaningful match on their own.
    private static let stop: Set<String> = [
        "the","and","for","that","this","with","you","your","are","was","were","but","not",
        "have","has","had","will","would","could","should","they","them","then","than","what",
        "when","where","which","who","why","how","all","any","can","get","got","just","like",
        "now","one","out","our","its","it's","i'm","i've","we're","there","their","about","into",
        "from","been","being","some","more","most","much","very","also","know","think","going",
        "yeah","okay","right","really","actually","kind","sort","stuff","thing","things","gonna",
        "want","need","make","made","done","said","says","let","lets","let's","over","here"
    ]

    /// Category weighting — bias toward what's genuinely actionable when heard.
    private static func weight(_ c: Category) -> Double {
        switch c {
        case .tasks:       return 1.45   // an open action item resurfacing mid-talk is gold
        case .questions:   return 1.40
        case .decisions:   return 1.25
        case .preferences: return 1.20
        case .people:      return 1.18
        case .projects:    return 1.12
        case .meetings:    return 1.00
        case .ideas:       return 1.00
        case .facts:       return 1.00
        case .misc:        return 0.90
        }
    }

    /// Significant lowercased word tokens (alphanumeric, length ≥ 3, not a stopword).
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) }
    }

    /// Rank `memories` by relevance to `recent` transcript text.
    /// - Returns hits above `minScore`, highest first, capped at `limit`.
    static func rank(recent: String, memories: [Memory],
                     minScore: Double = 3.0, limit: Int = 5) -> [Hit] {
        let recentLower = recent.lowercased()
        let recentTokens = Set(tokens(recent))
        guard !recentTokens.isEmpty else { return [] }

        var hits: [Hit] = []
        for mem in memories {
            var matched: [String] = []
            var score = 0.0

            // 1. Entity matches — strongest signal. A multi-word entity ("Q3 launch")
            //    counts if its full phrase appears; a single word if that token is present.
            for entity in mem.entities {
                let e = entity.lowercased().trimmingCharacters(in: .whitespaces)
                guard e.count >= 3 else { continue }
                let entToks = tokens(entity)
                let phraseHit = e.contains(" ") ? recentLower.contains(e)
                                                : recentTokens.contains(e)
                let tokenHit = !entToks.isEmpty && entToks.allSatisfy { recentTokens.contains($0) }
                if phraseHit || tokenHit {
                    score += 3.0
                    matched.append(entity)
                }
            }

            // 2. Title word overlap — strong; the title is the gist of the memory.
            let titleHits = Set(tokens(mem.title)).intersection(recentTokens)
            if !titleHits.isEmpty {
                score += 1.6 * Double(titleHits.count)
                for t in titleHits where !matched.contains(where: { $0.lowercased() == t }) {
                    matched.append(t)
                }
            }

            // 3. Content overlap — weak supporting signal, capped so a long note can't
            //    dominate just by containing many common-ish words.
            let contentHits = Set(tokens(mem.content)).intersection(recentTokens)
            score += 0.35 * Double(min(contentHits.count, 6))

            guard score > 0 else { continue }

            // Category bias + a nudge for importance.
            score *= weight(mem.categoryEnum)
            score += 0.18 * Double(mem.importance)

            // Require a real anchor: an entity or title hit. Pure content-word overlap
            // is too noisy to surface on its own.
            let hasAnchor = !mem.entities.isEmpty &&
                matched.contains { mem.entities.map { $0.lowercased() }.contains($0.lowercased()) }
            let hasTitleAnchor = !titleHits.isEmpty
            guard hasAnchor || hasTitleAnchor, score >= minScore else { continue }

            hits.append(Hit(memory: mem, score: score, matched: matched))
        }

        return hits.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }
}
