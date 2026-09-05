#!/usr/bin/env bash
# Exercise the production supervisor without starting the app or using credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/Sources/Burrow" "$TEST_ROOT/Tests/BurrowTests"
cp "$ROOT/Sources/IMessageSidecar.swift" "$TEST_ROOT/Sources/Burrow/"
cp "$ROOT/Tests/"IMessageSidecar*Tests.swift "$TEST_ROOT/Tests/BurrowTests/"
cat > "$TEST_ROOT/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SidecarChecks", platforms: [.macOS(.v13)],
    targets: [.target(name: "Burrow"), .testTarget(name: "BurrowTests", dependencies: ["Burrow"])])
SWIFT
cat > "$TEST_ROOT/Sources/Burrow/Store.swift" <<'SWIFT'
enum Store {
    static let iMessageOwnerPhone = ""
    static let iMessageProjectId = ""
    static let iMessageProjectSecret = ""
    static let iMessageAgentEnabled = false
    static let iMessageLLMProvider = ""
    static let iMessageLLMModel = ""
    static let iMessageLLMBaseURL = ""
    static let iMessageLLMKey = ""
}
SWIFT
swift test --package-path "$TEST_ROOT"
