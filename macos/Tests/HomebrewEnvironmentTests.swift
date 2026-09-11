//
//  HomebrewEnvironmentTests.swift
//  BurrowTests
//
//  The login-shell import behind #424: only `HOMEBREW_*` crosses from the
//  user's shell into the brew Burrow spawns, PATH stays Burrow's own, and
//  the local list read turns auto-update off.
//

import XCTest
@testable import Burrow

final class HomebrewEnvironmentTests: XCTestCase {
    func testParseKeepsOnlyWellFormedHomebrewAssignments() {
        let output = """
        Welcome banner printed by .zshrc
        PATH=/opt/homebrew/bin:/usr/bin
        HOMEBREW_API_DOMAIN=https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api
        HOMEBREW_BOTTLE_DOMAIN=https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles
        HOMEBREW_NO_ENV_HINTS=1
        HOMEBREW_=no name
        HOMEBREW_lower=no
        HOMEBREW_EMPTY=
        homebrew_prefix=/opt/homebrew
        HOMEBREW_WITH_EQUALS=a=b
        SHELL=/bin/zsh
        """
        XCTAssertEqual(HomebrewEnvironment.parse(output), [
            "HOMEBREW_API_DOMAIN": "https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api",
            "HOMEBREW_BOTTLE_DOMAIN": "https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_WITH_EQUALS": "a=b",
        ])
    }

    func testParseOfNoiseIsEmpty() {
        XCTAssertTrue(HomebrewEnvironment.parse("").isEmpty)
        XCTAssertTrue(HomebrewEnvironment.parse("zsh: can't set job control\n=\nHOMEBREW\n").isEmpty)
    }

    func testLoginShellMustBeAnAbsoluteExecutableAndDefaultsToZsh() {
        XCTAssertEqual(HomebrewEnvironment.loginShell(environment: ["SHELL": "/bin/zsh"]), "/bin/zsh")
        XCTAssertEqual(HomebrewEnvironment.loginShell(environment: [:]), "/bin/zsh")
        XCTAssertEqual(HomebrewEnvironment.loginShell(environment: ["SHELL": ""]), "/bin/zsh")
        XCTAssertNil(HomebrewEnvironment.loginShell(environment: ["SHELL": "zsh"]))
        XCTAssertNil(HomebrewEnvironment.loginShell(environment: ["SHELL": "/nonexistent/shell"]))
    }

    func testBrewEnvironmentLayersImportsOverTheAppEnvironment() {
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/x", "HOMEBREW_NO_AUTO_UPDATE": "0"]
        let imported = [
            "HOMEBREW_API_DOMAIN": "https://mirror.example/api",
            "PATH": "/tmp/evil",
            "HOMEBREW_bad": "x",
        ]

        let local = BrewClient.environment(
            brew: "/opt/homebrew/bin/brew", autoUpdate: false, base: base, imported: imported)
        XCTAssertEqual(local["PATH"], "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/bin:/bin")
        XCTAssertEqual(local["HOMEBREW_API_DOMAIN"], "https://mirror.example/api")
        XCTAssertNil(local["HOMEBREW_bad"])
        XCTAssertEqual(local["HOME"], "/Users/x")
        XCTAssertEqual(local["HOMEBREW_NO_AUTO_UPDATE"], "1", "a local read never fetches, whatever the user set")

        let network = BrewClient.environment(
            brew: "/opt/homebrew/bin/brew", autoUpdate: true, base: base, imported: imported)
        XCTAssertEqual(network["HOMEBREW_NO_AUTO_UPDATE"], "0", "otherwise the user's own setting stands")
    }
}
