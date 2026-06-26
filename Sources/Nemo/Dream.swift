import Foundation

/// The "dream" consolidation pass (plan 17). Models the memory store on human memory: new and
/// imported memories are born `episodic` (fragile, fast forgetting curve) and must earn promotion
/// to `semantic` (durable). A periodic offline sweep recategorizes mis-binned notes, promotes what's
/// been reinforced, and forgets what hasn't (archive → purge after a grace window).
///
/// The lifecycle (promote / decay / forget / purge) is pure and unit-tested. Recategorize + triage
/// and abstraction (clustering specifics into one durable gist, plan 17 §3.2) are cheap-model LLM
/// steps; their apply logic is pure and tested.
enum Dream {

    // MARK: - Lifecycle (pure, no LLM)

    struct Lifecycle {
        var memories: [Memory]
        var promoted = 0
        var demoted = 0
        var archived = 0
        var purged = 0
        var changed: Bool { promoted + demoted + archived + purged > 0 }
    }

    /// True when an episodic memory has earned durable (semantic) status: surfaced enough, marked
    /// important, owned by the user, or durable by category.
    static func shouldPromote(_ m: Memory, promoteHitCount: Int) -> Bool {
        guard m.stage == .episodic else { return false }
        if m.pinned || m.userEdited { return true }
        if m.hitCount >= promoteHitCount || m.importance >= 4 { return true }
        switch m.categoryEnum {
        case .decisions, .people, .preferences: return true
        default: return false
        }
    }

    /// One full lifecycle sweep. Recomputes each memory's retention along the forgetting curve
    /// (episodic memories decay faster than semantic), promotes the durable, demotes cold semantics,
    /// archives episodics that fall below the floor, and purges long-archived memories past the grace
    /// window. User-pinned and user-edited memories are exempt from forgetting and purge throughout.
    static func runLifecycle(_ input: [Memory], now: Date,
                             episodicHalfLife: Double, semanticHalfLife: Double,
                             retentionFloor: Double, purgeGraceDays: Int,
                             promoteHitCount: Int) -> Lifecycle {
        var memories = input
        var out = Lifecycle(memories: [])

        // 1. Promote durable episodics; floor their retention so they don't immediately decay out.
        var promotedNow = Set<Int>()
        for i in memories.indices where shouldPromote(memories[i], promoteHitCount: promoteHitCount) {
            memories[i].stage = .semantic
            memories[i].retention = max(memories[i].retention, Reinforcement.retentionMax)
            promotedNow.insert(i)
            out.promoted += 1
        }

        // 2. Decay retention along the curve; 3. archive / demote on the result.
        for i in memories.indices {
            let m = memories[i]
            guard !m.superseded else { continue }
            if promotedNow.contains(i) { continue }   // just earned semantic — don't decay it back out this pass
            // User-owned memories never decay or forget.
            if m.pinned || m.userEdited { memories[i].retention = Reinforcement.retentionMax; continue }

            let ref = m.lastSurfaced ?? m.updated
            let base = m.stage == .semantic ? semanticHalfLife : episodicHalfLife
            let r = Reinforcement.retained(m.retention, lastRef: ref, now: now,
                                           halfLifeDays: base, importance: m.importance,
                                           linkCount: m.links.count)
            memories[i].retention = r

            guard retentionFloor > 0, r < retentionFloor else { continue }
            if m.stage == .semantic {
                // Never archive a semantic memory outright — demote it; it gets a cycle as episodic
                // (and a chance to re-surface) before it can be forgotten.
                memories[i].stage = .episodic
                out.demoted += 1
            } else {
                memories[i].superseded = true
                memories[i].archivedAt = now
                memories[i].history.append("Forgotten by dream (retention \(String(format: "%.2f", r)) < floor)")
                memories[i].updated = now
                out.archived += 1
            }
        }

        // 4. Purge: episodic memories archived by the forgetting curve and untouched past the grace
        //    window are hard-removed, and their ids scrubbed from every other memory's links.
        if purgeGraceDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(purgeGraceDays) * 86_400)
            let purgeIds = Set(memories.filter {
                $0.superseded && !$0.pinned && !$0.userEdited && $0.stage == .episodic
                    && ($0.archivedAt.map { $0 < cutoff } ?? false)
            }.map(\.id))
            if !purgeIds.isEmpty {
                memories.removeAll { purgeIds.contains($0.id) }
                for i in memories.indices { memories[i].links.removeAll { purgeIds.contains($0) } }
                out.purged = purgeIds.count
            }
        }

        out.memories = memories
        return out
    }

    // MARK: - Recategorize + triage (LLM)

    /// One model verdict for a memory, keyed by the short id (first 8 chars of the UUID) the prompt uses.
    struct Verdict: Decodable { var sid: String; var action: String?; var category: String? }
    private struct TriagePayload: Decodable { var decisions: [Verdict]? }

    private static let triageSystem = """
    You are the "dream" consolidation engine of a personal always-listening memory assistant. During \
    sleep you reorganize recent memories: fix mis-categorized notes, and forget what isn't durable. \
    Many memories are imported from the user's coding/work tools and include ephemeral implementation \
    details (migration status, code line refs, config values, one-off debugging, point-in-time \
    metrics) that do NOT belong in a long-term life/work memory; others ARE durable (product/company \
    facts, real decisions, ongoing project goals, people, preferences). For each memory decide an \
    action: "keep" or "archive" (archive = forget; choose it for ephemeral trivia, stale status, or \
    anything with no value weeks later), and the best category. Be conservative: never archive a real \
    decision, a person, a money/business fact, or an active project. Output ONLY valid JSON.
    """

    /// Recategorize + triage a set of memories with the cheap model, in bounded batches. Returns the
    /// model's verdicts keyed by full memory id. A batch that fails to parse is skipped (the rest
    /// still apply), mirroring the resilience of `consolidateConcurrent`.
    static func triage(_ memories: [Memory], model: String?, batchSize: Int = 24) async -> [UUID: Verdict] {
        guard !memories.isEmpty else { return [:] }
        let categories = Category.allCases.map(\.rawValue).joined(separator: ", ")
        var byShort: [String: UUID] = [:]
        for m in memories { byShort[String(m.id.uuidString.prefix(8))] = m.id }

        var verdicts: [UUID: Verdict] = [:]
        for start in stride(from: 0, to: memories.count, by: batchSize) {
            let batch = Array(memories[start..<min(start + batchSize, memories.count)])
            let lines = batch.map { m -> String in
                let snip = m.content.replacingOccurrences(of: "\n", with: " ").prefix(480)
                let last = m.lastSurfaced.map { "\(Int(Date().timeIntervalSince($0) / 86_400))" } ?? "never"
                return """
                {"sid":"\(m.id.uuidString.prefix(8))","title":\(json(m.title)),"category":"\(m.category)",\
                "importance":\(m.importance),"hitCount":\(m.hitCount),"lastSurfacedDays":"\(last)",\
                "content":\(json(String(snip)))}
                """
            }.joined(separator: "\n")

            let prompt = """
            ALLOWED CATEGORIES: \(categories).

            MEMORIES (one JSON per line):
            \(lines)

            For EVERY sid return a decision. hitCount 0 with low importance and an implementation \
            flavour is a strong archive signal; durable business/people/decision facts are keep. \
            Respond with ONLY this JSON, no prose, no fences:
            {"decisions":[{"sid":"abcd1234","action":"keep","category":"Facts"}]}
            """
            guard let raw = try? await AssistantRunner.claudeOneShot(prompt: prompt, system: triageSystem,
                                                                     model: model, feature: "dream"),
                  let payload: TriagePayload = try? Consolidator.parseJSON(raw) else { continue }
            for v in (payload.decisions ?? []) {
                if let id = byShort[v.sid] { verdicts[id] = v }
            }
        }
        return verdicts
    }

    /// Apply triage verdicts to the graph (pure): recategorize "keep" verdicts that changed category,
    /// and archive "archive" verdicts (soft — reuses `superseded`, restorable). User-pinned/edited
    /// memories are never touched. Returns the new graph plus counts.
    static func applyTriage(_ input: [Memory], _ verdicts: [UUID: Verdict], now: Date)
    -> (memories: [Memory], recategorized: Int, archived: Int) {
        var memories = input
        var recat = 0, arch = 0
        for i in memories.indices {
            guard let v = verdicts[memories[i].id] else { continue }
            if memories[i].pinned || memories[i].userEdited { continue }
            switch (v.action ?? "keep").lowercased() {
            case "archive" where !memories[i].superseded:
                memories[i].superseded = true
                memories[i].archivedAt = now
                memories[i].history.append("Archived by dream")
                memories[i].updated = now
                arch += 1
            default:
                if let c = v.category {
                    let mapped = Category.match(c).rawValue
                    if mapped != memories[i].category {
                        memories[i].history.append("Recategorized \(memories[i].category)→\(mapped) (dream)")
                        memories[i].category = mapped
                        memories[i].updated = now
                        recat += 1
                    }
                }
            }
        }
        return (memories, recat, arch)
    }

    // MARK: - Abstraction: cluster → gist (plan 17 §3.2)

    /// A consolidated memory the model distilled from a cluster of specifics, plus which sources it
    /// fully subsumes (to be archived) versus merely relates to (linked, kept).
    struct Abstraction {
        var memberIds: [UUID]    // every cluster member — linked to the gist
        var subsumedIds: [UUID]  // members fully folded into the gist — archived (restorable)
        var title: String
        var content: String
        var category: String
        var entities: [String]
    }

    /// Group fragile (episodic, non-archived, non-user-owned) memories into clusters that share a
    /// named entity. Greedy and non-overlapping — largest clusters first, each memory consumed once —
    /// so a memory is abstracted into at most one gist per dream. Returns clusters of size ≥ `minSize`.
    static func entityClusters(_ memories: [Memory], minSize: Int) -> [[UUID]] {
        var byEntity: [String: [UUID]] = [:]
        for m in memories where m.stage == .episodic && !m.superseded && !m.pinned && !m.userEdited {
            for e in m.entities where e.count > 2 { byEntity[e.lowercased(), default: []].append(m.id) }
        }
        var used = Set<UUID>(); var clusters: [[UUID]] = []
        for (_, ids) in byEntity.sorted(by: { $0.value.count > $1.value.count }) {
            let fresh = Array(Set(ids)).filter { !used.contains($0) }
            if fresh.count >= minSize { clusters.append(fresh); fresh.forEach { used.insert($0) } }
        }
        return clusters
    }

    private struct GistResult: Decodable {
        var title: String; var content: String
        var category: String?; var entities: [String]?; var subsumes: [String]?
    }

    private static let abstractSystem = """
    You are the abstraction step of a memory assistant's "dream" consolidation. You receive a cluster \
    of specific memories that all concern the same entity/topic. Distill them into ONE durable, \
    higher-level memory — the gist a person would retain weeks later — preserving every distinct fact \
    while dropping incidental specifics. Then list which source memories are FULLY captured by your \
    gist (so they can be archived); leave out any source that still holds a distinct detail worth \
    keeping on its own. Never invent. Output ONLY valid JSON.
    """

    /// Ask the model to consolidate each cluster into one gist memory. Bounded: at most `maxClusters`
    /// clusters, at most `maxPerCluster` members each. A cluster that fails to parse is skipped.
    static func abstract(_ clusters: [[UUID]], from memories: [Memory], model: String?,
                         maxClusters: Int = 6, maxPerCluster: Int = 12) async -> [Abstraction] {
        guard !clusters.isEmpty else { return [] }
        let byId = Dictionary(memories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Abstraction] = []
        for cluster in clusters.prefix(maxClusters) {
            let members = cluster.prefix(maxPerCluster).compactMap { byId[$0] }
            guard members.count >= 2 else { continue }
            let lines = members.map { m -> String in
                let snip = m.content.replacingOccurrences(of: "\n", with: " ").prefix(420)
                return "{\"sid\":\"\(m.id.uuidString.prefix(8))\",\"title\":\(json(m.title)),\"content\":\(json(String(snip)))}"
            }.joined(separator: "\n")
            let prompt = """
            CLUSTER (memories one JSON per line):
            \(lines)

            Distill into ONE gist. Respond with ONLY this JSON, no prose, no fences:
            {"title":"short title","content":"durable gist, third person","category":"a category",\
            "entities":["named things"],"subsumes":["sid of each source fully captured"]}
            """
            guard let raw = try? await AssistantRunner.claudeOneShot(prompt: prompt, system: abstractSystem,
                                                                     model: model, feature: "dream"),
                  let g: GistResult = try? Consolidator.parseJSON(raw),
                  !g.title.trimmingCharacters(in: .whitespaces).isEmpty,
                  !g.content.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let shortToId = Dictionary(members.map { (String($0.id.uuidString.prefix(8)), $0.id) },
                                       uniquingKeysWith: { a, _ in a })
            let subsumed = (g.subsumes ?? []).compactMap { shortToId[$0] }
            out.append(Abstraction(memberIds: members.map(\.id), subsumedIds: subsumed,
                                   title: g.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                   content: g.content.trimmingCharacters(in: .whitespacesAndNewlines),
                                   category: Category.match(g.category ?? Category.misc.rawValue).rawValue,
                                   entities: (g.entities ?? []).filter { !$0.isEmpty }))
        }
        return out
    }

    /// Apply abstractions (pure): create each gist as a durable `semantic` memory linked to its cluster
    /// members, and archive the fully-subsumed sources (soft — restorable, pointing back at the gist).
    /// User-pinned/edited sources are never subsumed — they're kept and just linked to the gist.
    static func applyAbstractions(_ input: [Memory], _ abstractions: [Abstraction], now: Date)
    -> (memories: [Memory], created: Int, subsumed: Int) {
        var memories = input
        var idx = Dictionary(memories.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var created = 0, subsumed = 0

        for a in abstractions {
            let liveMembers = a.memberIds.filter { idx[$0].map { !memories[$0].superseded } ?? false }
            guard liveMembers.count >= 2 else { continue }

            var gist = Memory(title: a.title, content: a.content, category: a.category,
                              entities: a.entities, importance: 2, source: "dream:abstract")
            gist.stage = .semantic
            gist.retention = Reinforcement.retentionMax
            gist.importance = max(2, liveMembers.compactMap { idx[$0].map { memories[$0].importance } }.max() ?? 2)
            gist.links = liveMembers
            gist.history.append("Distilled from \(liveMembers.count) memories by dream")
            let gistId = gist.id
            memories.append(gist)
            idx[gistId] = memories.count - 1
            created += 1

            for mid in liveMembers {
                guard let i = idx[mid] else { continue }
                if !memories[i].links.contains(gistId) { memories[i].links.append(gistId) }
                // Subsume (archive) only fully-captured, non-user-owned sources.
                if a.subsumedIds.contains(mid), !memories[i].pinned, !memories[i].userEdited {
                    memories[i].superseded = true
                    memories[i].supersededBy = gistId
                    memories[i].archivedAt = now
                    memories[i].history.append("Folded into \"\(a.title)\" by dream")
                    memories[i].updated = now
                    subsumed += 1
                }
            }
        }
        return (memories, created, subsumed)
    }

    /// Minimal JSON string escaping for embedding titles/content into the prompt safely.
    private static func json(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
