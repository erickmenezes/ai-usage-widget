import Foundation
import Security
import UsageModel

/// Registering Claude credentials already on the machine, and the Cursor
/// config. Port of the Tauri build's accounts.rs. The Python CLI
/// (`claude-add`, `cursor-admin`, `cursor-cookie`) stays the headless path and
/// writes the same store, so the file formats must not drift.
public enum Accounts {
    public struct Candidate: Identifiable, Hashable, Sendable {
        public let id: String
        public let label: String
        /// The account the source's config dir is logged into, per its
        /// `.claude.json`. Lets the UI hide sources whose account is already
        /// registered without reading any secret.
        public let email: String?
    }

    /// What the Codex CLI on this Mac looks like. Codex needs no registration
    /// here — the collector talks to the CLI's own ChatGPT login — but the
    /// panel still has to say so, or its absence reads as an omission.
    public struct CodexStatus: Sendable {
        /// A `codex` executable was found on PATH or in a known install dir.
        public let installed: Bool
        /// `~/.codex/auth.json` exists, so the CLI is logged in.
        public let signedIn: Bool
        /// The account that login names, when its token carries one.
        public let email: String?
    }

    public struct Detection: Sendable {
        public let claude: [Candidate]
        public let codex: CodexStatus
        public let cursorConfigured: Bool
    }

    public struct Registered: Sendable {
        public let profile: String
        public let email: String
        public let plan: String
        /// The account was already registered; `profile` names the existing one.
        public let already: Bool
    }

    // MARK: Detection

    /// Sources found on the machine. Metadata only — no secret is read here, so
    /// listing never triggers the macOS Keychain prompt. That happens on Add.
    public static func detect() -> Detection {
        let services = keychainServices()
        return Detection(
            claude: keychainCandidates(services) + fileCandidates(excluding: services),
            codex: codexStatus(),
            cursorConfigured: FileManager.default.fileExists(atPath: Config.cursorConfig.path))
    }

    /// Metadata only, like the Claude detection: whether the CLI is there and
    /// which account it holds. The email comes from the id_token claims the
    /// collector already reads; no secret leaves this function.
    static func codexStatus() -> CodexStatus {
        let email = Codex.email()
        return CodexStatus(
            installed: FileManager.default.isExecutableFile(atPath: Codex.findCodex().path),
            signedIn: Codex.signedIn(),
            email: email.isEmpty ? nil : email)
    }

    /// Keychain services named `Claude Code-credentials[-<hash>]`, one per
    /// Claude Code login.
    ///
    /// Uses SecItemCopyMatching with kSecReturnAttributes and deliberately
    /// *without* kSecReturnData: attributes are metadata, so this enumerates
    /// silently. Asking for the data is what prompts, and that is reserved for
    /// registration.
    static func keychainServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        let services = items
            .compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0.hasPrefix(ClaudeSource.keychainService) }
        return Array(Set(services)).sorted()
    }

    /// Reverse-maps hash suffixes to ~/.claude* dirs so entries read as paths
    /// rather than hashes. An unknown hash — a deleted or exotic config dir —
    /// keeps its raw suffix instead of being dropped.
    static func keychainCandidates(_ services: [String]) -> [Candidate] {
        var byService: [String: (name: String, email: String)] = [:]
        for dir in ClaudeSource.claudeDirs() {
            byService[ClaudeSource.keychainService(for: dir)] =
                (dir.lastPathComponent, ClaudeSource.dirActiveEmail(dir))
        }
        return services.map { service in
            if let known = byService[service] {
                return Candidate(id: "keychain:\(service)",
                                 label: "Keychain · ~/\(known.name)",
                                 email: known.email.isEmpty ? nil : known.email)
            }
            let prefix = ClaudeSource.keychainService + "-"
            let label = service.hasPrefix(prefix)
                ? "Keychain · \(service.dropFirst(prefix.count))"
                : "Keychain · default"
            return Candidate(id: "keychain:\(service)", label: label, email: nil)
        }
    }

    /// `~/.claude*/.credentials.json` files. On macOS these are usually stale
    /// copies, so a dir that also has a Keychain entry is the same source seen
    /// twice and the Keychain wins.
    static func fileCandidates(excluding keychain: [String]) -> [Candidate] {
        ClaudeSource.claudeDirs().compactMap { dir in
            let file = dir.appendingPathComponent(".credentials.json")
            guard FileManager.default.fileExists(atPath: file.path),
                  !keychain.contains(ClaudeSource.keychainService(for: dir))
            else { return nil }
            let email = ClaudeSource.dirActiveEmail(dir)
            return Candidate(id: "file:\(file.path)",
                             label: "File · ~/\(dir.lastPathComponent)",
                             email: email.isEmpty ? nil : email)
        }
    }

    // MARK: Claude profiles

    public static func profiles() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: Config.claudeDir, includingPropertiesForKeys: nil)) ?? []
        return entries
            // Skip dotted dirs — notably our own transient .staging-<pid>,
            // which would otherwise dedupe every add against itself.
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .filter { FileManager.default.fileExists(
                atPath: $0.appendingPathComponent(".credentials.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func addClaude(_ id: String) async throws -> Registered {
        try await register(ClaudeSource.read(id), sourceID: id)
    }

    /// Registers a session obtained by `ClaudeLogin`, with no source recorded:
    /// this login is the profile's own, so `Claude.ensureFresh` refreshes it
    /// here instead of going back to the Keychain for it.
    public static func addClaudeLogin(
        _ attempt: ClaudeLogin.Attempt, pasted: String
    ) async throws -> Registered {
        try await register(ClaudeLogin.complete(attempt, pasted: pasted), sourceID: nil)
    }

    /// The shared half of both add paths. `sourceID` nil means the credential
    /// is the profile's own rather than a copy of a login the CLI still keeps.
    static func register(_ data: [String: Any], sourceID: String?) async throws -> Registered {
        guard let oauth = data.dict("claudeAiOauth") else {
            throw SimpleError("the source does not contain a Claude OAuth session")
        }
        guard oauth.string("accessToken") != nil, oauth.string("refreshToken") != nil else {
            throw SimpleError("the source does not contain a complete Claude OAuth session")
        }

        // Stage the credential so identify() can persist a rotated token, then
        // name the profile after whichever account it turns out to be.
        let staging = Config.claudeDir.appendingPathComponent(".staging-\(getpid())")
        let staged = staging.appendingPathComponent(".credentials.json")
        try Config.writeJSON(data, to: staged)
        if let sourceID { try writeSource(staging, id: sourceID, email: nil) }

        let identity: (email: String, plan: String)
        do {
            identity = try await Claude.identify(staged)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        if let sourceID { try writeSource(staging, id: sourceID, email: identity.email) }

        // One profile per account. Which copy survives depends on where this
        // one came from: an adopted credential defers to the existing profile
        // (its refresh-token lineage keeps working) and only re-points the
        // source, while a fresh sign-in replaces it — taking over a mirror with
        // a session of its own is exactly what signing in is for.
        for dir in profiles() {
            let existing = try? await Claude.identify(
                dir.appendingPathComponent(".credentials.json"))
            guard let existing,
                  existing.email.caseInsensitiveCompare(identity.email) == .orderedSame
            else { continue }
            if let sourceID {
                try? FileManager.default.removeItem(at: staging)
                try? writeSource(dir, id: sourceID, email: identity.email)
            } else {
                try Config.writeJSON(
                    try Config.readJSON(staged),
                    to: dir.appendingPathComponent(".credentials.json"))
                try? FileManager.default.removeItem(
                    at: dir.appendingPathComponent(ClaudeSource.sourceFile))
                try? FileManager.default.removeItem(at: staging)
                // The gate remembers a source this profile no longer has.
                await AdoptionGate.shared.forget(profile: dir.path)
            }
            return Registered(profile: dir.lastPathComponent, email: identity.email,
                              plan: identity.plan, already: true)
        }

        let name = profileName(for: identity.email)
        try FileManager.default.moveItem(
            at: staging, to: Config.claudeDir.appendingPathComponent(name))
        return Registered(profile: name, email: identity.email,
                          plan: identity.plan, already: false)
    }

    public static func removeClaude(_ profile: String) throws {
        // Path traversal guard: this name comes from the UI and is joined onto
        // the config dir before a recursive delete.
        guard !profile.isEmpty, !profile.hasPrefix("."),
              !profile.contains("/"), !profile.contains("\\"), !profile.contains("..")
        else { throw SimpleError("invalid profile name") }
        let dir = Config.claudeDir.appendingPathComponent(profile)
        guard FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(".credentials.json").path)
        else { throw SimpleError("profile not found: \(profile)") }
        try FileManager.default.removeItem(at: dir)
    }

    /// Records the source, and the account it held: a source that later logs
    /// into a *different* account must not be adopted, or the profile would
    /// silently change identity.
    static func writeSource(_ profileDir: URL, id: String, email: String?) throws {
        var record: [String: Any] = ["source": id]
        if let email { record["email"] = email }
        try Config.writeJSON(record, to: profileDir.appendingPathComponent(ClaudeSource.sourceFile))
    }

    /// Sanitized email local part, suffixed on collision. The same email never
    /// collides — that is deduplicated before naming.
    static func profileName(for email: String) -> String {
        let local = (email.split(separator: "@").first.map(String.init) ?? "claude").lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var base = String(local.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if base.isEmpty { base = "claude" }
        var name = base
        var counter = 2
        while FileManager.default.fileExists(
                atPath: Config.claudeDir.appendingPathComponent(name).path) {
            name = "\(base)-\(counter)"
            counter += 1
        }
        return name
    }

    // MARK: Cursor

    /// Mirrors the Python CLI's cursor-admin / cursor-cookie validation and the
    /// cursor.json format.
    public static func saveCursor(method: String, secret: String, email: String) throws {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        switch method {
        case "admin_key":
            guard secret.hasPrefix("key_") else { throw SimpleError("the key must start with key_") }
            let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !email.isEmpty else {
                throw SimpleError("email is required with the admin key")
            }
            try Config.writeJSON(
                ["method": "admin_key", "admin_key": secret, "email": email],
                to: Config.cursorConfig)
        case "dashboard_cookie":
            let prefix = "WorkosCursorSessionToken="
            let value = secret.hasPrefix(prefix) ? String(secret.dropFirst(prefix.count)) : secret
            guard value.count >= 100, value.contains("%3A%3A") || value.contains("::") else {
                throw SimpleError(
                    "the cookie does not look like a complete WorkosCursorSessionToken")
            }
            try Config.writeJSON(
                ["method": "dashboard_cookie", "session_cookie": value], to: Config.cursorConfig)
        default:
            throw SimpleError("unknown method: \(method)")
        }
    }

    public static func removeCursor() throws {
        try FileManager.default.removeItem(at: Config.cursorConfig)
    }
}
