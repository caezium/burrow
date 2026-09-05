//
//  HelperContract.swift
//  Burrow / BurrowHelper (shared)
//
//  The wire contract between the GUI and the root helper. Compiled into BOTH
//  targets so the two can never disagree about what a request means.
//
//  Everything in this file is pure Foundation — no SwiftUI, no Sparkle, no
//  Sentry — because the helper is a bare launchd daemon that must stay small,
//  auditable, and free of anything that could pull UI or network code into a
//  root process.
//
//  ── Why the contract looks like this ────────────────────────────────────
//  The old elevation path handed osascript a SHELL STRING built from an
//  executable path plus argv (`EngineCLI.elevatedScript`). It was carefully
//  quoted and well tested, but its shape meant the privileged side had to
//  trust whatever command the caller composed.
//
//  This contract inverts that. A request names an OPERATION and nothing else.
//  The argv is derived from the enum on the privileged side, so the set of
//  commands the helper can ever run is fixed at compile time and visible in
//  one switch statement. There is deliberately no field for a path, a flag, a
//  binary, or a command string — a client that is fully compromised still
//  cannot express "run this".
//

import Foundation

// MARK: - The closed operation set

/// Every privileged thing Burrow can ask for. Adding a case here is a
/// security decision, not a feature decision: it widens what the root daemon
/// is capable of doing, permanently, for every installed copy.
enum HelperOperation: String, Codable, CaseIterable, Sendable {
    /// Enumerate what a clean WOULD remove. Reads privileged locations; the
    /// engine's `--dry-run` guarantees no mutation.
    case scan
    /// Remove the caches the engine's own rules select.
    case clean
    /// Remove exactly the entries the user reviewed and ticked.
    ///
    /// This is the only operation that accepts data from the caller beyond a
    /// verb, which deserves saying plainly. It does NOT weaken the rule that a
    /// compromised client cannot express "run this": the argv is still built
    /// here, the executable is still the bundled engine, and the paths are
    /// values the daemon writes into a plan file of its own for the engine's
    /// `clean --apply --plan` — never anything executed, and never a file the
    /// client could hand root.
    ///
    /// What stops a compromised client asking root to delete something it
    /// shouldn't is that the daemon does not trust the list. It rebuilds the
    /// approved roots from its OWN getpwuid record, and re-derives every fact
    /// it checks — existence, symlink-ness, canonical form, volume, owner —
    /// with its own lstat; then the engine re-checks every path through its
    /// deletion rails and refuses anything outside its clean roots. The client
    /// proposes; the privileged side decides, twice.
    case cleanReviewed
    /// The engine's maintenance pass.
    case optimize
    /// Enumerate what an optimize WOULD do. The optimize counterpart of
    /// `scan`, so the elevated preview of either operation behaves the same.
    case optimizeScan
    /// Flush the DNS cache and signal mDNSResponder to reload.
    case flushDNS
    /// Renew the DHCP lease on one network interface.
    case renewDHCP
    /// Dump the Background Task Management database — the modern Login and
    /// background items list.
    ///
    /// Read-only, but it needs root twice over: `sfltool dumpbtm` raises its
    /// OWN authentication dialog when run as a normal user, and returns only
    /// a partial list even then. Through the helper it is one authentication
    /// the user already understands, and the complete list.
    case readLoginItems

    /// The engine argv for the operations that drive the bundled engine with a
    /// FIXED command line, or nil for the ones that don't (the network fixes,
    /// the login-items dump, and the reviewed clean — whose argv carries the
    /// daemon's own plan file and is built in `steps`).
    ///
    /// Spelled in the ENGINE's convention, because that is what the daemon
    /// runs: the bundled engine previews by default and needs `--apply` to
    /// act, the inverse of mo. `--stream` is always on — the daemon relays the
    /// engine's stdout line by line over XPC, so the GUI gets the same live
    /// NDJSON feed an un-elevated run does — and `--dry-run` is stated on the
    /// previews rather than inherited from the default, so a read-only run is
    /// a fact on the wire.
    var engineArguments: [String]? {
        switch self {
        case .scan: return ["clean", "--dry-run", "--stream"]
        case .clean: return ["clean", "--apply", "--stream"]
        case .optimize: return ["optimize", "--apply", "--stream"]
        case .optimizeScan: return ["optimize", "--dry-run", "--stream"]
        case .flushDNS, .renewDHCP, .readLoginItems, .cleanReviewed: return nil
        }
    }

    /// Whether the operation runs the bundled engine (so the daemon must
    /// prepare its verified execution snapshot first) rather than a system
    /// tool from the closed set.
    var usesBundledEngine: Bool {
        switch self {
        case .scan, .clean, .optimize, .optimizeScan, .cleanReviewed: return true
        case .flushDNS, .renewDHCP, .readLoginItems: return false
        }
    }

    var needsInterface: Bool { self == .renewDHCP }

    /// Whether this operation is driven by a reviewed path list. Exactly one
    /// operation is, and it is required to be non-empty for that one and
    /// required to be absent for every other.
    var needsReviewedPaths: Bool { self == .cleanReviewed }

    /// The engine argv for a reviewed clean over `planFile` — the plan file the
    /// DAEMON wrote from the paths it validated, never a client-supplied path.
    /// Fixed flags around that one value: `--apply --permanent` because this is
    /// the permanent path (the Trash mode never reaches the helper), `--plan`
    /// so the engine removes only the listed paths with no re-scan, each
    /// re-checked through its rails, `--stream` for the live relay.
    static func reviewedCleanArguments(planFile: String) -> [String] {
        ["clean", "--apply", "--permanent", "--plan", planFile, "--stream"]
    }

    /// The exact process steps the daemon runs, in order.
    ///
    /// Every executable is an absolute path from a closed set, and every
    /// argument is either a literal spelled here, an interface name that
    /// `HelperRequest.validate` has already proved is a real interface on this
    /// machine, or the daemon's own plan file (`reviewedPlanFile`, consumed
    /// only by `.cleanReviewed`; without one the reviewed clean resolves to NO
    /// steps rather than an engine run over something else). Nothing is
    /// passed to a shell.
    ///
    /// That last point is a security improvement over the path this replaces:
    /// `Connectivity.run` currently elevates
    /// `/bin/sh -c "dscacheutil -flushcache; killall -HUP mDNSResponder"`,
    /// so a root shell parses a command string. Here the two commands are two
    /// separate `posix_spawn` calls with fixed argv and no shell in between.
    func steps(interface: String?, reviewedPlanFile: String? = nil) -> [HelperStep] {
        switch self {
        case .scan, .clean, .optimize, .optimizeScan:
            return [HelperStep(executable: .bundledEngine, arguments: engineArguments ?? [])]
        case .cleanReviewed:
            guard let reviewedPlanFile else { return [] }
            return [HelperStep(executable: .bundledEngine,
                               arguments: Self.reviewedCleanArguments(planFile: reviewedPlanFile))]
        case .flushDNS:
            return [
                HelperStep(executable: .system(HelperSystemTool.dscacheutil), arguments: ["-flushcache"]),
                HelperStep(executable: .system(HelperSystemTool.killall), arguments: ["-HUP", "mDNSResponder"]),
            ]
        case .renewDHCP:
            guard let interface else { return [] }
            return [HelperStep(executable: .system(HelperSystemTool.ipconfig),
                               arguments: ["set", interface, "DHCP"])]
        case .readLoginItems:
            return [HelperStep(executable: .system(HelperSystemTool.sfltool),
                               arguments: ["dumpbtm"])]
        }
    }

    /// Whether this operation mutates the disk. `scan` is read-only, but it
    /// still authenticates: it reads privileged locations, and the product
    /// decision was that anything running AS ROOT prompts.
    var mutatesDisk: Bool {
        switch self {
        case .scan, .optimizeScan: return false
        case .clean, .optimize, .cleanReviewed: return true
        // These change system state or read privileged data rather than
        // touching the filesystem, but all run as root, so all authenticate.
        case .flushDNS, .renewDHCP: return false
        case .readLoginItems: return false
        }
    }

    /// Recognise an elevated call site's argv as a typed operation, or `nil`
    /// if it isn't one of them.
    ///
    /// This is the migration seam. `OperationFlow` still describes elevated
    /// work as argv — the engine-convention argv `BurrowEngine.streamArgv` /
    /// `engineArgv` produce: `["clean", "--apply", "--stream"]` for a live
    /// clean, `["clean", "--stream"]` (or `["clean", "--dry-run", "--stream"]`)
    /// for its preview, and the same shapes for optimize, with `--stream`
    /// absent when the streaming switch is off. This maps exactly those onto
    /// the helper WITHOUT letting anything else through: the verb must come
    /// first, every flag must be one of the three the engine takes on these
    /// commands, and `--apply` with `--dry-run` is a contradiction the engine
    /// itself refuses. Anything else returns nil and keeps the existing
    /// osascript route, rather than being forwarded as some approximate
    /// operation.
    ///
    /// The engine's convention decides the mapping, never mo's: a bare
    /// `["clean"]` is a PREVIEW here, because that is what the engine does
    /// with it. Reading it as the live clean (as the first version of this
    /// seam did, from mo's convention) would have had the daemon run the
    /// engine's dry run and report a cleanup that removed nothing.
    init?(engineArguments: [String]) {
        guard let verb = engineArguments.first, ["clean", "optimize"].contains(verb) else { return nil }
        let flags = engineArguments.dropFirst()
        let allowed: Set<String> = ["--apply", "--dry-run", "--stream"]
        guard flags.allSatisfy({ allowed.contains($0) }),
              Set(flags).count == flags.count else { return nil }
        let apply = flags.contains("--apply")
        guard !(apply && flags.contains("--dry-run")) else { return nil }
        switch (verb, apply) {
        case ("clean", true): self = .clean
        case ("clean", false): self = .scan
        case ("optimize", true): self = .optimize
        case ("optimize", false): self = .optimizeScan
        default: return nil
        }
    }
}

// MARK: - Execution model

/// The only system binaries the daemon may ever execute, by absolute path.
///
/// A closed set, spelled once. The daemon never resolves a name through
/// `PATH` and never accepts a path from a caller — those are the two ways a
/// root process ends up running somebody else's binary.
enum HelperSystemTool {
    static let dscacheutil = "/usr/bin/dscacheutil"
    static let killall = "/usr/bin/killall"
    static let ipconfig = "/usr/sbin/ipconfig"
    static let sfltool = "/usr/bin/sfltool"

    /// Every permitted absolute path. Used by the daemon to re-check an
    /// executable immediately before spawning it, so a step constructed by
    /// some future code path still cannot introduce a new binary.
    static let all: Set<String> = [dscacheutil, killall, ipconfig, sfltool]
}

/// What a step runs.
enum HelperExecutable: Equatable, Sendable {
    /// The signed engine inside our own app bundle, resolved by the daemon.
    case bundledEngine
    /// One of `HelperSystemTool.all`, by absolute path.
    case system(String)
}

/// One process the daemon spawns. An operation is an ordered list of these.
struct HelperStep: Equatable, Sendable {
    let executable: HelperExecutable
    let arguments: [String]
}

// MARK: - Invoking user

/// The non-privileged app's statement of who initiated the operation. This is
/// a consistency claim, never authority: the daemon binds it to the XPC
/// peer's effective uid and reconstructs the account from its own user
/// database before using either value.
struct HelperInvokingUserClaim: Codable, Equatable, Sendable {
    let uid: UInt32
    let canonicalHome: String
}

/// One account record from the daemon's user database. Kept as data so the
/// selection rule can be tested with several signed-in/local accounts without
/// consulting the test runner's real account.
struct HelperInvokingUserAccount: Equatable, Sendable {
    let uid: UInt32
    let username: String
    let homeDirectory: String
}

/// The daemon's descriptor-based inspection of the home named by getpwuid.
/// A path supplied by the client never creates this value.
struct HelperHomeInspection: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case directory
        case symbolicLink
        case other
        case missing
    }

    let kind: Kind
    let canonicalPath: String?
    let ownerUID: UInt32?
}

struct HelperResolvedInvokingUser: Equatable, Sendable {
    let uid: UInt32
    let username: String
    let canonicalHome: String

    /// A complete, deterministic environment for every root child. Nothing is
    /// inherited from launchd and no client-provided string is copied here.
    /// Built by `PrivilegedEngineEnvironment` so the daemon and the osascript
    /// path hand the engine the same variables.
    var childEnvironment: [String: String] {
        Dictionary(uniqueKeysWithValues: PrivilegedEngineEnvironment.variables(
            home: canonicalHome, username: username, uid: uid).map { ($0.key, $0.value) })
    }
}

/// The environment every ELEVATED engine invocation runs with — the one
/// builder behind both elevation routes (the privileged helper's
/// `childEnvironment` and the osascript `elevatedScript` preamble), so the
/// two cannot hand the engine different facts about who asked.
///
/// Two variables are the engine's own privileged-run contract (burrow-engine
/// BUR-130/BUR-141) and exist because a root process has a root `$HOME`:
///
///   * `BURROW_HOME` — the invoking user's real home, as the engine's
///     highest-precedence home override. Without it an elevated uninstall
///     enumerates leftovers under `/var/root`, finds none, and reports "no
///     support files" about an app with hundreds of megabytes of them; the
///     engine refuses to run with a `/var/root` home unless this is set.
///   * `BURROW_PRIVILEGED=1` — tells the engine it is running with rights
///     the invoking user does not have, so it ignores `BURROW_FCLONES` /
///     `BURROW_BRCTL` overrides pointing outside its own bundle directory.
///     A user-writable override is exactly what must never be handed root.
///
/// Ordered, because the osascript preamble is a shell string and tests pin
/// its exact text.
enum PrivilegedEngineEnvironment {
    static let homeKey = "BURROW_HOME"
    static let privilegedKey = "BURROW_PRIVILEGED"
    static let privilegedValue = "1"

    static func variables(home: String, username: String, uid: UInt32) -> [(key: String, value: String)] {
        [
            ("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
            ("HOME", home),
            ("USER", username),
            ("LOGNAME", username),
            ("SUDO_USER", username),
            ("SUDO_UID", String(uid)),
            ("LC_ALL", "C"),
            (homeKey, home),
            (privilegedKey, privilegedValue),
        ]
    }
}

enum HelperInvokingUserResolutionError: Error, Equatable, Sendable {
    case rootPeer
    case claimUIDMismatch
    case missingAccount
    case invalidUsername
    case invalidAccountHome
    case missingHome
    case symbolicLinkHome
    case homeNotDirectory
    case homeOwnerMismatch
    case canonicalHomeMismatch
}

/// The fail-closed identity rule shared by the app tests and daemon. The
/// daemon supplies getpwuid data and a no-follow filesystem inspection; this
/// function decides whether those authoritative facts agree with the XPC peer
/// and the app's pre-authorization claim.
enum HelperInvokingUserResolver {
    static func resolve(
        peerUID: UInt32,
        claim: HelperInvokingUserClaim,
        accounts: [HelperInvokingUserAccount],
        inspectHome: (String) -> HelperHomeInspection
    ) throws -> HelperResolvedInvokingUser {
        guard peerUID != 0 else { throw HelperInvokingUserResolutionError.rootPeer }
        guard claim.uid == peerUID else { throw HelperInvokingUserResolutionError.claimUIDMismatch }
        guard let account = accounts.first(where: { $0.uid == peerUID }) else {
            throw HelperInvokingUserResolutionError.missingAccount
        }
        guard isSafeEnvironmentValue(account.username), account.username != "root" else {
            throw HelperInvokingUserResolutionError.invalidUsername
        }
        guard account.homeDirectory.hasPrefix("/"),
              isSafeEnvironmentValue(account.homeDirectory) else {
            throw HelperInvokingUserResolutionError.invalidAccountHome
        }

        let home = inspectHome(account.homeDirectory)
        switch home.kind {
        case .missing: throw HelperInvokingUserResolutionError.missingHome
        case .symbolicLink: throw HelperInvokingUserResolutionError.symbolicLinkHome
        case .other: throw HelperInvokingUserResolutionError.homeNotDirectory
        case .directory: break
        }
        guard let canonicalHome = home.canonicalPath,
              canonicalHome.hasPrefix("/"), canonicalHome != "/",
              canonicalHome != "/var/root", canonicalHome != "/private/var/root",
              isSafeEnvironmentValue(canonicalHome) else {
            throw HelperInvokingUserResolutionError.invalidAccountHome
        }
        guard home.ownerUID == peerUID else {
            throw HelperInvokingUserResolutionError.homeOwnerMismatch
        }
        guard claim.canonicalHome == canonicalHome else {
            throw HelperInvokingUserResolutionError.canonicalHomeMismatch
        }

        return HelperResolvedInvokingUser(uid: peerUID,
                                         username: account.username,
                                         canonicalHome: canonicalHome)
    }

    private static func isSafeEnvironmentValue(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}

// MARK: - Reviewed cleanup targets

/// The original review identities survive the authentication dialog and the XPC boundary.
/// The daemon still derives its allowed roots independently; these only narrow that authority.
struct HelperReviewedSelection: Codable, Equatable, Sendable {
    let expiresAt: Date
    let roots: [PinnedFileIdentity]
    let items: [PinnedFileIdentity]

    func matches(paths: [String], now: Date = Date(),
                 inspect: (PinnedFileIdentity) -> Bool = { $0.matchesCurrent() }) -> Bool {
        guard now <= expiresAt, !roots.isEmpty,
              roots.count <= HelperReviewedPathPolicy.maximumTargets,
              !items.isEmpty, items.count <= HelperReviewedPathPolicy.maximumTargets,
              items.count == paths.count,
              Set(items.map(\.path)) == Set(paths),
              roots.allSatisfy(inspect), items.allSatisfy(inspect) else { return false }
        return true
    }
}

/// One approved root, as the DAEMON derives it. The invoking user's home comes
/// from getpwuid and the rest are fixed system cache locations; a client never
/// contributes to this list.
struct HelperReviewedRoot: Equatable, Sendable {
    let path: String
    let device: UInt64
    /// System cache trees are root-owned and shared, so their contents
    /// legitimately belong to other accounts. A per-user tree is not: deleting
    /// another account's files there would be a real escalation, since the
    /// invoking user could not do it themselves.
    let allowsForeignOwner: Bool

    var prefix: String { path.hasSuffix("/") ? path : path + "/" }
}

/// The daemon's own lstat of a proposed target. Injected so the rule below is
/// a pure function and can be tested against layouts the test host doesn't have.
struct HelperReviewedTarget: Equatable, Sendable {
    let exists: Bool
    let isSymbolicLink: Bool
    let canonicalPath: String?
    let device: UInt64
    let ownerUID: UInt32
}

enum HelperReviewedPathRejection: String, Error, Codable, Equatable, Sendable {
    case emptySelection
    case tooManyTargets
    case malformedPath
    case missingPath
    case symbolicLink
    case notCanonical
    case outsideApprovedRoots
    case foreignVolume
    case foreignOwner
}

/// What root is allowed to delete on a client's say-so.
///
/// Every rule here is enforced against facts the daemon gathered itself. The
/// client's list is a proposal; nothing in it is taken on trust, including
/// whether a path exists or where it points.
enum HelperReviewedPathPolicy {
    /// A reviewed clean is a handful of cache entries. A list far past that is
    /// not a user's selection, and an unbounded one is a way to make the root
    /// daemon do unbounded work.
    static let maximumTargets = 4096

    static func validate(paths: [String],
                         roots: [HelperReviewedRoot],
                         invokingUID: UInt32,
                         inspect: (String) -> HelperReviewedTarget)
        -> Result<[String], HelperReviewedPathRejection> {
        guard !paths.isEmpty else { return .failure(.emptySelection) }
        guard paths.count <= maximumTargets else { return .failure(.tooManyTargets) }
        guard !roots.isEmpty else { return .failure(.outsideApprovedRoots) }

        var accepted: [String] = []
        var seen = Set<String>()
        for path in paths {
            guard path.hasPrefix("/"), path != "/", !path.hasSuffix("/"),
                  !path.contains("/../"), !path.hasSuffix("/.."),
                  !path.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else { return .failure(.malformedPath) }

            let target = inspect(path)
            guard target.exists else { return .failure(.missingPath) }
            // A symlink would let the delete land on whatever it points at.
            guard !target.isSymbolicLink else { return .failure(.symbolicLink) }
            // realpath must agree with the literal path, so no component along
            // the way is a link either.
            guard let canonical = target.canonicalPath, canonical == path else {
                return .failure(.notCanonical)
            }
            // A root itself is never deletable — only things strictly below it.
            guard let root = roots.first(where: {
                path != $0.path && path.hasPrefix($0.prefix)
            }) else { return .failure(.outsideApprovedRoots) }
            guard target.device == root.device else { return .failure(.foreignVolume) }
            guard root.allowsForeignOwner || target.ownerUID == invokingUID else {
                return .failure(.foreignOwner)
            }
            // Duplicates are dropped rather than refused: the same entry twice
            // is harmless, and the second find would just fail on a missing path.
            if seen.insert(path).inserted { accepted.append(path) }
        }
        return .success(accepted)
    }
}

// MARK: - Request

/// Why a request never reached the authorization step. Named so the GUI can
/// explain the refusal instead of showing a bare failure, and so a rejection
/// is never confused with "the command ran and failed".
enum HelperRequestRejection: String, Codable, Equatable, Sendable {
    /// The payload wasn't decodable as a request at all.
    case malformedPayload
    /// The operation ID wasn't a UUID (see `HelperRequest.operationID`).
    case malformedOperationID
    /// The helper's build doesn't match the app's — see `HelperVersionSkew`.
    case buildMismatch
    /// This operation ID was already served. One authorization, one operation.
    case replayedOperationID
    /// The interface name was missing, malformed, or not a real interface on
    /// this machine — or was supplied for an operation that takes none.
    case invalidInterface
    /// The invoking-user claim was malformed or did not match the XPC peer,
    /// daemon account database, and inspected home directory.
    case invalidInvokingUser
    /// The reviewed path list was missing, oversized, or contained an entry
    /// the daemon's own inspection refused. See `HelperReviewedPathPolicy`.
    case invalidReviewedPaths
}

/// One privileged operation, fully described. None of its fields can carry a
/// command; the identity fields are consistency claims checked by the daemon.
struct HelperRequest: Codable, Equatable, Sendable {
    let operation: HelperOperation

    /// A fresh UUID per request. This is the replay key: the daemon serves any
    /// given ID at most once, so a captured payload — external authorization
    /// form and all — cannot be resent to buy a second root run out of one
    /// prompt. A client-chosen constant would defeat that, hence the format
    /// check rather than "any non-empty string".
    let operationID: String

    /// `CFBundleVersion` of the calling app, compared against the helper's own.
    /// A registered daemon outlives the app that installed it (Sparkle replaces
    /// Burrow.app underneath it), and a stale root helper holding an older idea
    /// of what `clean` does is exactly the drift worth refusing.
    let clientBuild: String

    /// The uid and canonical home resolved by the app before authentication.
    /// This is mandatory context for every privileged action, but only a
    /// claim: the daemon independently resolves and verifies both values.
    let invokingUser: HelperInvokingUserClaim

    /// The network interface for `renewDHCP`, and nil for everything else.
    ///
    /// This is the ONLY caller-supplied value that reaches a child process's
    /// argv, which is why it is checked twice: against a strict character
    /// shape, and against the interfaces that actually exist on this machine.
    /// A name that isn't a real interface is refused rather than passed on.
    var networkInterface: String? = nil

    /// The entries the user reviewed and ticked, for `cleanReviewed` and
    /// nothing else.
    ///
    /// These reach a child process's argv, but only as operands to a fixed
    /// `find … -delete` the daemon composes, and only after the daemon has
    /// re-derived every fact it checks about them. Empty for every other
    /// operation, and an operation that carries them when it shouldn't is
    /// refused rather than having them ignored.
    var reviewedPaths: [String] = []
    var reviewedSelection: HelperReviewedSelection? = nil

    init(operation: HelperOperation,
         operationID: String,
         clientBuild: String,
         invokingUser: HelperInvokingUserClaim,
         networkInterface: String? = nil,
          reviewedPaths: [String] = [],
          reviewedSelection: HelperReviewedSelection? = nil) {
        self.operation = operation
        self.operationID = operationID
        self.clientBuild = clientBuild
        self.invokingUser = invokingUser
        self.networkInterface = networkInterface
        self.reviewedPaths = reviewedPaths
        self.reviewedSelection = reviewedSelection
    }

    /// `nil` when the request is well formed. Runs on the PRIVILEGED side —
    /// the client's own validation is a courtesy, this one is the boundary.
    ///
    /// `liveInterfaces` is injected so the rule stays pure and testable; the
    /// daemon passes the real list from the system.
    func validate(expectedBuild: String,
                  liveInterfaces: @autoclosure () -> Set<String> = []) -> HelperRequestRejection? {
        guard UUID(uuidString: operationID) != nil else { return .malformedOperationID }
        guard HelperVersionSkew.evaluate(appBuild: expectedBuild, helperBuild: clientBuild) == .matched else {
            return .buildMismatch
        }
        guard invokingUser.uid != 0,
              invokingUser.canonicalHome.hasPrefix("/"),
              invokingUser.canonicalHome != "/",
              invokingUser.canonicalHome != "/var/root",
              invokingUser.canonicalHome != "/private/var/root",
              !invokingUser.canonicalHome.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return .invalidInvokingUser }

        if operation.needsReviewedPaths {
            // Shape only. Whether these paths may actually be deleted is
            // decided by HelperReviewedPathPolicy against the daemon's own
            // lstat — this check just refuses obvious nonsense early.
            guard !reviewedPaths.isEmpty,
                  reviewedPaths.count <= HelperReviewedPathPolicy.maximumTargets,
                  reviewedSelection != nil
            else { return .invalidReviewedPaths }
        } else {
            // Paths on an operation that takes none means the caller and this
            // contract disagree about what is being asked for.
            guard reviewedPaths.isEmpty, reviewedSelection == nil else { return .invalidReviewedPaths }
        }

        if operation.needsInterface {
            guard let name = networkInterface,
                  HelperRequest.isPlausibleInterfaceName(name),
                  liveInterfaces().contains(name) else { return .invalidInterface }
        } else {
            // An interface on an operation that takes none means the caller
            // and this contract disagree about what is being asked for.
            // Refuse rather than silently ignore it.
            guard networkInterface == nil else { return .invalidInterface }
        }
        return nil
    }

    /// BSD interface names are short, lowercase, and end in a unit number —
    /// `en0`, `utun3`, `bridge0`, `awdl0`. Anything else (a path, a flag, a
    /// space, a shell metacharacter) is refused outright rather than escaped:
    /// there is no legitimate interface name outside this shape, so rejecting
    /// costs nothing and removes the whole question.
    static func isPlausibleInterfaceName(_ name: String) -> Bool {
        guard (2...15).contains(name.count) else { return false }
        var sawDigit = false
        var letters = 0
        for scalar in name.unicodeScalars {
            if scalar >= "a" && scalar <= "z" {
                guard !sawDigit else { return false }   // letters must precede digits
                letters += 1
            } else if scalar >= "0" && scalar <= "9" {
                sawDigit = true
            } else {
                return false
            }
        }
        return letters >= 2 && sawDigit
    }
}

// MARK: - Response

/// What a privileged operation produced. The failure cases mirror the
/// osascript path's `ElevatedOutcome` so the GUI keeps ONE error taxonomy
/// across both elevation routes (the rule issue #48 established).
struct HelperResponse: Codable, Equatable, Sendable {
    enum Outcome: Codable, Equatable, Sendable {
        /// The engine ran and exited with this status.
        case exited(Int32)
        /// The user dismissed the authentication prompt.
        case authorizationCancelled
        /// Authentication was attempted and refused (wrong credentials, not an
        /// administrator, interaction unavailable).
        case authorizationDenied
        /// The request never reached authorization.
        case rejected(HelperRequestRejection)
        /// The signed, bundled engine could not be resolved or failed
        /// verification — so nothing was executed.
        case engineUnavailable

        /// Collapse to the `Int32` the existing call sites branch on. Every
        /// failure shape is nonzero: a dismissed prompt must never read as
        /// success.
        var exitCode: Int32 {
            switch self {
            case .exited(let code): return code
            case .authorizationCancelled, .authorizationDenied: return 1
            case .rejected: return 78          // EX_CONFIG: the request was refused, not run
            case .engineUnavailable: return 127
            }
        }

        // The bridge onto the GUI's existing `ElevatedOutcome` taxonomy lives
        // in PrivilegedHelperClient.swift — that type belongs to the app, and
        // this file also compiles into the daemon, which must stay free of
        // anything GUI-side.
    }

    let outcome: Outcome
}

// MARK: - Replay guard

/// Remembers which operation IDs have already been served, so one
/// authorization buys exactly one root operation.
///
/// Bounded on purpose: a daemon can stay resident for weeks, and an unbounded
/// set would grow with every request a client cared to send.
///
/// Eviction is by AGE, not by count. A count-bounded FIFO looks equivalent but
/// isn't: a caller could send `capacity` fresh IDs to push an older one out of
/// the set and then replay that older payload, turning the bound itself into
/// the bypass. Age-based eviction cannot be driven that way — an ID is only
/// forgotten once it is far older than any authorization could still be valid
/// for, so the practical replay window is always covered no matter how much
/// traffic arrives. The count cap remains as a memory backstop, but it only
/// discards entries that are ALREADY expired.
final class HelperReplayGuard: @unchecked Sendable {
    /// Comfortably longer than the gap between authenticating and executing,
    /// and longer than the authorization credential's own ten-second life, so
    /// nothing still-usable is ever forgotten.
    static let retention: TimeInterval = 3600

    private let capacity: Int
    private let retention: TimeInterval
    private let now: () -> Date
    private var order: [(id: String, at: Date)] = []
    private var seen: Set<String> = []
    private let lock = NSLock()

    init(capacity: Int = 8192,
         retention: TimeInterval = HelperReplayGuard.retention,
         now: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.retention = max(1, retention)
        self.now = now
    }

    /// Number of IDs currently remembered.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return seen.count
    }

    /// The hard memory ceiling. Refusing to forget a still-replayable ID is the
    /// right call, but it cannot mean growing without limit inside a process
    /// running as root: a caller sending fresh IDs would otherwise enlarge the
    /// set for the whole retention window. Past this many live entries the
    /// guard stops admitting instead of stops remembering, so the failure is a
    /// refused request rather than a forgotten ID that could then be replayed.
    private var ceiling: Int { capacity * 16 }

    /// `true` the first time an ID is presented, `false` for every repeat —
    /// and `false` once the set is full, which fails the request closed.
    func admit(_ operationID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let moment = now()
        evictExpired(before: moment.addingTimeInterval(-retention))
        guard !seen.contains(operationID) else { return false }
        // Checked AFTER eviction, so a full set means genuinely fresh entries
        // rather than accumulated expired ones.
        guard seen.count < ceiling else { return false }
        seen.insert(operationID)
        order.append((operationID, moment))
        return true
    }

    /// Drop only entries older than the retention window. If a flood pushes
    /// past `capacity` while every entry is still fresh, the guard keeps them
    /// — refusing to forget a replayable ID matters more than the memory,
    /// and the entries are short strings.
    private func evictExpired(before cutoff: Date) {
        guard let first = order.first, first.at <= cutoff || order.count > capacity else { return }
        var index = 0
        while index < order.count, order[index].at <= cutoff {
            seen.remove(order[index].id)
            index += 1
        }
        if index > 0 { order.removeFirst(index) }
    }
}

// MARK: - Version skew

/// The security-relevant contract implemented by a running daemon. Keep the
/// protocol independent of CFBundleVersion: development and repaired builds
/// may share a number while an already-running helper still has older code.
struct HelperStatus: Codable, Equatable, Sendable {
    static let currentProtocolVersion = 1
    static let reviewedSelectionCapability = "reviewed-selection-v1"

    let build: String
    let protocolVersion: Int
    let capabilities: Set<String>

    static func current(build: String) -> HelperStatus {
        HelperStatus(build: build,
                     protocolVersion: currentProtocolVersion,
                     capabilities: [reviewedSelectionCapability])
    }
}

/// Whether the app and the installed helper have a compatible contract.
enum HelperVersionSkew {
    enum Skew: Equatable, Sendable {
        case matched
        case mismatched
    }

    /// Exact equality, and an empty build on either side is a mismatch. There
    /// is no "close enough" here: the helper runs as root, and a version it
    /// can't name is a version nobody has reasoned about.
    static func evaluate(appBuild: String, helperBuild: String) -> Skew {
        guard !appBuild.isEmpty, !helperBuild.isEmpty, appBuild == helperBuild else { return .mismatched }
        return .matched
    }

    /// Build-only replies, missing selectors, malformed data, and unknown
    /// protocols all fail closed. Capabilities are additive within a protocol.
    static func evaluate(appBuild: String, statusData: Data?) -> Skew {
        guard let statusData,
              let status = try? JSONDecoder().decode(HelperStatus.self, from: statusData),
              status.protocolVersion == HelperStatus.currentProtocolVersion,
              status.capabilities.contains(HelperStatus.reviewedSelectionCapability)
        else { return .mismatched }
        return evaluate(appBuild: appBuild, helperBuild: status.build)
    }
}
