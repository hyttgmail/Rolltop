import CryptoKit
import Foundation

// Script conditions: running a command safely, and remembering which commands the user
// allowed on this Mac.

/// Runs a shell command with a minimal environment, a timeout, and capped output.
nonisolated enum AutomationScriptExecutor {
    static let outputLimit = 4096

    /// Only these variables reach the script: a Rolltop started from a terminal must not pass
    /// on the terminal's environment (API keys and the like).
    static var environment: [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
        ]
    }

    /// `/bin/sh -c command` in the home folder, standard error with standard output; it holds
    /// when it exits 0 within `timeout` seconds. Runs in its own process group, which the
    /// timeout ends as a whole (`ScriptRunner`, Platform).
    static func run(_ command: String, timeout: TimeInterval) async -> AutomationScriptOutcome {
        let result = await ScriptRunner.run(command, timeout: timeout,
                                            options: .init(environment: environment, currentDirectory: NSHomeDirectory(),
                                                           capturesStandardError: true, outputLimit: outputLimit))
        let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return AutomationScriptOutcome(finishedAt: Date(), exitStatus: result.terminationStatus, timedOut: result.timedOut,
                                       output: text, duration: result.duration, launchError: result.launchError)
    }
}

/// Which script commands the user allowed to run on this Mac.
///
/// Kept in its own file (`Automations/script-approvals.json`), not in the settings, so a
/// settings import or a rule copied from elsewhere never arms a script. An approval is
/// bound to the rule id, the condition id and the exact command text.
final class AutomationScriptApprovals {
    let fileURL: URL
    private(set) var keys: Set<String>
    private let log = Log.logger("automations")

    init(fileURL: URL) {
        self.fileURL = fileURL
        let data = try? Data(contentsOf: fileURL)
        keys = Set(data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rolltop/Automations/script-approvals.json")
    }

    nonisolated static func key(ruleID: String, conditionID: String, command: String) -> String {
        let digest = SHA256.hash(data: Data("rolltop-script-v1\u{0}\(ruleID)\u{0}\(conditionID)\u{0}\(command)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func isApproved(ruleID: String, conditionID: String, command: String) -> Bool {
        keys.contains(Self.key(ruleID: ruleID, conditionID: conditionID, command: command))
    }

    func setApproved(_ approved: Bool, ruleID: String, conditionID: String, command: String) {
        let key = Self.key(ruleID: ruleID, conditionID: conditionID, command: command)
        let changed = approved ? keys.insert(key).inserted : keys.remove(key) != nil
        if changed { save() }
    }

    /// Keeps only approvals that still match a script of `rules`.
    func prune(rules: [AutomationRule]) {
        let live = Set(rules.flatMap { rule in
            rule.scriptConditions.map { Self.key(ruleID: rule.id, conditionID: $0.id, command: $0.script.command) }
        })
        let kept = keys.intersection(live)
        if kept != keys {
            keys = kept
            save()
        }
    }

    func revokeAll() {
        guard !keys.isEmpty else { return }
        keys = []
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(keys.sorted()).write(to: fileURL, options: .atomic)
        } catch {
            log.error("cannot save script approvals: \(error.localizedDescription)")
        }
    }
}
