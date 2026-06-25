import Foundation

/// Seeds the memory graph from what other AI assistants already know about the user.
/// It auto-discovers Claude's file-based memories (and any extra paths configured),
/// then runs them through the consolidator under an "import" framing.
enum ContextImporter {

    struct Source: Identifiable, Hashable {
        var id: String { path }
        var assistant: String   // e.g. "claude"
        var label: String       // human label for the UI
        var path: String        // file or directory
        var fileCount: Int
    }

    private static let fm = FileManager.default
    private static var home: String { NSHomeDirectory() }

    /// Finds importable memory locations on this machine.
    static func discover() -> [Source] {
        var sources: [Source] = []

        // Claude Code keeps per-project memory dirs and MEMORY.md indexes.
        let claudeRoots = [
            "\(home)/.claude/projects",
            "\(home)/.claude"
        ]
        var claudeFiles: [String] = []
        for root in claudeRoots {
            claudeFiles += markdownFiles(under: root, matching: { name in
                let n = name.lowercased()
                return n == "memory.md" || n.hasSuffix(".md") && root.hasSuffix("memory")
            })
        }
        // Also any directory literally named "memory".
        claudeFiles += memoryDirFiles(under: "\(home)/.claude")
        // Global CLAUDE.md user instructions are rich context too.
        for g in ["\(home)/.claude/CLAUDE.md"] where fm.fileExists(atPath: g) { claudeFiles.append(g) }

        claudeFiles = Array(Set(claudeFiles)).sorted()
        if !claudeFiles.isEmpty {
            sources.append(Source(assistant: "claude", label: "Claude memory & CLAUDE.md",
                                  path: "\(home)/.claude", fileCount: claudeFiles.count))
        }

        // User-configured extra paths (could be a ChatGPT export, notes, etc.).
        for p in Config.importPaths {
            let expanded = (p as NSString).expandingTildeInPath
            let count = isDir(expanded) ? markdownFiles(under: expanded, matching: { _ in true }).count
                                        : (fm.fileExists(atPath: expanded) ? 1 : 0)
            if count > 0 {
                sources.append(Source(assistant: "custom",
                                      label: (expanded as NSString).lastPathComponent,
                                      path: expanded, fileCount: count))
            }
        }
        return sources
    }

    /// Reads a source's text (bounded), distills it via the consolidator, and returns the
    /// merged memory set. Chunks are large and distilled **concurrently** so importing a big
    /// memory store takes a couple of minutes, not many. `onProgress(done, total)` reports
    /// chunk completion for the UI.
    static func importSource(_ source: Source, into existing: [Memory], model: String?,
                             onProgress: @Sendable @escaping (Int, Int) -> Void = { _, _ in })
    async throws -> Consolidator.Output {
        let files: [String] = isDir(source.path)
            ? collectFiles(for: source)
            : [source.path]

        let blob = files.compactMap { path -> String? in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let rel = (path as NSString).lastPathComponent
            return "### \(rel)\n\(trimmed)"
        }.joined(separator: "\n\n")

        guard !blob.isEmpty else {
            throw NSError(domain: "Nemo", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No readable memory found in \(source.label)."])
        }

        // Larger chunks → far fewer LLM calls; the model handles big context easily.
        let batches = chunked(blob, maxChars: 40_000).map { [TranscriptSegment(text: $0, start: Date(), end: Date())] }
        return await Consolidator.consolidateConcurrent(batches: batches, existing: existing,
                                                        model: model, importedFrom: source.assistant,
                                                        onProgress: onProgress)
    }

    // MARK: - Structured (no-LLM) import

    /// Claude's memory files are already one-fact-per-file with frontmatter and `[[links]]`.
    /// We parse them straight into memories — instant, and it preserves the existing
    /// categories and interconnections instead of paying an LLM to re-derive them.
    static func importClaudeStructured(into existing: [Memory]) -> Consolidator.Output {
        let files = memoryDirFiles(under: "\(home)/.claude")
        let titleMap = indexTitleMap(files)        // slug -> nice title from MEMORY.md
        let parsed = files.compactMap { parseMemoryFile($0, titleMap: titleMap) }
        guard !parsed.isEmpty else {
            return Consolidator.Output(memories: existing, summary: nil, created: 0, updated: 0)
        }

        var memories = existing
        var byTitle: [String: Int] = [:]
        for (i, m) in memories.enumerated() { byTitle[m.title.lowercased()] = i }

        var created = 0, updated = 0
        var slugToIndex: [String: Int] = [:]

        for p in parsed {
            let key = p.title.lowercased()
            if let idx = byTitle[key] {
                memories[idx].content = p.content
                memories[idx].category = p.category
                memories[idx].importance = max(memories[idx].importance, p.importance)
                memories[idx].source = "import:claude"
                memories[idx].updated = Date()
                slugToIndex[p.slug] = idx
                updated += 1
            } else {
                let m = Memory(title: p.title, content: p.content, category: p.category,
                               importance: p.importance, source: "import:claude")
                memories.append(m)
                let idx = memories.count - 1
                byTitle[key] = idx
                slugToIndex[p.slug] = idx
                created += 1
            }
        }

        // Resolve [[wikilink]] / (file.md) references into the graph's bidirectional links.
        for p in parsed {
            guard let ai = slugToIndex[p.slug] else { continue }
            for ls in p.linkSlugs {
                guard let bi = slugToIndex[ls], bi != ai else { continue }
                let aid = memories[ai].id, bid = memories[bi].id
                if !memories[ai].links.contains(bid) { memories[ai].links.append(bid) }
                if !memories[bi].links.contains(aid) { memories[bi].links.append(aid) }
            }
        }

        return Consolidator.Output(memories: memories, summary: nil, created: created, updated: updated)
    }

    private struct ParsedMemory {
        var slug: String
        var title: String
        var content: String
        var category: String
        var importance: Int
        var linkSlugs: [String]
    }

    /// Parses one Claude memory file. Returns nil for index files / files without frontmatter.
    private static func parseMemoryFile(_ path: String, titleMap: [String: String]) -> ParsedMemory? {
        let name = (path as NSString).lastPathComponent
        guard name.lowercased() != "memory.md" else { return nil }   // that's the index, not a fact
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        guard text.hasPrefix("---") else { return nil }

        // Split frontmatter / body.
        let parts = text.components(separatedBy: "\n---")
        guard parts.count >= 2 else { return nil }
        let front = String(parts[0].dropFirst(3))   // drop leading "---"
        let body = parts.dropFirst().joined(separator: "\n---")
            .drop { $0 == "-" || $0 == "\n" }
        let bodyText = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bodyText.isEmpty else { return nil }

        let slug = (name as NSString).deletingPathExtension
        let type = frontValue("type", in: front) ?? "reference"
        let title = titleMap[slug] ?? humanize(frontValue("name", in: front) ?? slug)

        // Links: [[slug]] and (slug.md)
        var links = matches(#"\[\[([^\]\|]+?)\]\]"#, in: bodyText)
        links += matches(#"\]\(([a-zA-Z0-9_-]+)\.md\)"#, in: bodyText)
        links = Array(Set(links.map { $0.lowercased() }))

        return ParsedMemory(slug: slug, title: title, content: bodyText,
                            category: category(forType: type), importance: importance(forType: type),
                            linkSlugs: links)
    }

    /// Maps each memory slug to the human title used in any sibling MEMORY.md index.
    private static func indexTitleMap(_ files: [String]) -> [String: String] {
        let indexes = Set(files.filter { ($0 as NSString).lastPathComponent.lowercased() == "memory.md" })
        var map: [String: String] = [:]
        for idx in indexes {
            guard let text = try? String(contentsOfFile: idx, encoding: .utf8) else { continue }
            // - [Title](slug.md) — hook
            let re = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([a-zA-Z0-9_-]+)\.md\)"#)
            let ns = text as NSString
            re?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges == 3 else { return }
                let title = ns.substring(with: m.range(at: 1))
                let slug = ns.substring(with: m.range(at: 2)).lowercased()
                if map[slug] == nil { map[slug] = title }
            }
        }
        return map
    }

    private static func frontValue(_ key: String, in front: String) -> String? {
        for line in front.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\(key):") {
                return t.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func category(forType t: String) -> String {
        switch t.lowercased() {
        case "user":      return Category.preferences.rawValue
        case "feedback":  return Category.preferences.rawValue
        case "project":   return Category.projects.rawValue
        case "reference": return Category.facts.rawValue
        default:          return Category.misc.rawValue
        }
    }
    private static func importance(forType t: String) -> Int {
        switch t.lowercased() {
        case "user", "feedback": return 4
        case "project":          return 3
        default:                 return 2
        }
    }

    private static func humanize(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m, m.numberOfRanges > 1 { out.append(ns.substring(with: m.range(at: 1))) }
        }
        return out
    }

    // MARK: - Helpers

    private static func collectFiles(for source: Source) -> [String] {
        if source.assistant == "claude" {
            var files = memoryDirFiles(under: "\(home)/.claude")
            files += markdownFiles(under: "\(home)/.claude", matching: { $0.lowercased() == "memory.md" })
            if fm.fileExists(atPath: "\(home)/.claude/CLAUDE.md") { files.append("\(home)/.claude/CLAUDE.md") }
            return Array(Set(files)).sorted()
        }
        return markdownFiles(under: source.path, matching: { _ in true })
    }

    private static func isDir(_ path: String) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    /// All files inside any directory named "memory" beneath `root`.
    private static func memoryDirFiles(under root: String) -> [String] {
        guard let en = fm.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        for case let rel as String in en {
            let full = "\(root)/\(rel)"
            let comps = rel.split(separator: "/")
            if comps.contains("memory"), !isDir(full),
               rel.lowercased().hasSuffix(".md") {
                out.append(full)
            }
        }
        return out
    }

    private static func markdownFiles(under root: String, matching: (String) -> Bool) -> [String] {
        guard isDir(root), let en = fm.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        var visited = 0
        for case let rel as String in en {
            visited += 1
            if visited > 20_000 { break }     // safety bound on huge trees
            let name = (rel as NSString).lastPathComponent
            guard name.lowercased().hasSuffix(".md"), matching(name) else { continue }
            out.append("\(root)/\(rel)")
        }
        return out
    }

    private static func chunked(_ s: String, maxChars: Int) -> [String] {
        guard s.count > maxChars else { return [s] }
        var chunks: [String] = []
        var current = ""
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > maxChars, !current.isEmpty {
                chunks.append(current); current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
