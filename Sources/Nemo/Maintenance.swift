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

    // MARK: - Dedupe (LLM adjudication + merge)

    private static let dedupeSystem = """
    You are deduplicating a personal memory graph. Each numbered pair is two memories that might \
    describe the SAME underlying fact or item. For each pair, decide if they should be merged. If \
    yes, return one merged title and content preserving EVERY distinct detail (prefer the more \
    specific wording), and which side to keep ("a" or "b"). Be conservative: if they are about \
    different things (e.g. two different people), do not merge. Output ONLY valid JSON.
    """

    private struct DedupeDecision: Decodable {
        var pair: Int; var merge: Bool?; var title: String?; var content: String?; var keep: String?
    }
    private struct DedupePayload: Decodable { var merges: [DedupeDecision]? }

    /// One approved merge, by memory id.
    struct MergeAction: Equatable { var keep: UUID; var drop: UUID; var title: String; var content: String }

    /// Ask the cheap model which candidate pairs are genuine duplicates, then apply the merges.
    static func dedupe(memories: [Memory], pairs: [(Int, Int)], model: String?) async throws -> Output {
        guard !pairs.isEmpty else { return Output(memories: memories, summary: nil, created: 0, updated: 0) }
        let listed = pairs.enumerated().map { idx, p in
            """
            PAIR \(idx):
            A: "\(memories[p.0].title)" — \(memories[p.0].content)
            B: "\(memories[p.1].title)" — \(memories[p.1].content)
            """
        }.joined(separator: "\n\n")

        let prompt = """
        Candidate duplicate pairs:
        \(listed)

        Respond with ONLY this JSON, no prose, no markdown fences:
        {"merges":[{"pair":0,"merge":true,"title":"merged title","content":"merged content","keep":"a"}]}
        Include only pairs you decided to merge (merge:true). If none, return {"merges":[]}.
        """
        let raw = try await AssistantRunner.claudeOneShot(prompt: prompt, system: dedupeSystem,
                                                          model: model, feature: "dedupe")
        let payload: DedupePayload = try parseJSON(raw)

        var actions: [MergeAction] = []
        for d in (payload.merges ?? []) where (d.merge ?? true) {
            guard d.pair >= 0, d.pair < pairs.count else { continue }
            let p = pairs[d.pair]
            let a = memories[p.0], b = memories[p.1]
            // Never silently overwrite a user-edited memory: keep its side and its wording.
            let keepA: Bool
            if a.userEdited && !b.userEdited { keepA = true }
            else if b.userEdited && !a.userEdited { keepA = false }
            else { keepA = (d.keep?.lowercased() != "b") }
            let keep = keepA ? a : b, drop = keepA ? b : a
            let title = keep.userEdited ? keep.title : (d.title ?? keep.title)
            let content = keep.userEdited ? keep.content : (d.content ?? keep.content)
            actions.append(MergeAction(keep: keep.id, drop: drop.id, title: title, content: content))
        }
        return Output(memories: applyMerges(memories, actions), summary: nil, created: 0, updated: actions.count)
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
