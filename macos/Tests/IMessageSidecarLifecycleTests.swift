import XCTest
import Darwin
@testable import Burrow

final class IMessageSidecarLifecycleTests: XCTestCase {
    private func waitForStarts(_ count: Int, at log: URL) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if text.split(separator: "\n").filter({ $0.hasPrefix("start") }).count >= count { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
    private func withSidecar(agent: Bool, timeout: TimeInterval = 10,
                             body: (IMessageSidecar, URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("fake-bun")
        // A local fixture records lifecycle only. No Bun/Photon/Claude or Burrow MCP runs.
        try """
        #!/bin/sh
        echo "start $$ $2" >> events
        trap 'echo "stop $$" >> events; exit 0' TERM INT
        while :; do /bin/sleep 0.03; done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let config = SidecarConfig(ownerPhone: "+15551234567", projectId: "fake", projectSecret: "fake", agentEnabled: agent,
                                   llmProvider: "claude-cli", llmModel: "", llmBaseURL: "", llmKey: "")
        let paths = SidecarPaths(dir: dir, bun: executable, agentEntry: URL(fileURLWithPath: "agent.ts"), checkEntry: URL(fileURLWithPath: "check.ts"))
        let sidecar = IMessageSidecar(configuration: { config }, paths: { paths }, checkInterval: 0.04, initialDelay: 0.02, checkTimeout: timeout)
        defer { sidecar.stop() }
        try body(sidecar, dir.appendingPathComponent("events"))
    }

    func testRepeatedStartDoesNotDuplicateAndStopTerminatesBothChildren() throws {
        try withSidecar(agent: true) { sidecar, log in
            sidecar.start(); sidecar.start()
            waitForStarts(2, at: log)
            let before = try String(contentsOf: log, encoding: .utf8)
            XCTAssertEqual(before.split(separator: "\n").filter { $0.hasPrefix("start") }.count, 2)
            sidecar.stop()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let after = try String(contentsOf: log, encoding: .utf8)
            XCTAssertEqual(after.split(separator: "\n").filter { $0.hasPrefix("stop") }.count, 2)
        }
    }

    func testTimedOutChecksReleaseTheirSlotWithoutOverlapping() throws {
        try withSidecar(agent: false, timeout: 0.1) { sidecar, log in
            sidecar.start()
            waitForStarts(2, at: log)
            sidecar.stop()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
            XCTAssertGreaterThanOrEqual(lines.filter { $0.hasPrefix("start") }.count, 2)
            var active = 0
            for line in lines {
                active += line.hasPrefix("start") ? 1 : -1
                XCTAssertTrue((0...1).contains(active), "overlapping check processes: \(lines)")
            }
            XCTAssertEqual(active, 0)
        }
    }
}
