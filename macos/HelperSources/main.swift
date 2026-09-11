//
//  main.swift
//  BurrowHelper
//
//  Entry point for the root daemon. launchd starts this on demand when
//  something connects to the Mach service; it publishes its own authorization
//  right, pins who may connect, serves requests, and exits when idle.
//
//  Nothing here does privileged work. The gauntlet every request runs is in
//  HelperService.swift.
//

import Foundation
import ServiceManagement

enum HelperMain {

    /// How long the daemon lingers with no work before exiting.
    ///
    /// A root process should not be resident for longer than it is useful.
    /// launchd restarts it on the next connection at no cost to the user, so
    /// the only thing a long idle life buys is a larger window in which a root
    /// process exists to be attacked.
    static let idleTimeout: TimeInterval = 120

    static func start() -> Never {
        // Traced stage by stage. When this daemon last misbehaved there was no
        // way to tell "it never started" from "it started and the
        // authorization failed", which cost more time than the bug did.
        helperTrace("startup: entered main")

        // The team that signed US. Learned at runtime, so no team ID,
        // certificate, or developer name is ever hardcoded in the repository,
        // and the check survives certificate renewal.
        let teamID = HelperCodeRequirement.selfTeamIdentifier()
        let requirement = HelperCodeRequirement.string(bundleID: HelperNames.clientBundleID,
                                                       teamID: teamID)
        helperTrace("startup: signing team \(teamID == nil ? "absent (ad-hoc)" : "present")")

        if teamID == nil {
            // Ad-hoc: local development only. Say so loudly — a release build
            // always has a team, and the release gate refuses to ship without
            // one, so seeing this in the wild means something is wrong.
            helperTrace("running ad-hoc signed: caller pinning is identifier-only (development build)")
        }

        // Publish the right's definition. Rewritten every launch on purpose:
        // the compiled-in definition is the source of truth, so a stale or
        // tampered policy entry from an earlier install cannot weaken a newer
        // helper. Failure is not fatal — the right still evaluates, just with
        // the system's default wording.
        helperTrace("startup: publishing authorization right")
        if !HelperAuthorization.installRightDefinition() {
            helperTrace("startup: could NOT publish the authorization right definition")
        }

        let service = HelperService(teamID: teamID)
        let delegate = HelperListenerDelegate(service: service)
        let listener = NSXPCListener(machServiceName: HelperNames.machService)

        // Gate 1, enforced by the system before our delegate ever runs. The
        // supported alternative to hand-rolling an audit-token check — see
        // HelperCodeRequirement for why the PID-based version of this is a
        // textbook vulnerability.
        listener.setConnectionCodeSigningRequirement(requirement)

        listener.delegate = delegate
        listener.resume()

        helperTrace("helper \(HelperService.build) listening on \(HelperNames.machService)")

        // Idle exit. Checked on a timer rather than tied to connection
        // teardown so a client that opens a connection and then goes silent
        // cannot pin a root process open indefinitely.
        var idleSince = Date()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler {
            guard service.isIdle else { idleSince = Date(); return }
            guard Date().timeIntervalSince(idleSince) >= idleTimeout else { return }
            // The decision and the exit are one step: `commitIdleExit`
            // closes the admission gate under the lock `execute` admits
            // with, so a request cannot slip in between the two. A request
            // that beat it means the daemon is not idle after all.
            guard service.commitIdleExit() else { idleSince = Date(); return }
            helperTrace("idle timeout reached; exiting")
            exit(0)
        }
        timer.resume()

        RunLoop.main.run()
        // RunLoop.main.run() does not return; this keeps the Never signature
        // honest for the compiler.
        exit(0)
    }
}

HelperMain.start()
