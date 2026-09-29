import Foundation

extension Codex {
    /// `codex` from PATH, then the install locations a GUI app's minimal
    /// launchd PATH misses. Mirrors Python's `codex_bin` plus the extra
    /// candidates the Rust port added — a superset, and it matters here: an app
    /// launched from Finder or launchd has neither Homebrew nor nvm on PATH.
    static func findCodex() -> URL {
        let fm = FileManager.default
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("codex")
                if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        let home = Config.home
        var candidates: [URL] = []
        // Highest nvm version first, like Python's sorted(...)[-1].
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            candidates += versions
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appendingPathComponent("bin/codex") }
        }
        candidates += [
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent("bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
            ?? URL(fileURLWithPath: "codex")
    }

    struct LaunchError: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { "app-server did not start: \(reason)" }
    }
    struct PhaseError: Error, LocalizedError {
        let inner: String, phase: String, exit: String
        var errorDescription: String? { "\(inner) (\(phase) phase, exit=\(exit))" }
    }

    /// Speaks JSON-RPC to `codex app-server --stdio`.
    static func live() throws -> [String: Any] {
        let binary = findCodex()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server", "--stdio"]

        // codex is a Node script: put the binary's own directory first so it
        // finds its sibling `node`, which a GUI app's PATH will not have.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = binary.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "")
        process.environment = env

        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let channel = RPCChannel()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { channel.feed(data) }
        }

        do {
            try process.run()
        } catch {
            throw LaunchError(reason: error.localizedDescription)
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            terminate(process)
        }

        func send(_ line: String) throws {
            try stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        }
        /// Python reports the child's exit status alongside the failure, which
        /// is what distinguishes "crashed" from "still running but silent".
        func exitCode() -> String {
            process.isRunning ? "None" : "\(process.terminationStatus)"
        }

        let initialize: [String: Any] = [
            "method": "initialize",
            "id": 1,
            "params": [
                "clientInfo": ["name": "ai-usage-monitor",
                               "title": "AI Usage Monitor",
                               "version": "0.1.0"],
                "capabilities": NSNull(),
            ],
        ]
        try send(String(decoding: try JSONSerialization.data(withJSONObject: initialize),
                        as: UTF8.self))
        do {
            _ = try channel.waitFor(id: 1, timeout: 5)
        } catch {
            throw PhaseError(inner: error.localizedDescription, phase: "init", exit: exitCode())
        }

        try send(#"{"method":"initialized"}"#)
        try send(#"{"method":"account/rateLimits/read","id":2}"#)
        do {
            return try channel.waitFor(id: 2, timeout: 15) as? [String: Any] ?? [:]
        } catch {
            throw PhaseError(inner: error.localizedDescription, phase: "rateLimits", exit: exitCode())
        }
    }

    /// SIGTERM, then SIGKILL if it will not go — the reference's terminate/wait/kill.
    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// Last `token_count` carrying `rate_limits` in the most recent session.
    static func cached() throws -> [String: Any] {
        let dir = Config.home.appendingPathComponent(".codex/sessions")
        guard let latest = newestJSONL(dir) else { throw SimpleError("no local session found") }
        guard let stream = try? String(contentsOf: latest, encoding: .utf8) else {
            throw SimpleError("no local session found")
        }
        var found: [String: Any]?
        for line in stream.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let payload = (object as? [String: Any])?.dict("payload"),
                  payload.string("type") == "token_count",
                  let limits = payload.dict("rate_limits"), !limits.isEmpty
            else { continue }
            // Keep scanning: the LAST match in the file is the current one.
            found = limits
        }
        guard let found else { throw SimpleError("no limits were found in the local sessions") }
        return ["rateLimits": found]
    }

    private static func newestJSONL(_ dir: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        var best: (Date, URL)?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let stamp = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }
            if best == nil || stamp > best!.0 { best = (stamp, url) }
        }
        return best?.1
    }

    /// The CLI's ChatGPT login. Its presence, not the binary's, is what makes
    /// Codex a registered account: with Codex installed but never signed in,
    /// the session cache can still hold someone's old limits.
    static var authFile: URL { Config.home.appendingPathComponent(".codex/auth.json") }

    static func signedIn() -> Bool {
        FileManager.default.fileExists(atPath: authFile.path)
    }

    /// Email from the `id_token` claims in ~/.codex/auth.json. Never throws —
    /// identity is a nicety, the limits are the point.
    static func email() -> String {
        guard let auth = try? Config.readJSON(authFile) as? [String: Any],
              let token = auth.dict("tokens")?.string("id_token")
        else { return "" }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return "" }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        return claims.string("email") ?? ""
    }
}
