import Foundation

/// Periodic maintenance of the memory graph (plans 03 & 04): collapse near-duplicate memories so
/// the graph stays crisp, without re-running expensive consolidation. Two stages — free on-device
/// candidate generation, then a cheap LLM adjudication only on the candidates.
extension Consolidator {

    // MARK: - Candidate generation (on-device, free)

    private static func memTokens(_ m: Memory) -> Set<String> {
        Set(Surfacer.tokens(m.title + " " + m.content))
    }
    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let uni = a.union(b).count
        return uni == 0 ? 0 : Double(a.intersection(b).count) / Double(uni)
    }
    private static func sharesEntity(_ a: Memory, _ b: Memory) -> Bool {
        !Set(a.entities.map { $0.lowercased() })
            .intersection(b.entities.map { $0.lowercased() }).isEmpty
    }

    /// Index pairs likely to be duplicates: embedding cosine ≥ threshold when available, else a
    /// shared-entity + high token-Jaccard fallback. Skips archived (superseded) memories.
    static func candidatePairs(_ memories: [Memory],
                               cosine: (Int, Int) -> Double?,
                               cosineThreshold: Double,
                               jaccardThreshold: Double = 0.6) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        let toks = memories.map { memTokens($0) }
        for i in 0..<memories.count where !memories[i].superseded {
            for j in (i + 1)..<memories.count where !memories[j].superseded {
                if let c = cosine(i, j) {
                    if c >= cosineThreshold { pairs.append((i, j)) }
                } else if sharesEntity(memories[i], memories[j]),
                          jaccard(toks[i], toks[j]) >= jaccardThreshold {
                    pairs.append((i, j))
                }
            }
        }
        return pairs
    }

    /// Categories where a contradiction (a changed fact/date/status) is worth nominating even when
    /// similarity is only moderate (plan 04).
    private static let actionableCategories: Set<String> =
        [Category.decisions, .tasks, .facts, .questions].map { $0.rawValue }.reduce(into: Set()) { $0.insert($1) }

    /// Nominate pairs that may *contradict* rather than duplicate: same named entity, both in an
    /// actionable category. The LLM decides whether one actually supersedes the other.
    static func contradictionPairs(_ memories: [Memory]) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        for i in 0..<memories.count where !memories[i].superseded && actionableCategories.contains(memories[i].category) {
            for j in (i + 1)..<memories.count where !memories[j].superseded && actionableCategories.contains(memories[j].category) {
                if sharesEntity(memories[i], memories[j]) { pairs.append((i, j)) }
            }
        }
        return pairs
    }

    /// Union of duplicate and contradiction candidates, de-duplicated by unordered index pair.
    static func maintenancePairs(_ memories: [Memory], cosine: (Int, Int) -> Double?,
                                 cosineThreshold: Double) -> [(Int, Int)] {
        let dup = candidatePairs(memories, cosine: cosine, cosineThreshold: cosineThreshold)
        let con = contradictionPairs(memories)
        var seen = Set<String>(); var out: [(Int, Int)] = []
        for p in dup + con {
            let key = "\(min(p.0, p.1))-\(max(p.0, p.1))"
            if seen.insert(key).inserted { out.append((min(p.0, p.1), max(p.0, p.1))) }
        }
        return out
    }

    // MARK: - Maintenance (LLM adjudication: duplicate | supersedes | distinct)

    private static let maintainSystem = """
    You maintain a personal memory graph. Each numbered pair is two memories that may overlap. For \
    each, classify the relation: "duplicate" (same underlying fact/item — should be merged), \
    "supersedes" (one UPDATES or OVERRIDES the other, e.g. a changed date, decision, status, or \
    number), or "distinct" (about different things — leave both). For "duplicate", give a merged \
    title and content preserving every distinct detail, and which side to keep ("a"/"b"). For \
    "supersedes", say which side is NEWER ("a"/"b") using the given timestamps, and a one-line note \
    of what changed. Be conservative: when unsure, answer "distinct". Output ONLY valid JSON.
    """

    private struct Decision: Decodable {
        var pair: Int
        var relation: String?            // "duplicate" | "supersedes" | "distinct"
        var title: String?; var content: String?; var keep: String?   // duplicate
        var newer: String?; var note: String?                         // supersedes
    }
    private struct MaintainPayload: Decodable { var pairs: [Decision]? }

    /// One approved merge, by memory id.
    struct MergeAction: Equatable { var keep: UUID; var drop: UUID; var title: String; var content: String }
    /// One approved supersession: `older` is archived, pointing at the live `newer`.
    struct SupersedeAction: Equatable { var newer: UUID; var older: UUID; var note: String }

    /// Adjudicate candidate pairs and apply both merges (duplicates) and supersessions.
    static func maintain(memories: [Memory], pairs: [(Int, Int)], model: String?) async throws -> Output {
        guard !pairs.isEmpty else { return Output(memories: memories, summary: nil, created: 0, updated: 0) }
        let fmt = ISO8601DateFormatter()
        let listed = pairs.enumerated().map { idx, p in
            """
            PAIR \(idx):
            A (updated \(fmt.string(from: memories[p.0].updated))): "\(memories[p.0].title)" — \(memories[p.0].content)
            B (updated \(fmt.string(from: memories[p.1].updated))): "\(memories[p.1].title)" — \(memories[p.1].content)
            """
        }.joined(separator: "\n\n")

        let prompt = """
        Candidate pairs:
        \(listed)

        Respond with ONLY this JSON, no prose, no markdown fences:
        {"pairs":[
          {"pair":0,"relation":"duplicate","title":"merged","content":"merged body","keep":"a"},
          {"pair":1,"relation":"supersedes","newer":"b","note":"deadline moved Sep 30 -> Oct 15"}
        ]}
        Omit pairs you judge "distinct".
        """
        let raw = try await AssistantRunner.claudeOneShot(prompt: prompt, system: maintainSystem,
                                                          model: model, feature: "maintain")
        let payload: MaintainPayload = try parseJSON(raw)

        var merges: [MergeAction] = []
        var supersedes: [SupersedeAction] = []
        for d in (payload.pairs ?? []) {
            guard d.pair >= 0, d.pair < pairs.count else { continue }
            let p = pairs[d.pair]
            let a = memories[p.0], b = memories[p.1]
            switch (d.relation ?? "distinct").lowercased() {
            case "duplicate":
                let keepA: Bool
                if a.userEdited && !b.userEdited { keepA = true }
                else if b.userEdited && !a.userEdited { keepA = false }
                else { keepA = (d.keep?.lowercased() != "b") }
                let keep = keepA ? a : b, drop = keepA ? b : a
                merges.append(MergeAction(keep: keep.id, drop: drop.id,
                                          title: keep.userEdited ? keep.title : (d.title ?? keep.title),
                                          content: keep.userEdited ? keep.content : (d.content ?? keep.content)))
            case "supersedes":
                let newerIsB = (d.newer?.lowercased() == "b")
                let newer = newerIsB ? b : a, older = newerIsB ? a : b
                supersedes.append(SupersedeAction(newer: newer.id, older: older.id,
                                                  note: d.note ?? "Updated; previous version archived."))
            default:
                continue   // distinct → leave both
            }
        }
        let afterMerge = applyMerges(memories, merges)
        let afterSupersede = applySupersede(afterMerge, supersedes)
        return Output(memories: afterSupersede, summary: nil, created: 0, updated: merges.count + supersedes.count)
    }

    /// Archive each older memory, point it at the live newer one, and append a history note to the
    /// survivor. Skips ids missing (e.g. already merged) or already archived. Pure & testable.
    static func applySupersede(_ memories: [Memory], _ actions: [SupersedeAction]) -> [Memory] {
        var byId = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0) })
        for act in actions {
            guard var older = byId[act.older], var newer = byId[act.newer],
                  act.older != act.newer, !older.superseded else { continue }
            older.superseded = true
            older.supersededBy = act.newer
            byId[act.older] = older
            if !act.note.isEmpty { newer.history.append(act.note) }
            newer.updated = Date()
            byId[act.newer] = newer
        }
        return memories.map { byId[$0.id] ?? $0 }
    }

    /// Resolve a supersede chain to the live head memory id (plan 04).
    static func liveHead(_ id: UUID, in byId: [UUID: Memory]) -> UUID {
        var current = id
        var guardCount = 0
        while let m = byId[current], m.superseded, let next = m.supersededBy, guardCount < 64 {
            current = next; guardCount += 1
        }
        return current
    }

    /// Fold each dropped memory into its kept one (union entities/links/provenance, max importance/
    /// weight, sum hitCount), repoint inbound links, then remove the dropped. Pure & testable.
    static func applyMerges(_ memories: [Memory], _ actions: [MergeAction]) -> [Memory] {
        var byId = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0) })
        var order = memories.map(\.id)

        for act in actions {
            guard var keep = byId[act.keep], let drop = byId[act.drop], act.keep != act.drop else { continue }
            keep.title = act.title
            keep.content = act.content
            keep.entities = Array(Set(keep.entities + drop.entities)).sorted()
            keep.links = Array(Set(keep.links + drop.links)).filter { $0 != act.keep && $0 != act.drop }
            keep.importance = max(keep.importance, drop.importance)
            keep.weight = max(keep.weight, drop.weight)
            keep.hitCount += drop.hitCount
            keep.sourceSegmentIds = Array(Set(keep.sourceSegmentIds + drop.sourceSegmentIds).prefix(20))
            keep.userEdited = keep.userEdited || drop.userEdited
            keep.pinned = keep.pinned || drop.pinned
            keep.history += drop.history
            keep.updated = Date()
            byId[act.keep] = keep
            byId[act.drop] = nil
            order.removeAll { $0 == act.drop }
            // Repoint any other memory's links from the dropped id to the kept id.
            for (id, var m) in byId where m.links.contains(act.drop) {
                m.links = Array(Set(m.links.map { $0 == act.drop ? act.keep : $0 })).filter { $0 != id }
                byId[id] = m
            }
        }
        return order.compactMap { byId[$0] }
    }
}
