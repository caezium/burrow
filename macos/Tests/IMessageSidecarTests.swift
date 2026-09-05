//
//  IMessageSidecarTests.swift
//  BurrowTests
//
//  The pure launch-spec builder for the iMessage sidecar: config → env vars +
//  args. No process is spawned; we assert the sidecar is handed the right
//  environment (delivery creds, LLM provider, MCP binary) and argv.
//

import XCTest
@testable import Burrow

final class IMessageSidecarTests: XCTestCase {
    private func cfg(agent: Bool = false) -> SidecarConfig {
        SidecarConfig(
            ownerPhone: "+8613410272240",
            projectId: "proj-1",
            projectSecret: "secret-1",
            agentEnabled: agent,
            llmProvider: "openrouter",
            llmModel: "anthropic/claude-sonnet-5",
            llmBaseURL: "",
            llmKey: "sk-or-xyz"
        )
    }

    func testEnvironment_carriesDeliveryAndMcpBinary() {
        let env = SidecarLaunch.environment(cfg(), burrowBin: "/Applications/Burrow.app/Contents/MacOS/Burrow")
        XCTAssertEqual(env["BURROW_ALERT_TO"], "+8613410272240")
        XCTAssertEqual(env["PHOTON_PROJECT_ID"], "proj-1")
        XCTAssertEqual(env["PHOTON_PROJECT_SECRET"], "secret-1")
        XCTAssertEqual(env["BURROW_BIN"], "/Applications/Burrow.app/Contents/MacOS/Burrow")
        XCTAssertEqual(env["NO_PROXY"], "*")           // Photon egress bypasses any local proxy
        XCTAssertEqual(env["LOG_LEVEL"], "silent")
    }

    func testEnvironment_omitsLLMKeysWhenAgentDisabled() {
        let env = SidecarLaunch.environment(cfg(agent: false), burrowBin: "/x")
        XCTAssertNil(env["BURROW_LLM_PROVIDER"])
        XCTAssertNil(env["BURROW_LLM_KEY"])
    }

    func testEnvironment_includesLLMKeysWhenAgentEnabled() {
        let env = SidecarLaunch.environment(cfg(agent: true), burrowBin: "/x")
        XCTAssertEqual(env["BURROW_LLM_PROVIDER"], "openrouter")
        XCTAssertEqual(env["BURROW_LLM_MODEL"], "anthropic/claude-sonnet-5")
        XCTAssertEqual(env["BURROW_LLM_KEY"], "sk-or-xyz")
    }

    func testArgs() {
        XCTAssertEqual(SidecarLaunch.agentArgs(entry: "/s/agent.ts"), ["run", "/s/agent.ts"])
        XCTAssertEqual(SidecarLaunch.checkArgs(entry: "/s/check.ts"), ["run", "/s/check.ts", "--scheduled"])
        XCTAssertEqual(SidecarLaunch.checkArgs(entry: "/s/check.ts", digest: true), ["run", "/s/check.ts", "--digest"])
    }

    func testHasDelivery() {
        XCTAssertTrue(cfg().hasDelivery)
        var c = cfg(); c.projectSecret = ""
        XCTAssertFalse(c.hasDelivery)
    }

    func testEnvironmentClearsStaleCredentialsAndFindsLocalClaude() {
        let env = SidecarLaunch.environment(cfg(agent: false), burrowBin: "/x", base: [
            "BURROW_LLM_KEY": "old-key", "BURROW_LLM_PROVIDER": "anthropic", "USE_JAN": "1", "PATH": "/usr/bin:/bin",
        ])
        XCTAssertNil(env["BURROW_LLM_KEY"])
        XCTAssertNil(env["BURROW_LLM_PROVIDER"])
        XCTAssertNil(env["USE_JAN"])
        XCTAssertTrue(env["PATH"]!.contains("/.local/bin"))
        XCTAssertTrue(env["BURROW_ALERT_STATE_DIR"]!.contains("Library/Application Support/Burrow/iMessage"))
        XCTAssertNotNil(env["BURROW_PARENT_PID"])
    }
}
