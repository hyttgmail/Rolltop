import Darwin
import Foundation
import Testing
@testable import Rolltop

/// The shared script runner (Platform/ScriptRunner.swift): own process group, minimal
/// environment, timeout that ends the whole group.
@Suite struct ScriptRunnerTests {
    private let options = ScriptRunner.Options(environment: ["PATH": "/usr/bin:/bin"], currentDirectory: "/",
                                               capturesStandardError: true)

    @Test func runsInItsOwnProcessGroupWithOnlyTheGivenEnvironment() async {
        let result = await ScriptRunner.run("echo pgid=$(ps -o pgid= -p $$ | tr -d ' ') pid=$$ home=${HOME:-unset}; pwd", timeout: 5,
                                            options: options)
        let text = String(decoding: result.output, as: UTF8.self)
        #expect(result.terminationStatus == 0)
        #expect(!result.timedOut)
        let group = result.processGroup.map(String.init) ?? "?"
        #expect(text.contains("pgid=\(group) pid=\(group)"), "\(text)")
        #expect(text.contains("home=unset"))
        #expect(text.hasSuffix("/\n"))
        #expect(group != String(getpgrp()), "never the caller's own group")
    }

    @Test func timeoutEndsBackgroundChildrenToo() async throws {
        let start = Date()
        let result = await ScriptRunner.run("sleep 30 & echo $!; sleep 30", timeout: 0.5, options: options)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(start) < 5)
        let line = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let child = try #require(pid_t(line))
        var gone = false
        for _ in 0..<30 {
            if kill(child, 0) != 0, errno == ESRCH { gone = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(gone, "background child \(child) survived the timeout")
    }

    @Test func childrenThatIgnoreTermAreKilled() async throws {
        let result = await ScriptRunner.run("trap '' TERM; (trap '' TERM; sleep 30) & echo $!; sleep 30", timeout: 0.3,
                                            options: ScriptRunner.Options(environment: [:], currentDirectory: "/",
                                                                          capturesStandardError: false, killGrace: 0.3))
        #expect(result.timedOut)
        let line = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let child = try #require(pid_t(line))
        var gone = false
        for _ in 0..<30 {
            if kill(child, 0) != 0, errno == ESRCH { gone = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(gone, "child \(child) that ignores TERM survived")
    }

    @Test func outputIsCappedAndStatusKept() async {
        let result = await ScriptRunner.run("yes x | head -c 10000; exit 3", timeout: 5,
                                            options: ScriptRunner.Options(environment: ["PATH": "/usr/bin:/bin"], currentDirectory: "/",
                                                                          capturesStandardError: false, outputLimit: 100))
        #expect(result.output.count == 100)
        #expect(result.terminationStatus == 3)
    }
}
