import Foundation
import UsageModel

/// Fans out over every configured provider and returns one `Provider` each.
///
/// Port of `collect_all` in the Tauri widget's collector/mod.rs, itself a port
/// of cli/usage_monitor.py. The invariant that matters: a `collect*` never
/// throws out of here. A failure comes back as a `Provider` carrying `error`,
/// so one dead provider cannot blank the panel.
public enum Collector {
    /// The 5h quota window, also the horizon for trusting a `.claude.json` mtime.
    static let claudeSessionSeconds: TimeInterval = 5 * 3600
    /// Environments whose configs are this close apart are both taken as in use.
    static let claudeConfigTieSeconds: TimeInterval = 600

    public static func collectAll() async -> [Provider] {
        let profiles = claudeProfiles()
        // Codex is listed only once its CLI is signed in to ChatGPT. Being
        // installed is not enough, and the stale session cache would otherwise
        // put limits on screen for an account that is not registered.
        let codexSignedIn = Codex.signedIn()

        // Concurrent, but the output order is fixed: Claude profiles in
        // directory order, then Codex, then Cursor — same as the Python
        // collector, so the parity diff compares like with like.
        var providers = await withTaskGroup(of: (Int, Provider).self) { group in
            for (index, dir) in profiles.enumerated() {
                group.addTask { (index, await Claude.collect(profileDir: dir)) }
            }
            if codexSignedIn {
                group.addTask { (profiles.count, await Codex.collect()) }
            }
            group.addTask { (profiles.count + 1, await Cursor.collect()) }

            var collected: [(Int, Provider)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        markStandby(&providers)
        return providers
    }

    /// Each Claude account lives in its own subdirectory of
    /// ~/.config/ai-usage-monitor/claude/, holding .credentials.json.
    static func claudeProfiles() -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: Config.claudeDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Flags the Claude accounts that are not the one currently burning quota.
    /// Not yet ported — see PLAN.md. Until it is, nothing is flagged, which is
    /// the same thing `mark_standby` does when it cannot tell the accounts
    /// apart, so the placeholder is honest rather than wrong.
    static func markStandby(_ providers: inout [Provider]) {
        // TODO(phase-1): port mark_standby / active_claude_emails.
    }
}
