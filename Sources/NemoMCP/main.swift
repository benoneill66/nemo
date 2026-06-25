import Foundation
import NaturalLanguage

// Nemo MCP server (plan 12). A small, dependency-free stdio JSON-RPC server that exposes Nemo's
// memory graph (read-only) to MCP clients like Claude Code / Claude Desktop, so they can reach the
// user's real-world spoken context. It reads the same on-device JSON store the app writes; it never
// touches audio and opens no network listener.
//
// Register with:  claude mcp add nemo -- /path/to/NemoMCP

// MARK: - Store (subset decoders over Nemo's JSON — Decodable ignores fields we don't declare)

struct MCPMemory: Decodable {
    var id: UUID
    var title: String
    var content: String
    var category: String
    var entities: [String]
    var importance: Int
    var updated: Date?
    var superseded: Bool?
}

struct MCPSegment: Decodable {
    var id: UUID
    var text: String
    var start: Date
}

private struct EmbeddingCacheDTO: Decodable { var vectors: [String: [Double]] }

enum DataStore {
    static let dir = ("~/.config/nemo/data" as NSString).expandingTildeInPath

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
    private static func load<T: Decodable>(_ file: String, _ type: T.Type) -> T? {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(T.self, from: data)
    }

    static func memories() -> [MCPMemory] {
        (load("memories.json", [MCPMemory].self) ?? []).filter { !($0.superseded ?? false) }
    }
    static func segments() -> [MCPSegment] { load("transcript.json", [MCPSegment].self) ?? [] }
    static func embeddings() -> [String: [Double]] {
        load("embeddings.json", EmbeddingCacheDTO.self)?.vectors ?? [:]
    }
}

// MARK: - Search (semantic via NLEmbedding over the cached vectors, with a lexical fallback)

enum Search {
    private static let model = NLEmbedding.sentenceEmbedding(for: .english)

    private static func normalize(_ v: [Double]) -> [Double] {
        let n = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        return n > 1e-9 ? v.map { $0 / n } : v
    }
    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0; for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }; return s
    }

    static func memories(matching query: String, limit: Int) -> [MCPMemory] {
        let mems = DataStore.memories()
        let vectors = DataStore.embeddings()
        if let model, let qv = model.vector(for: query), !vectors.isEmpty {
            let q = normalize(qv)
            let scored = mems.compactMap { m -> (MCPMemory, Double)? in
                guard let v = vectors[m.id.uuidString], v.count == q.count else { return nil }
                return (m, dot(q, normalize(v)))
            }.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
            if !scored.isEmpty { return Array(scored) }
        }
        return lexical(query, mems, limit: limit)
    }

    static func lexical(_ query: String, _ mems: [MCPMemory], limit: Int) -> [MCPMemory] {
        let terms = query.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init).filter { $0.count >= 3 }
        guard !terms.isEmpty else { return Array(mems.prefix(limit)) }
        return mems.filter { m in
            let hay = (m.title + " " + m.content + " " + m.entities.joined(separator: " ")).lowercased()
            return terms.contains { hay.contains($0) }
        }.prefix(limit).map { $0 }
    }
}

// MARK: - Tool implementations (return human/JSON text)

enum Tools {
    static func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private static func dto(_ m: MCPMemory) -> [String: Any] {
        ["id": m.id.uuidString, "title": m.title, "content": m.content,
         "category": m.category, "importance": m.importance, "entities": m.entities]
    }

    static func call(_ name: String, _ args: [String: Any]) -> String {
        let limit = (args["limit"] as? Int) ?? 8
        switch name {
        case "search_memories":
            let q = (args["query"] as? String) ?? ""
            return json(Search.memories(matching: q, limit: limit).map(dto))
        case "list_recent":
            var mems = DataStore.memories()
            if let cat = args["category"] as? String, !cat.isEmpty {
                mems = mems.filter { $0.category.lowercased() == cat.lowercased() }
            }
            mems.sort { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
            return json(mems.prefix(limit).map(dto))
        case "list_action_items":
            let tasks = DataStore.memories()
                .filter { $0.category.lowercased() == "action items" }
                .sorted { $0.importance > $1.importance }
            return json(tasks.prefix(limit).map(dto))
        case "search_transcript":
            let q = (args["query"] as? String).map { $0.lowercased() } ?? ""
            let fmt = ISO8601DateFormatter()
            let hits = DataStore.segments().filter { q.isEmpty || $0.text.lowercased().contains(q) }
                .suffix(limit)
                .map { ["text": $0.text, "at": fmt.string(from: $0.start)] as [String: Any] }
            return json(Array(hits))
        default:
            return "Unknown tool: \(name)"
        }
    }

    static let definitions: [[String: Any]] = [
        [
            "name": "search_memories",
            "description": "Semantic + keyword search over the user's Nemo memory graph (decisions, action items, people, preferences, facts captured from speech). Returns the most relevant memories.",
            "inputSchema": ["type": "object",
                            "properties": ["query": ["type": "string", "description": "What to look for"],
                                           "limit": ["type": "integer", "description": "Max results (default 8)"]],
                            "required": ["query"]]
        ],
        [
            "name": "list_recent",
            "description": "List the user's most recently updated memories, optionally filtered by category.",
            "inputSchema": ["type": "object",
                            "properties": ["category": ["type": "string"],
                                           "limit": ["type": "integer"]]]
        ],
        [
            "name": "list_action_items",
            "description": "List the user's open action items captured by Nemo, most important first.",
            "inputSchema": ["type": "object", "properties": ["limit": ["type": "integer"]]]
        ],
        [
            "name": "search_transcript",
            "description": "Search the user's retained speech transcript for a phrase.",
            "inputSchema": ["type": "object",
                            "properties": ["query": ["type": "string"], "limit": ["type": "integer"]],
                            "required": ["query"]]
        ],
    ]
}

// MARK: - JSON-RPC over stdio (newline-delimited)

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}
func respond(id: Any?, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
}
func respondError(id: Any?, code: Int, message: String) {
    send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    let method = msg["method"] as? String ?? ""
    let id = msg["id"]
    let params = msg["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        respond(id: id, result: ["protocolVersion": "2024-11-05",
                                 "capabilities": ["tools": [String: Any]()],
                                 "serverInfo": ["name": "nemo", "version": "1.0"]])
    case "notifications/initialized":
        continue   // notification, no response
    case "ping":
        respond(id: id, result: [:])
    case "tools/list":
        respond(id: id, result: ["tools": Tools.definitions])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        respond(id: id, result: ["content": [["type": "text", "text": Tools.call(name, args)]]])
    default:
        if id != nil { respondError(id: id, code: -32601, message: "Method not found: \(method)") }
    }
}
