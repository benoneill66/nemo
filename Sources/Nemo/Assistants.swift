import Foundation

/// One configurable assistant: a wake word that routes to a particular CLI backend.
struct Assistant {
    enum Kind: String { case claude, codex, gemini }
    var name: String          // spoken/displayed name, e.g. "Claude"
    var kind: Kind            // which CLI to drive
    var wake: [String]        // wake words (without "hey"), incl. mishear variants
    var model: String?        // optional model override
    var voice: String?        // optional TTS voice for this assistant
    var command: String?      // optional explicit CLI path

    init(name: String, kind: Kind, wake: [String],
         model: String? = nil, voice: String? = nil, command: String? = nil) {
        self.name = name; self.kind = kind; self.wake = wake.map { $0.lowercased() }
        self.model = model; self.voice = voice; self.command = command
    }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String,
              let kindStr = (json["kind"] as? String)?.lowercased(),
              let kind = Kind(rawValue: kindStr) else { return nil }
        let wake = (json["wake"] as? [String]).map { $0.map { $0.lowercased() } } ?? [name.lowercased()]
        self.init(name: name, kind: kind, wake: wake,
                  model: json["model"] as? String,
                  voice: json["voice"] as? String,
                  command: json["command"] as? String)
    }
}

/// Reads ~/.config/nemo/config.json and exposes settings.
enum Settings {
    static func raw() -> [String: Any] {
        let path = ("~/.config/nemo/config.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    static func assistants() -> [Assistant] {
        if let arr = raw()["assistants"] as? [[String: Any]] {
            let list = arr.compactMap { Assistant(json: $0) }
            if !list.isEmpty { return list }
        }
        return defaultAssistants
    }

    static let defaultAssistants: [Assistant] = [
        Assistant(name: "Claude", kind: .claude,
                  wake: ["claude", "cloud", "clyde", "claud"], model: "claude-sonnet-4-6"),
        Assistant(name: "Codex", kind: .codex,
                  wake: ["codex", "codecs", "cortex", "kodaks"]),
        Assistant(name: "Gemini", kind: .gemini,
                  wake: ["gemini", "gemini", "jiminy", "gemma", "gemmini"])
    ]
}

/// Runs an assistant's CLI for a single prompt, optionally streaming text deltas.
enum AssistantRunner {
    private static var home: String { NSHomeDirectory() }

    static func run(_ a: Assistant, prompt: String,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        guard let bin = resolveBinary(a) else {
            throw mkErr("Couldn't find the \(a.name) CLI. Install it, or set \"command\" for \(a.name) in config.json.")
        }
        switch a.kind {
        case .claude: return try await runClaude(bin, a, prompt, onDelta)
        case .gemini: return try await runGemini(bin, a, prompt)
        case .codex:  return try await runCodex(bin, a, prompt)
        }
    }

    /// Runs a single non-streaming Claude prompt and returns the full text answer.
    /// Used by the memory consolidator and context importer (not the spoken flow).
    /// `system` overrides the system prompt; pass nil for none.
    static func claudeOneShot(prompt: String, system: String?, model: String? = nil,
                              timeout: TimeInterval = 240) async throws -> String {
        let probe = Assistant(name: "Claude", kind: .claude, wake: ["claude"], model: model)
        guard let bin = resolveBinary(probe) else {
            throw mkErr("Couldn't find the Claude CLI. Install it or set \"command\" in config.json.")
        }
        var args = ["-p", prompt,
                    "--output-format", "text",
                    "--strict-mcp-config", "--setting-sources", "",
                    "--permission-mode", "bypassPermissions"]
        if let system { args += ["--system-prompt", system] }
        if let model { args += ["--model", model] }
        let (status, out, errs) = try await exec(executable: bin, arguments: args, onLine: nil, timeout: timeout)
        let answer = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty {
            throw mkErr(status != 0 && !errs.isEmpty ? errs : "Claude returned no output.")
        }
        return answer
    }

    // MARK: Backends

    private static let claudeSystem = """
    You are Claude, a friendly voice assistant that answers out loud over a speaker. \
    You DO have tools and must use them freely: use WebSearch (and WebFetch) for any \
    current or real-time information — weather, news, prices, scores, recent events. \
    If a tool you need is not in your immediate list, call ToolSearch to find it first. \
    NEVER say you lack access to real-time data; if you need current info, search the \
    web. When you need a tool, FIRST say one short, natural sentence telling the user \
    what you're about to do (e.g. "Let me check the weather for you."), then use the \
    tool and give the answer. If you can answer instantly without a tool, just answer. \
    Keep answers short and conversational — one to three sentences of plain spoken \
    English. No markdown, lists, code, emoji, URLs, or source citations. If you need \
    one missing detail like a city, ask one short question.
    """

    /// For CLIs without a system-prompt flag, fold the spoken-style guidance in.
    private static func spokenPrompt(_ p: String) -> String {
        """
        You are a friendly voice assistant. Answer the question below out loud in one \
        to three short, conversational sentences of plain spoken English — no markdown, \
        lists, code, emoji, URLs, or citations. Use web search if you need current \
        information. Question: \(p)
        """
    }

    private static func runClaude(_ bin: String, _ a: Assistant, _ prompt: String,
                                  _ onDelta: @escaping (String) -> Void) async throws -> String {
        var args = [
            "-p", prompt,
            "--system-prompt", claudeSystem,
            "--output-format", "stream-json", "--include-partial-messages", "--verbose",
            "--strict-mcp-config", "--setting-sources", "",
            "--permission-mode", "bypassPermissions"
        ]
        if let m = a.model { args += ["--model", m] }

        var full = ""
        let (status, _, errs) = try await exec(executable: bin, arguments: args, onLine: { line in
            if let t = textDelta(fromLine: line) {
                full += t
                onDelta(t)
            } else if isContentBlockStop(fromLine: line) {
                onDelta("\n") // flush any buffered preamble sentence now
            }
        })
        let answer = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if status != 0 && answer.isEmpty {
            throw mkErr(errs.isEmpty ? "Claude exited with code \(status)." : errs)
        }
        return answer
    }

    private static func runGemini(_ bin: String, _ a: Assistant, _ prompt: String) async throws -> String {
        var args = ["-p", spokenPrompt(prompt), "-y"]
        if let m = a.model { args += ["-m", m] }
        let (status, out, errs) = try await exec(executable: bin, arguments: args, onLine: nil)
        let answer = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty {
            throw mkErr(status != 0 && !errs.isEmpty ? errs : "Gemini gave no answer.")
        }
        return answer
    }

    private static func runCodex(_ bin: String, _ a: Assistant, _ prompt: String) async throws -> String {
        let tmp = NSTemporaryDirectory() + "nemo-codex-\(UUID().uuidString).txt"
        var args = [
            "exec", spokenPrompt(prompt),
            "--skip-git-repo-check", "--ignore-user-config",
            "--dangerously-bypass-approvals-and-sandbox",
            "-o", tmp, "--color", "never"
        ]
        if let m = a.model { args += ["-m", m] }
        let (status, _, errs) = try await exec(executable: bin, arguments: args, onLine: nil)
        let answer = (try? String(contentsOfFile: tmp, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try? FileManager.default.removeItem(atPath: tmp)
        if answer.isEmpty {
            throw mkErr(status != 0 && !errs.isEmpty ? errs : "Codex gave no answer.")
        }
        return answer
    }

    // MARK: Process plumbing

    /// Runs a process off the main thread. If `onLine` is given, stdout is delivered
    /// line-by-line (for streaming); stdout and stderr are also returned in full.
    private static func exec(executable: String, arguments: [String],
                             onLine: ((Data) -> Void)?,
                             timeout: TimeInterval = 120) async throws -> (Int32, String, String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments

                let workDir = ("~/.config/nemo/workdir" as NSString).expandingTildeInPath
                try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
                p.currentDirectoryURL = URL(fileURLWithPath: workDir)

                var env = ProcessInfo.processInfo.environment
                env["HOME"] = home
                env["PATH"] = childPATH(binDir: (executable as NSString).deletingLastPathComponent)
                p.environment = env

                let out = Pipe(); let errp = Pipe()
                p.standardOutput = out; p.standardError = errp
                p.standardInput = FileHandle.nullDevice

                do { try p.run() } catch { cont.resume(throwing: error); return }

                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                let handle = out.fileHandleForReading
                var buffer = Data(); var full = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    full.append(chunk)
                    if let onLine {
                        buffer.append(chunk)
                        while let nl = buffer.firstIndex(of: 0x0A) {
                            let line = buffer.subdata(in: buffer.startIndex..<nl)
                            buffer.removeSubrange(buffer.startIndex...nl)
                            onLine(line)
                        }
                    }
                }
                if let onLine, !buffer.isEmpty { onLine(buffer) }

                let errData = errp.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); timer.cancel()
                cont.resume(returning: (p.terminationStatus,
                                        String(data: full, encoding: .utf8) ?? "",
                                        String(data: errData, encoding: .utf8) ?? ""))
            }
        }
    }

    private static func resolveBinary(_ a: Assistant) -> String? {
        if let c = a.command, FileManager.default.isExecutableFile(atPath: c) { return c }
        let candidates: [String]
        switch a.kind {
        case .claude:
            candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        case .codex:
            candidates = ["/opt/homebrew/bin/codex", "\(home)/.local/bin/codex", "/usr/local/bin/codex"]
        case .gemini:
            candidates = ["/opt/homebrew/bin/gemini", "\(home)/.local/bin/gemini", "/usr/local/bin/gemini"]
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// PATH for child CLIs. Includes the binary's dir, Homebrew, ~/.local/bin, and any
    /// nvm node dirs (gemini is a node script and needs `node` on PATH).
    private static func childPATH(binDir: String) -> String {
        var dirs = [binDir, "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for v in versions.sorted(by: >) { dirs.append("\(nvm)/\(v)/bin") }
        }
        dirs += ["/usr/bin", "/bin"]
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    private static func mkErr(_ message: String) -> NSError {
        NSError(domain: "Nemo", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Stream parsing (claude stream-json) + speech sanitizing

    static func textDelta(fromLine line: Data) -> String? {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "stream_event",
              let event = obj["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String
        else { return nil }
        return text
    }

    static func isContentBlockStop(fromLine line: Data) -> Bool {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "stream_event",
              let event = obj["event"] as? [String: Any]
        else { return false }
        return event["type"] as? String == "content_block_stop"
    }

    /// Strips anything that sounds bad read aloud: markdown links/URLs, a trailing
    /// "Sources:" block, list bullets, and markdown formatting characters.
    static func spoken(from text: String) -> String {
        var s = text
        if let r = s.range(of: #"(?im)\n+\s*sources?\s*:.*$"#, options: .regularExpression) {
            s.removeSubrange(r.lowerBound..<s.endIndex)
        }
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*[-*]\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[*_`#>]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
