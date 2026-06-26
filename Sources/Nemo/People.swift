import Foundation

// MARK: - Person model (plan 16)

/// One discrete piece of context learned about a person, kept with provenance so the UI can
/// show where it came from and so re-runs can dedupe rather than pile up duplicates.
struct PersonFact: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var source: String = "transcript"   // "transcript" | "import:<assistant>" | "user"
    var sourceMemoryId: UUID? = nil       // the memory this fact was distilled from, if any
    var added: Date = Date()

    /// Normalized form used to dedupe facts that say the same thing.
    var dedupKey: String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
    }
}

/// A first-class person Nemo builds up context on over time. Unlike a bare entity string, a
/// `Person` accumulates aliases, attributes (role/org/email…), discrete facts with provenance,
/// the memories that mention them, and the voice clusters (speakers) attached to them. Crucially,
/// two people who merely share a name are NOT assumed identical — disambiguation is deliberate
/// (see `PeopleBuilder`), and a wrong guess can be undone by merging or splitting.
struct Person: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String                          // canonical display name
    var aliases: [String] = []                // other names / nicknames / spellings seen
    var summary: String = ""                  // rolling human-readable blurb (derived unless edited)
    var attributes: [String: String] = [:]    // role, org, email, location, relationship, …
    var facts: [PersonFact] = []              // accumulated context with provenance
    var memoryIds: [UUID] = []                // memories that mention this person
    var speakerIds: [Int] = []                // voice clusters attached to this person
    var mentionCount: Int = 0                 // times seen across consolidation rounds (confidence)
    var firstSeen: Date = Date()
    var lastSeen: Date = Date()

    var pinned: Bool = false                  // user-curated: automation won't override
    var userEdited: Bool = false              // user edited name/summary: don't clobber
    var mergedFrom: [UUID] = []               // ids of people merged into this one (provenance)

    /// Every name this person answers to (canonical + aliases), lowercased.
    var knownNames: [String] {
        ([name] + aliases).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    /// First token of the canonical name — used for loose "Sarah" ↔ "Sarah Chen" candidate matching.
    var firstName: String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    /// A short attributes line (e.g. "PM at Acme · ben@x.com") for compact display.
    var attributeLine: String {
        var parts: [String] = []
        if let role = attributes["role"], !role.isEmpty {
            if let org = attributes["org"], !org.isEmpty { parts.append("\(role) at \(org)") }
            else { parts.append(role) }
        } else if let org = attributes["org"], !org.isEmpty {
            parts.append(org)
        }
        if let rel = attributes["relationship"], !rel.isEmpty { parts.append(rel) }
        if let email = attributes["email"], !email.isEmpty { parts.append(email) }
        return parts.joined(separator: " · ")
    }

    /// The blurb shown for this person: the user's text if they edited it, otherwise derived
    /// from attributes + the most recent facts so the UI always has something useful.
    var displaySummary: String {
        if userEdited, !summary.isEmpty { return summary }
        if !summary.isEmpty { return summary }
        let recent = facts.suffix(3).map(\.text)
        let line = attributeLine
        return ([line] + recent).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var hue: Double {
        // Stable pleasant hue derived from the id, independent of speaker hues.
        let golden = 0.61803398875
        let seed = Double(abs(id.hashValue % 997)) / 997.0
        return (seed + golden).truncatingRemainder(dividingBy: 1)
    }
}

// MARK: - PeopleBuilder: extraction + human-like disambiguation

/// Builds and enriches the `Person` graph from newly consolidated memories. This is the piece that
/// makes "people" a real concept rather than loose name strings:
///
///  1. It asks the model to pull the people out of the latest memories, with their attributes and
///     a few durable facts.
///  2. For each person it decides — like a human would — whether they're someone Nemo already knows
///     (matching against candidates with the SAME or overlapping names, using surrounding context)
///     or a new person who merely shares a name. It never assumes same-name ⇒ same-person.
///
/// The model returns a `match` (an existing person id) or null (new). A deterministic, conservative
/// fallback (exact full-name match only) is used when the model is unavailable.
enum PeopleBuilder {

    /// One resolved person the model produced for this round.
    struct Resolution: Decodable {
        var match: String?            // existing Person UUID string, or null = new person
        var name: String
        var aliases: [String]?
        var role: String?
        var org: String?
        var email: String?
        var relationship: String?
        var facts: [String]?
        var memories: [String]?       // titles of related memories to link
    }
    private struct Payload: Decodable { var people: [Resolution]? }

    private static let system = """
    You maintain the people directory of an always-listening personal assistant. You are given \
    newly distilled memories and the assistant's EXISTING people who share a name with someone in \
    those memories. Your job is to identify the real people referenced and, for each, decide \
    whether they are one of the existing people or a brand-new person.

    Think like a careful human who knows these people:
    - NEVER assume two people are the same just because they share a name or first name. \
    "Sarah from accounting" and "Sarah my sister" are different people.
    - Match an existing person ONLY when the surrounding context is consistent with what is already \
    known about them (role, org, relationship, projects, other facts). When context conflicts or is \
    insufficient to be confident, treat them as a NEW person (match: null) rather than guessing.
    - A short name can match a fuller existing name (e.g. "Priya" → "Priya Shah") when context fits.
    - Capture only durable, factual context (role, organization, relationships, responsibilities, \
    stable preferences). Ignore one-off chatter. Never invent facts.

    Output ONLY valid JSON.
    """

    /// Whether there is any person-shaped signal worth running the model over.
    static func hasCandidates(in memories: [Memory]) -> Bool {
        memories.contains { !$0.entities.isEmpty || $0.categoryEnum == .people }
    }

    /// Run extraction + disambiguation over `touched` memories against the `existing` directory.
    /// Returns the model's resolutions (callers apply them). Throws if the model output is unusable.
    static func resolve(touched: [Memory], existing: [Person],
                        model: String?) async throws -> [Resolution] {
        guard hasCandidates(in: touched) else { return [] }

        // Gather the names referenced this round so we can show the model the relevant existing
        // people (those that share a name) as match candidates — keeping the prompt bounded.
        let referenced = referencedNames(in: touched)
        let candidates = existing.filter { p in
            !p.knownNames.isEmpty && (
                p.knownNames.contains { referenced.contains($0) } ||
                referenced.contains(p.firstName.lowercased())
            )
        }.sorted { $0.lastSeen > $1.lastSeen }.prefix(30)

        let prompt = buildPrompt(touched: touched, candidates: Array(candidates))
        let raw = try await AssistantRunner.claudeOneShot(prompt: prompt, system: system,
                                                          model: model, feature: "people")
        let payload: Payload = try Consolidator.parseJSON(raw)
        return (payload.people ?? []).filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Names mentioned in a batch of memories, lowercased — entities plus people-category titles.
    static func referencedNames(in memories: [Memory]) -> Set<String> {
        var names = Set<String>()
        for m in memories {
            for e in m.entities {
                let t = e.lowercased().trimmingCharacters(in: .whitespaces)
                if t.count > 1 { names.insert(t) }
            }
        }
        return names
    }

    // MARK: Prompt

    private static func buildPrompt(touched: [Memory], candidates: [Person]) -> String {
        let mems = touched.prefix(40).map { m -> String in
            let ent = m.entities.isEmpty ? "" : " [entities: \(m.entities.joined(separator: ", "))]"
            return "- \"\(m.title)\" [\(m.category)]: \(m.content)\(ent)"
        }.joined(separator: "\n")

        let known: String
        if candidates.isEmpty {
            known = "(none known yet)"
        } else {
            known = candidates.map { p -> String in
                var line = "- id=\(p.id.uuidString) name=\"\(p.name)\""
                if !p.aliases.isEmpty { line += " aliases=[\(p.aliases.joined(separator: ", "))]" }
                let attrs = p.attributeLine
                if !attrs.isEmpty { line += " — \(attrs)" }
                let facts = p.facts.suffix(4).map(\.text)
                if !facts.isEmpty { line += "\n    known: \(facts.joined(separator: "; "))" }
                return line
            }.joined(separator: "\n")
        }

        return """
        NEW MEMORIES:
        \(mems)

        EXISTING PEOPLE WHO SHARE A NAME WITH SOMEONE ABOVE (candidates to match against — \
        remember a shared name does NOT make them the same person):
        \(known)

        Identify the real people referenced in the new memories. For each, decide if they are one \
        of the existing people (set "match" to that id) or a new person (set "match" to null). \
        Respond with ONLY this JSON, no prose, no fences:
        {
          "people": [
            {
              "match": "<existing id or null>",
              "name": "canonical full name",
              "aliases": ["other names seen"],
              "role": "their role or null",
              "org": "their organization or null",
              "email": "email or null",
              "relationship": "relationship to the user or null",
              "facts": ["durable context facts about them"],
              "memories": ["titles of the new memories that involve them"]
            }
          ]
        }
        If no real people are referenced, return {"people": []}.
        """
    }

    // MARK: Deterministic fallback (no LLM / model failure)

    /// Conservative resolution used when the model is unavailable: attach memories to a person only
    /// on an EXACT full-name match against a known entity; never merges different same-name people,
    /// never invents facts. Returns updated people (existing + any newly created).
    static func resolveDeterministically(touched: [Memory], existing: [Person]) -> [Person] {
        var people = existing
        var byName: [String: Int] = [:]
        for (i, p) in people.enumerated() {
            for n in p.knownNames { byName[n] = i }
        }
        for m in touched where m.categoryEnum == .people || !m.entities.isEmpty {
            // Only treat People-category entities as person names in the fallback to avoid
            // mistaking projects/things for people.
            guard m.categoryEnum == .people else { continue }
            for e in m.entities {
                let name = e.trimmingCharacters(in: .whitespaces)
                guard name.count > 1 else { continue }
                let key = name.lowercased()
                if let idx = byName[key] {
                    if !people[idx].memoryIds.contains(m.id) { people[idx].memoryIds.append(m.id) }
                    people[idx].mentionCount += 1
                    people[idx].lastSeen = max(people[idx].lastSeen, m.updated)
                } else {
                    let p = Person(name: name, memoryIds: [m.id], mentionCount: 1,
                                   firstSeen: m.updated, lastSeen: m.updated)
                    people.append(p)
                    byName[key] = people.count - 1
                }
            }
        }
        return people
    }
}
