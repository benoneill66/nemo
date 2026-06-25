import Foundation

/// Turns raw transcript segments into durable, categorized, interconnected memories by
/// asking the Claude CLI to distill them, then merging the result into the existing graph
/// (updating matching memories, creating new ones, and linking related/co-occurring items).
enum Consolidator {

    // What the model returns. Kept lenient so a slightly-off response still parses.
    private struct Draft: Decodable, Sendable {
        var title: String
        var content: String
        var category: String?
        var entities: [String]?
        var related: [String]?      // titles of related memories (existing or new)
        var importance: Int?
        var action: String?         // "create" | "update"
    }
    private struct Payload: Decodable {
        var memories: [Draft]?
        var summary: String?
    }

    struct Output {
        var memories: [Memory]      // the full, merged memory set
        var summary: String?        // optional running summary of this batch / session
        var created: Int
        var updated: Int
    }

    private static let system = """
    You are the memory engine of an always-listening personal assistant. You receive raw \
    speech transcripts (possibly noisy, with filler and misheard words) and distill them \
    into durable, well-organized memories about the user's life and work. Be faithful: \
    never invent facts. Ignore chit-chat, filler, and anything with no lasting value. \
    Merge related points into single coherent memories. Write each memory's content as \
    crisp third-person notes the user would value weeks later. Output ONLY valid JSON.
    """

    private static let importSystem = """
    You are the memory engine of a personal assistant, importing what another AI assistant \
    already knows about the user. You receive that assistant's saved memory notes and must \
    reorganize them into this assistant's own durable, categorized memories. Preserve every \
    real fact; do not invent. Merge duplicates. Output ONLY valid JSON.
    """

    /// `sessionTitle` (if any) lets the model know these segments belong to a meeting.
    /// `importedFrom` (e.g. "claude") switches to import framing and tags new memories as
    /// having come from that assistant rather than the live transcript.
    static func consolidate(segments: [TranscriptSegment],
                            existing: [Memory],
                            model: String?,
                            sessionTitle: String?,
                            importedFrom: String? = nil) async throws -> Output {
        let prompt = buildPrompt(segments: segments, existing: existing,
                                 sessionTitle: sessionTitle, importedFrom: importedFrom)
        let sys = importedFrom == nil ? system : importSystem
        let raw = try await AssistantRunner.claudeOneShot(prompt: prompt, system: sys, model: model)
        let payload = try parse(raw)
        let source = importedFrom.map { "import:\($0)" } ?? "transcript"
        return merge(drafts: payload.memories ?? [], into: existing,
                     summary: payload.summary, source: source)
    }

    /// Distills many independent batches **concurrently** (capped), then merges them once.
    /// Used for bulk work like context import, where dozens of chunks would otherwise run as
    /// slow sequential CLI calls. Each batch is distilled against the same `existing` snapshot;
    /// a batch that fails is skipped rather than aborting the whole job.
    static func consolidateConcurrent(batches: [[TranscriptSegment]],
                                      existing: [Memory],
                                      model: String?,
                                      importedFrom: String?,
                                      maxConcurrent: Int = 5,
                                      onProgress: @Sendable @escaping (Int, Int) -> Void = { _, _ in }) async -> Output {
        let sys = importedFrom == nil ? system : importSystem
        let source = importedFrom.map { "import:\($0)" } ?? "transcript"
        let total = batches.count
        guard total > 0 else { return Output(memories: existing, summary: nil, created: 0, updated: 0) }

        var allDrafts: [Draft] = []
        var summary: String?
        var done = 0
        var next = 0

        await withTaskGroup(of: (Int, [Draft], String?).self) { group in
            func schedule() {
                guard next < batches.count else { return }
                let i = next; next += 1
                let segs = batches[i]
                group.addTask {
                    do {
                        let prompt = buildPrompt(segments: segs, existing: existing,
                                                 sessionTitle: nil, importedFrom: importedFrom)
                        let raw = try await AssistantRunner.claudeOneShot(prompt: prompt, system: sys, model: model)
                        let payload = try parse(raw)
                        return (i, payload.memories ?? [], payload.summary)
                    } catch {
                        return (i, [], nil)  // skip this chunk, keep importing the rest
                    }
                }
            }
            for _ in 0..<min(maxConcurrent, total) { schedule() }
            while let (_, drafts, s) = await group.next() {
                allDrafts.append(contentsOf: drafts)
                if summary == nil { summary = s }
                done += 1
                onProgress(done, total)
                schedule()
            }
        }
        return merge(drafts: allDrafts, into: existing, summary: summary, source: source)
    }

    // MARK: - Prompt

    private static func buildPrompt(segments: [TranscriptSegment],
                                    existing: [Memory],
                                    sessionTitle: String?,
                                    importedFrom: String?) -> String {
        let fmt = ISO8601DateFormatter()
        let transcript = segments.map { seg -> String in
            let mark = seg.marked ? " [IMPORTANT\(seg.markers.isEmpty ? "" : ": \(seg.markers.joined(separator: ", "))")]" : ""
            return "(\(fmt.string(from: seg.start)))\(mark) \(seg.text)"
        }.joined(separator: "\n")

        // Give the model the existing memory titles so it can update/link rather than
        // duplicate. Cap to the most recent to keep the prompt bounded.
        let recent = existing.sorted { $0.updated > $1.updated }.prefix(60)
        let existingList = recent.isEmpty ? "(none yet)" :
            recent.map { "- \"\($0.title)\" [\($0.category)]" }.joined(separator: "\n")

        let categories = Category.allCases.map { $0.rawValue }.joined(separator: ", ")
        let sessionLine = sessionTitle.map { "These segments are from a session titled \"\($0)\". Tag relevant memories with category \"Meetings\".\n" } ?? ""

        let sourceLabel: String
        let sourceNote: String
        if let from = importedFrom {
            sourceLabel = "IMPORTED MEMORY NOTES FROM \(from.uppercased())"
            sourceNote = "Reorganize these existing notes into this assistant's memories, preserving every fact."
        } else {
            sourceLabel = "NEW TRANSCRIPT SEGMENTS"
            sourceNote = "Segments tagged [IMPORTANT] were explicitly flagged by the user — capture them and set importance 4–5."
        }

        return """
        \(sessionLine)KNOWN CATEGORIES (prefer these, coin a new one only if none fit): \(categories).

        EXISTING MEMORIES (update one by reusing its EXACT title with action "update"; \
        otherwise create new and reference these titles in "related" when connected):
        \(existingList)

        \(sourceLabel) (\(sourceNote)):
        \(transcript)

        Distill the above into memories. Respond with ONLY this JSON shape, no prose, \
        no markdown fences:
        {
          "summary": "<=2 sentence summary of what these segments were about",
          "memories": [
            {
              "title": "short unique title",
              "content": "the durable note, third person",
              "category": "one of the categories",
              "entities": ["people, projects, or things named"],
              "related": ["titles of other memories this connects to"],
              "importance": 1,
              "action": "create"
            }
          ]
        }
        If nothing is worth remembering, return {"summary": "...", "memories": []}.
        """
    }

    // MARK: - Parse

    private static func parse(_ raw: String) throws -> Payload {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip ```json fences if the model added them despite instructions.
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
            if let r = s.range(of: "```", options: .backwards) { s = String(s[..<r.lowerBound]) }
        }
        // Isolate the outermost JSON object in case of stray text.
        if let first = s.firstIndex(of: "{"), let last = s.lastIndex(of: "}") {
            s = String(s[first...last])
        }
        guard let data = s.data(using: .utf8) else {
            throw NSError(domain: "Nemo", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Consolidator produced unreadable output."])
        }
        return try JSONDecoder().decode(Payload.self, from: data)
    }

    // MARK: - Merge

    private static func merge(drafts: [Draft], into existing: [Memory],
                              summary: String?, source: String) -> Output {
        var memories = existing
        var byTitle: [String: Int] = [:]   // lowercased title -> index
        for (i, m) in memories.enumerated() { byTitle[m.title.lowercased()] = i }

        var created = 0, updated = 0
        // Track titles touched this round so "related" can link new-to-new too.
        var touched: [String: UUID] = [:]

        for draft in drafts {
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !content.isEmpty else { continue }
            let key = title.lowercased()
            let importance = min(5, max(1, draft.importance ?? 2))
            let category = Category.match(draft.category ?? Category.misc.rawValue).rawValue
            let entities = (draft.entities ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if let idx = byTitle[key] {
                memories[idx].content = content
                memories[idx].category = category
                memories[idx].entities = Array(Set(memories[idx].entities + entities)).sorted()
                memories[idx].importance = max(memories[idx].importance, importance)
                memories[idx].updated = Date()
                touched[key] = memories[idx].id
                updated += 1
            } else {
                let mem = Memory(title: title, content: content, category: category,
                                 entities: entities, importance: importance, source: source)
                memories.append(mem)
                byTitle[key] = memories.count - 1
                touched[key] = mem.id
                created += 1
            }
        }

        // Resolve "related" titles into bidirectional links.
        for draft in drafts {
            let key = draft.title.lowercased()
            guard let idx = byTitle[key] else { continue }
            for rel in (draft.related ?? []) {
                let rk = rel.lowercased()
                guard rk != key, let ridx = byTitle[rk] else { continue }
                link(&memories, idx, ridx)
            }
        }

        // Strengthen the graph: link memories that share a named entity.
        linkByEntity(&memories)

        return Output(memories: memories, summary: summary, created: created, updated: updated)
    }

    private static func link(_ memories: inout [Memory], _ a: Int, _ b: Int) {
        guard a != b else { return }
        let idA = memories[a].id, idB = memories[b].id
        if !memories[a].links.contains(idB) { memories[a].links.append(idB) }
        if !memories[b].links.contains(idA) { memories[b].links.append(idA) }
    }

    private static func linkByEntity(_ memories: inout [Memory]) {
        var index: [String: [Int]] = [:]
        for (i, m) in memories.enumerated() {
            for e in m.entities where e.count > 2 {
                index[e.lowercased(), default: []].append(i)
            }
        }
        for (_, idxs) in index where idxs.count > 1 {
            for i in 0..<idxs.count {
                for j in (i + 1)..<idxs.count { link(&memories, idxs[i], idxs[j]) }
            }
        }
    }
}
