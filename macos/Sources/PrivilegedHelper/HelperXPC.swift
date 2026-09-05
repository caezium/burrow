//
//  HelperXPC.swift
//  Burrow / BurrowHelper (shared)
//
//  The XPC surface, and the names both sides must agree on.
//
//  The protocol is deliberately tiny, and the only method that
//  does privileged work takes an opaque request blob plus an authorization
//  blob — both of which the daemon decodes and validates itself. There is no
//  method that takes a command, a path, or an argument list, so the XPC
//  surface cannot be talked into running something the typed contract doesn't
//  already allow.
//

import Foundation

// MARK: - Names

enum HelperNames {
    /// The Mach service the daemon vends and the client connects to. Must
    /// match `MachServices` in the launchd property list.
    static let machService = "dev.caezium.Burrow.privileged-helper"

    /// The launchd label, and the property list file name inside the app at
    /// `Contents/Library/LaunchDaemons/`. `SMAppService.daemon(plistName:)`
    /// resolves the daemon from exactly that location.
    static let daemonPlist = "dev.caezium.Burrow.privileged-helper.plist"

    /// The bundle identifier the daemon requires of any caller.
    static let clientBundleID = "dev.caezium.Burrow"
}

// MARK: - Daemon interface

/// What the root daemon exposes. Implemented in the helper target.
@objc protocol BurrowHelperProtocol {
    /// Run one typed operation as root.
    ///
    /// - Parameters:
    ///   - requestData: a JSON-encoded `HelperRequest`. Opaque here on
    ///     purpose — the daemon decodes and validates it, so a malformed or
    ///     hostile payload is refused inside the privileged process rather
    ///     than being pre-parsed by the caller.
    ///   - authorization: the client's `AuthorizationExternalForm` bytes. The
    ///     daemon rebuilds the reference and REQUIRES the right, which is what
    ///     raises the authentication prompt.
    ///   - reply: a JSON-encoded `HelperResponse`.
    func execute(requestData: Data, authorization: Data, withReply reply: @escaping (Data) -> Void)

    /// The helper's own `CFBundleVersion`. The client compares it against its
    /// own build and refuses to use a helper that doesn't match, since a
    /// registered daemon outlives the app that installed it.
    func helperBuild(withReply reply: @escaping (String) -> Void)

    /// A JSON-encoded `HelperStatus`, including the wire protocol and the
    /// security checks this daemon implements. A build number alone cannot
    /// distinguish a running helper from another binary built with that same
    /// number. Clients must require this handshake before sending work; old
    /// daemons without this selector fall back to the guarded osascript path.
    func helperStatus(withReply reply: @escaping (Data) -> Void)

    /// Ask the daemon to terminate a running operation.
    ///
    /// This exists because the osascript path could NOT do it: killing
    /// `osascript` orphans the root child it spawned, so the old streaming
    /// flow had no safe way to cancel. The daemon owns the child process
    /// directly, so it can signal it and reap it properly.
    func cancelOperation(operationID: String, withReply reply: @escaping (Bool) -> Void)
}

// MARK: - Client interface

/// What the daemon can call back on the client — output streaming only.
/// Nothing here grants the daemon any authority over the app.
@objc protocol BurrowHelperClientProtocol {
    /// One line of engine output, ANSI already stripped by the daemon.
    func helperDidEmit(line: String, operationID: String)
}

// MARK: - Interface configuration

enum HelperInterface {
    /// Both sides build their `NSXPCInterface` here so the shapes can't drift.
    static func daemon() -> NSXPCInterface {
        NSXPCInterface(with: BurrowHelperProtocol.self)
    }

    static func client() -> NSXPCInterface {
        NSXPCInterface(with: BurrowHelperClientProtocol.self)
    }
}
