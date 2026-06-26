import Foundation
import CryptoKit
import Network
#if canImport(AppKit)
import AppKit
#endif

/// Connects Nemo to a Gmail account (read-only) and pulls recent mail as importable context.
///
/// Auth uses Google's recommended **OAuth 2.0 loopback flow** for native desktop apps: we spin
/// up a one-shot HTTP listener on `127.0.0.1`, open the system browser to Google's consent
/// screen, and catch the redirect with the authorization code — no embedded webview, no secret
/// shipped in a public client beyond what Google issues for "Desktop app" clients. PKCE + a CSRF
/// `state` value harden the exchange. The long-lived refresh token is persisted locally (0600)
/// alongside Nemo's other data; only distilled text ever leaves the Mac, and only to your Claude
/// CLI via the existing import pipeline.
enum GmailService {

    // MARK: - Errors

    enum GmailError: LocalizedError {
        case notConfigured
        case notConnected
        case oauthFailed(String)
        case http(Int, String)
        case decode(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Gmail isn't configured. Sign into the gog CLI (gog auth add <you@gmail.com>) to reuse its OAuth client, or add \"gmail\": { \"clientId\": \"…\", \"clientSecret\": \"…\" } to ~/.config/nemo/config.json."
            case .notConnected:
                return "Not connected to Gmail. Use Connect first."
            case .oauthFailed(let m): return "Gmail sign-in failed: \(m)"
            case .http(let code, let m): return "Gmail API error (\(code)): \(m)"
            case .decode(let m): return "Couldn't read Gmail response: \(m)"
            case .cancelled: return "Gmail sign-in was cancelled."
            }
        }
    }

    // MARK: - Config

    private static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let apiBase = "https://gmail.googleapis.com/gmail/v1/users/me"

    static var clientId: String? { Config.gmailClientId }
    static var clientSecret: String? { Config.gmailClientSecret }
    static var isConfigured: Bool { !(clientId ?? "").isEmpty && !(clientSecret ?? "").isEmpty }

    // MARK: - A pulled message

    struct Message: Sendable {
        var id: String
        var from: String
        var to: String
        var subject: String
        var date: String
        var snippet: String
        var body: String

        /// Renders the message as a single import-friendly text block.
        var asContext: String {
            var head = "### Email: \(subject.isEmpty ? "(no subject)" : subject)"
            var lines: [String] = []
            if !from.isEmpty { lines.append("From: \(from)") }
            if !to.isEmpty { lines.append("To: \(to)") }
            if !date.isEmpty { lines.append("Date: \(date)") }
            let bodyText = body.isEmpty ? snippet : body
            head += "\n" + lines.joined(separator: "\n")
            return head + "\n\n" + bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Token persistence

    private struct Tokens: Codable {
        var refreshToken: String
        var accessToken: String?
        var expiry: Date?
        var account: String?     // email address, for display
    }

    private static var tokenPath: String {
        let dir = ("~/.config/nemo/data" as NSString).expandingTildeInPath
        return dir + "/gmail.json"
    }

    private static func loadTokens() -> Tokens? {
        guard let data = FileManager.default.contents(atPath: tokenPath) else { return nil }
        return try? JSONDecoder.gmail.decode(Tokens.self, from: data)
    }

    private static func saveTokens(_ t: Tokens) {
        let dir = ("~/.config/nemo/data" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.gmail.encode(t) else { return }
        FileManager.default.createFile(atPath: tokenPath, contents: data,
                                       attributes: [.posixPermissions: 0o600])
    }

    /// Whether we currently hold a refresh token (i.e. the account is linked).
    static var isConnected: Bool { loadTokens()?.refreshToken.isEmpty == false }

    /// The linked account's email address, if known.
    static var connectedAccount: String? { loadTokens()?.account }

    /// Forget the linked account (local only — does not revoke server-side).
    static func disconnect() {
        try? FileManager.default.removeItem(atPath: tokenPath)
    }

    // MARK: - Connect (OAuth loopback flow)

    /// Runs the full consent flow and persists a refresh token. Opens the user's browser.
    static func connect() async throws {
        guard isConfigured, let clientId, let clientSecret else { throw GmailError.notConfigured }

        let verifier = randomURLSafe(64)
        let challenge = codeChallenge(for: verifier)
        let state = randomURLSafe(32)

        let receiver = LoopbackReceiver()
        let port = try receiver.start()
        let redirectURI = "http://127.0.0.1:\(port)"
        defer { receiver.stop() }

        var comps = URLComponents(string: authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent")
        ]
        guard let authURL = comps.url else { throw GmailError.oauthFailed("bad auth URL") }

        openInBrowser(authURL)

        let code = try await receiver.waitForCode(expectedState: state, timeout: 300)

        // Exchange the authorization code for tokens.
        let form = [
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ]
        let json = try await postForm(tokenEndpoint, form: form)
        guard let refresh = json["refresh_token"] as? String, !refresh.isEmpty else {
            throw GmailError.oauthFailed("Google did not return a refresh token. Revoke Nemo's access at myaccount.google.com/permissions and try again.")
        }
        let access = json["access_token"] as? String
        let expiry = (json["expires_in"] as? Double).map { Date().addingTimeInterval($0 - 60) }
        var tokens = Tokens(refreshToken: refresh, accessToken: access, expiry: expiry, account: nil)
        // Best-effort: fetch the profile to label the connection.
        if let access { tokens.account = try? await profileEmail(accessToken: access) }
        saveTokens(tokens)
    }

    // MARK: - Access tokens

    /// Returns a valid access token, refreshing it from the refresh token when needed.
    private static func accessToken() async throws -> String {
        guard var tokens = loadTokens(), !tokens.refreshToken.isEmpty else { throw GmailError.notConnected }
        if let token = tokens.accessToken, let expiry = tokens.expiry, expiry > Date() {
            return token
        }
        guard let clientId, let clientSecret else { throw GmailError.notConfigured }
        let json = try await postForm(tokenEndpoint, form: [
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token"
        ])
        guard let access = json["access_token"] as? String else {
            throw GmailError.oauthFailed("token refresh returned no access_token")
        }
        tokens.accessToken = access
        tokens.expiry = (json["expires_in"] as? Double).map { Date().addingTimeInterval($0 - 60) }
        saveTokens(tokens)
        return access
    }

    // MARK: - Fetch

    /// Lists recent messages matching `query` (Gmail search syntax) and returns them parsed to
    /// plaintext, newest first, capped at `max`. `onProgress(done, total)` reports per-message
    /// fetch completion for the UI.
    static func fetchRecent(query: String, max: Int,
                            onProgress: @Sendable @escaping (Int, Int) -> Void = { _, _ in })
    async throws -> [Message] {
        let token = try await accessToken()
        let ids = try await listMessageIds(query: query, max: max, token: token)
        guard !ids.isEmpty else { return [] }

        var out: [Message?] = Array(repeating: nil, count: ids.count)
        var done = 0
        try await withThrowingTaskGroup(of: (Int, Message).self) { group in
            var next = 0
            func schedule() {
                guard next < ids.count else { return }
                let i = next; next += 1
                let id = ids[i]
                group.addTask { (i, try await getMessage(id: id, token: token)) }
            }
            for _ in 0..<Swift.min(5, ids.count) { schedule() }
            while let (i, msg) = try await group.next() {
                out[i] = msg
                done += 1
                onProgress(done, ids.count)
                schedule()
            }
        }
        return out.compactMap { $0 }
    }

    private static func listMessageIds(query: String, max: Int, token: String) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?
        repeat {
            var comps = URLComponents(string: "\(apiBase)/messages")!
            var items: [URLQueryItem] = [
                .init(name: "maxResults", value: String(Swift.min(100, max - ids.count)))
            ]
            if !query.isEmpty { items.append(.init(name: "q", value: query)) }
            if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
            comps.queryItems = items
            let json = try await getJSON(comps.url!, token: token)
            if let arr = json["messages"] as? [[String: Any]] {
                ids += arr.compactMap { $0["id"] as? String }
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil && ids.count < max
        return Array(ids.prefix(max))
    }

    private static func getMessage(id: String, token: String) async throws -> Message {
        var comps = URLComponents(string: "\(apiBase)/messages/\(id)")!
        comps.queryItems = [.init(name: "format", value: "full")]
        let json = try await getJSON(comps.url!, token: token)

        let snippet = (json["snippet"] as? String).map(decodeHTMLEntities) ?? ""
        let payload = json["payload"] as? [String: Any] ?? [:]
        let headers = payload["headers"] as? [[String: Any]] ?? []
        func header(_ name: String) -> String {
            for h in headers {
                if let n = h["name"] as? String, n.caseInsensitiveCompare(name) == .orderedSame {
                    return (h["value"] as? String) ?? ""
                }
            }
            return ""
        }
        let body = extractBody(from: payload)
        return Message(id: id,
                       from: header("From"), to: header("To"),
                       subject: header("Subject"), date: header("Date"),
                       snippet: snippet, body: body)
    }

    /// Best-effort plaintext extraction: prefer text/plain, fall back to stripped text/html.
    private static func extractBody(from payload: [String: Any]) -> String {
        if let plain = findPart(payload, mime: "text/plain") { return plain }
        if let html = findPart(payload, mime: "text/html") { return stripHTML(html) }
        return ""
    }

    private static func findPart(_ node: [String: Any], mime: String) -> String? {
        let nodeMime = (node["mimeType"] as? String)?.lowercased() ?? ""
        if nodeMime == mime, let body = node["body"] as? [String: Any],
           let data = body["data"] as? String, let text = decodeBase64URL(data) {
            return text
        }
        if let parts = node["parts"] as? [[String: Any]] {
            for p in parts { if let found = findPart(p, mime: mime) { return found } }
        }
        return nil
    }

    private static func profileEmail(accessToken token: String) async throws -> String? {
        let json = try await getJSON(URL(string: "\(apiBase)/profile")!, token: token)
        return json["emailAddress"] as? String
    }

    // MARK: - HTTP helpers

    private static func getJSON(_ url: URL, token: String) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GmailError.decode("not a JSON object")
        }
        return json
    }

    private static func postForm(_ urlString: String, form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GmailError.decode("token response not JSON")
        }
        return json
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GmailError.http(http.statusCode, String(body.prefix(300)))
        }
    }

    // MARK: - Encoding helpers

    private static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(hash))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ s: String) -> String? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html
        // Drop script/style blocks wholesale, then all tags.
        for pattern in [#"<script[\s\S]*?</script>"#, #"<style[\s\S]*?</style>"#, #"<[^>]+>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = decodeHTMLEntities(text)
        // Collapse runs of whitespace.
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n[ \t]*\n[ \t\n]*"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        var out = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    private static func openInBrowser(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

#if DEBUG
extension GmailService {
    /// Test hook: plaintext extraction from a Gmail `payload` JSON object.
    static func _testExtractBody(_ payload: [String: Any]) -> String { extractBody(from: payload) }
    /// Test hook: HTML → plaintext.
    static func _testStripHTML(_ html: String) -> String { stripHTML(html) }
}
#endif

private extension JSONDecoder {
    static var gmail: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
private extension JSONEncoder {
    static var gmail: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

// MARK: - Loopback redirect receiver

/// A one-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect. It binds an ephemeral
/// port (reported back so the redirect URI can include it), serves a single "you can close this
/// tab" page, and resolves with the authorization `code`.
private final class LoopbackReceiver: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "nemo.gmail.oauth")
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false
    private let lock = NSLock()

    /// Starts the listener and returns the chosen port (blocks briefly until it's ready).
    func start() throws -> Int {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let err): failure = err; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw GmailService.GmailError.oauthFailed("loopback listener didn't start")
        }
        if let failure { throw failure }
        guard let port = listener.port?.rawValue else {
            throw GmailService.GmailError.oauthFailed("loopback listener has no port")
        }
        return Int(port)
    }

    func waitForCode(expectedState: String, timeout: TimeInterval) async throws -> String {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { cont in
                        self.lock.lock(); self.continuation = cont; self.expectedState = expectedState; self.lock.unlock()
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw GmailService.GmailError.oauthFailed("timed out waiting for Google's redirect")
                }
                let code = try await group.next()!
                group.cancelAll()
                return code
            }
        } onCancel: {
            self.resolve(.failure(GmailService.GmailError.cancelled))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private var expectedState: String = ""

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let result = self.parse(request)
            let pageBody: String
            switch result {
            case .success:
                pageBody = "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'><h2>Nemo is connected to Gmail.</h2><p>You can close this tab and return to Nemo.</p></body></html>"
            case .failure:
                pageBody = "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'><h2>Sign-in failed.</h2><p>Return to Nemo and try again.</p></body></html>"
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(pageBody.utf8.count)\r\nConnection: close\r\n\r\n\(pageBody)"
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
            self.resolve(result)
        }
    }

    /// Pulls `code` / `state` / `error` out of the first request line.
    private func parse(_ request: String) -> Result<String, Error> {
        guard let firstLine = request.split(separator: "\r\n").first,
              let pathPart = firstLine.split(separator: " ").dropFirst().first else {
            return .failure(GmailService.GmailError.oauthFailed("malformed redirect request"))
        }
        let path = String(pathPart)
        guard let comps = URLComponents(string: "http://127.0.0.1\(path)") else {
            return .failure(GmailService.GmailError.oauthFailed("malformed redirect URL"))
        }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let err = value("error") {
            return .failure(GmailService.GmailError.oauthFailed(err))
        }
        guard let returnedState = value("state"), returnedState == expectedState else {
            return .failure(GmailService.GmailError.oauthFailed("state mismatch (possible CSRF) — try again"))
        }
        guard let code = value("code"), !code.isEmpty else {
            return .failure(GmailService.GmailError.oauthFailed("no authorization code in redirect"))
        }
        return .success(code)
    }

    private func resolve(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished, let cont = continuation else { lock.unlock(); return }
        finished = true
        continuation = nil
        lock.unlock()
        switch result {
        case .success(let code): cont.resume(returning: code)
        case .failure(let err): cont.resume(throwing: err)
        }
    }
}
