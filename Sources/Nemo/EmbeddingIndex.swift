import Foundation
import NaturalLanguage

/// Persisted form of the embedding cache (uuid/​hash as strings so the JSON is portable).
struct EmbeddingCache: Codable {
    var vectors: [String: [Double]]
    var hashes: [String: String]
}

/// On-device sentence-embedding index over the memory graph. Powers semantic relevance in the
/// Surfacer (plan 01) and retrieval for spoken answers (plan 11). Fully local via Apple's
/// NaturalLanguage framework — no network, no new dependency. If the embedding asset is missing
/// (`isAvailable == false`), callers fall back to lexical-only ranking.
///
/// Used exclusively from the main actor (owned by `AppState`); not thread-safe by itself.
final class EmbeddingIndex {
    private let model = NLEmbedding.sentenceEmbedding(for: .english)
    private(set) var vectors: [UUID: [Double]] = [:]   // unit vectors → cosine == dot product
    private var hashes: [UUID: UInt64] = [:]           // stable content hash, to skip re-embedding

    var isAvailable: Bool { model != nil }

    init() { loadCache() }

    /// The text we embed for a memory — the title carries most of the signal, content adds nuance.
    static func text(for m: Memory) -> String { m.title + ". " + m.content }

    /// Embed arbitrary text into a unit vector, or nil if unavailable/empty.
    func vector(for text: String) -> [Double]? {
        guard let model else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let v = model.vector(for: t) else { return nil }
        return Self.normalize(v)
    }

    /// Refresh vectors for `memories`: embed new/changed entries, drop deleted ones. Incremental —
    /// unchanged memories keep their vector untouched. Cheap to call after every consolidation.
    func sync(_ memories: [Memory]) {
        guard isAvailable else { return }
        let ids = Set(memories.map(\.id))
        for id in Array(vectors.keys) where !ids.contains(id) { vectors[id] = nil; hashes[id] = nil }
        var changed = false
        for m in memories {
            let h = Self.stableHash(Self.text(for: m))
            if hashes[m.id] == h, vectors[m.id] != nil { continue }
            if let v = vector(for: Self.text(for: m)) {
                vectors[m.id] = v; hashes[m.id] = h; changed = true
            }
        }
        if changed || vectors.count != memories.count { saveCache() }
    }

    /// Eagerly drop a memory's vector (e.g. on delete) so it can't surface before the next sync.
    func remove(_ id: UUID) { vectors[id] = nil; hashes[id] = nil }

    /// The stored unit vector for a memory, if embedded — used by maintenance to block candidate
    /// pairs semantically without an O(n²) scan (plan 03).
    func storedVector(_ id: UUID) -> [Double]? { vectors[id] }

    /// Cosine similarity between two indexed memories, or nil if either isn't embedded (plan 03).
    func cosine(_ a: UUID, _ b: UUID) -> Double? {
        guard let va = vectors[a], let vb = vectors[b], va.count == vb.count else { return nil }
        return Self.dot(va, vb)   // vectors are unit-normalized → dot == cosine
    }

    /// Top-k memory ids by cosine similarity to `query`, highest first. Scores in [-1, 1].
    func search(_ query: String, limit: Int) -> [(id: UUID, score: Double)] {
        guard limit > 0, !vectors.isEmpty, let q = vector(for: query) else { return [] }
        var scored: [(UUID, Double)] = []
        scored.reserveCapacity(vectors.count)
        for (id, v) in vectors where v.count == q.count { scored.append((id, Self.dot(q, v))) }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { (id: $0.0, score: $0.1) }
    }

    // MARK: - Math

    private static func normalize(_ v: [Double]) -> [Double] {
        let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard norm > 1e-9 else { return v }
        return v.map { $0 / norm }
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }

    /// Deterministic FNV-1a hash — stable across launches (unlike `Hasher`, which is seeded).
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    // MARK: - Persistence

    private func loadCache() {
        guard let cache = Store.loadEmbeddingCache() else { return }
        for (k, v) in cache.vectors { if let id = UUID(uuidString: k) { vectors[id] = v } }
        for (k, v) in cache.hashes { if let id = UUID(uuidString: k), let h = UInt64(v) { hashes[id] = h } }
    }

    private func saveCache() {
        let v = Dictionary(uniqueKeysWithValues: vectors.map { ($0.key.uuidString, $0.value) })
        let h = Dictionary(uniqueKeysWithValues: hashes.map { ($0.key.uuidString, String($0.value)) })
        Store.saveEmbeddingCache(EmbeddingCache(vectors: v, hashes: h))
    }
}
