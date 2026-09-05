//
//  CleanView.swift
//  Burrow
//
//  The Clean tab, four states (design 1.4 + 2.1):
//
//    idle      — the minimal hero. "Scan your Mac" (dry-run) or the
//                direct "Clean Now" path.
//    scanning/ — the same hero with a huge live total that counts up as
//    result      the dry-run streams; the animation IS the scan
//                progress. "Review results" pushes the review.
//    review    — CleanReviewView: per-item ticks, locked-app badges,
//                the honest confirm pill.
//    run       — the existing elevated `mo clean` with streaming report.
//                Unticked paths ride a whitelist session (fenced block,
//                restored after; startup sweep covers crashes). Trash
//                mode recycles the reviewed, ticked paths instead.
//
//  The dry-run keeps its FDA gate — that's the one decision point where
//  "Scan with admin" is a real choice. The ambient FDA state lives in
//  RootView's AccessBanner.
//

import SwiftUI
import AppKit

/// Dry-run report: the themed groups + summary TaskReport always built,
/// plus the live byte total the count-up hero renders.
struct CleanDryReport {
    let groups: [TaskGroup]
    let summary: TaskSummary?
    let liveBytes: Int64
    let list: CleanList?

    static func reduce(_ lines: [String], bundledEngine: Bool,
                       legacyList: () -> CleanList? = CleanList.loadLive) -> Self {
        let (groups, summary) = BurrowStreamReport.reduce(lines)
        let bytes = lines.reduce(Int64(0)) { $0 + BurrowStreamReport.streamedBytes($1) }
        return Self(groups: groups, summary: summary, liveBytes: bytes,
                    list: bundledEngine ? CleanList.fromEngineOutput(lines) : legacyList())
    }
}

struct CleanView: View {
    @StateObject private var dryFlow = OperationFlow<CleanDryReport>()
    @StateObject private var realFlow = OperationFlow<TaskRunReport>()

    /// Which screen is on top when no run is active.
    private enum Screen { case hero, review }
    @State private var screen: Screen = .hero
    /// Parsed clean-list.txt + locked map, loaded when entering review.
    @State private var reviewList: CleanList?
    @State private var reviewSnapshot: CleanupSnapshot?
    @State private var reviewLocked: [String: CleanSelection.LockReason] = [:]
    /// When the dry-run finished — the review goes stale after a few
    /// minutes (TOCTOU: caches appear between preview and run).
    @State private var scanFinishedAt: Date?
    /// Trash-mode result line, shown as a done banner.
    @State private var trashResult: String?
    @State private var fdaGranted = Privacy.hasFullDiskAccess()
    /// All-time bytes cleaned (PRD §Clean), loaded off-main for the done screen.
    @State private var lifetimeCleaned: Int64 = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch realFlow.state {
            case .running, .finished:
                realRunScreen
            default:
                switch dryFlow.state {
                case .gated(let pending):
                    FullDiskAccessRequired(
                        accent: Tool.clean.accent,
                        onRecheck: {
                            dryFlow.start(pending)
                            if case .gated = dryFlow.state { return false }
                            return true
                        },
                        onRunAnyway: { dryFlow.start(pending.elevated()) },
                        onCancel: { dryFlow.reset() })
                case .running:
                    scanHero(final: false)
                case .finished:
                    if screen == .review, let list = reviewList {
                        CleanReviewView(list: list, locked: reviewLocked,
                                        onConfirm: { confirmClean($0) },
                                        onExit: { screen = .hero })
                    } else {
                        scanHero(final: true)
                    }
                case .idle:
                    idleHero
                }
            }
        }
        .onAppear {
            fdaGranted = Privacy.hasFullDiskAccess()
            CleanupExecutionPlan.sweepStalePlanFiles()
            // Skip Intro (Settings ▸ General): the dry-run preview is
            // read-only, so it can start the moment the tab opens.
            if Store.skipIntro, case .idle = dryFlow.state, case .idle = realFlow.state {
                startDry()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fdaGranted = Privacy.hasFullDiskAccess()
        }
        .onChange(of: dryRunFinished) { _, finished in
            if finished { scanFinishedAt = Date() }
        }
        .overlay(alignment: .bottom) {
            if let result = trashResult {
                DoneBanner(accent: Tool.clean.accent, title: "Moved to Trash", detail: result)
                    .padding(.horizontal, 18).padding(.bottom, 10)
                    .onTapGesture { trashResult = nil }
            }
        }
    }

    /// Done-screen detail: this run's freed line + the all-time total.
    private var cleanedDetail: String? {
        let thisRun = realFlow.report?.summary.map(\.completionLine)
        let life = lifetimeCleaned > 0
            ? String(format: NSLocalizedString("Lifetime: %@ cleaned", comment: ""), Fmt.bytes(lifetimeCleaned))
            : nil
        let parts = [thisRun, life].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private func loadLifetime() async {
        lifetimeCleaned = await Task.detached(priority: .utility) {
            CleanWatch.totals(from: MoleHistory.load()).cleanedBytes
        }.value
    }

    private var dryRunFinished: Bool {
        if case .finished = dryFlow.state { return true }
        return false
    }

    // MARK: - Idle hero

    private var idleHero: some View {
        ToolHero(tool: .clean, title: "Clean", subtitle: Tool.clean.tagline) {
            PillButton(title: "Scan your Mac") { startDry() }
            // The direct path this screen has always been documented to
            // offer. Scanning first is the better habit, so it keeps the
            // filled pill — but making review the ONLY way through means
            // anyone who already trusts the engine has to sit through a
            // scan they don't want.
            // Goes straight to the clean — no confirmation sheet. The
            // elevation prompt is still ahead of any deletion, so this is
            // one deliberate press away from a system auth gate rather
            // than a bare one-click delete.
            PillButton(title: "Clean now", filled: false) { startDirectClean() }
                .help(NSLocalizedString("Runs the engine's own cache selection without a per-item review.", comment: ""))
        }
    }

    private func startDirectClean() {
        trashResult = nil
        screen = .hero
        realFlow.reset()
        // No cleanup plan: the engine chooses its own targets, so this routes
        // to the plain `clean` operation rather than the reviewed one.
        //
        // `.moleStream` rather than a hand-built ToolOperation reducing with `parseTaskReport`:
        // this is the one direct path that still spawns the ENGINE, and the engine streams
        // NDJSON — the human-text marker grammar matches none of its shapes, so the run would
        // clean for real and then report nothing. `BurrowStreamReport.reduce` falls back to
        // `parseTaskReport` when the output isn't envelope-shaped, so an external mo still
        // reads correctly. The plan-driven runs elsewhere in this file keep `parseTaskReport`
        // because they spawn `/usr/bin/find`, which prints nothing either way.
        realFlow.start(.moleStream(["clean"], elevated: true,
                                   label: NSLocalizedString("Cleaning caches", comment: ""),
                                   notifyOnEnd: true))
    }

    // MARK: - Scanning / result hero (2.1)

    /// Scanning and result share one layout — the number mounts at 0 and
    /// ticks up live, so the count-up IS the progress indicator.
    private func scanHero(final: Bool) -> some View {
        let bytes = displayBytes(final: final)
        return VStack(spacing: 18) {
            Spacer()
            HeroOrb(accent: Tool.clean.accent, size: 110)
            VStack(spacing: 10) {
                Group {
                    if reduceMotion {
                        Text(heroNumber(bytes, final: final))
                    } else {
                        Text(heroNumber(bytes, final: final))
                            .contentTransition(.numericText(value: Double(bytes)))
                            .animation(.easeOut(duration: 0.25), value: bytes)
                    }
                }
                .font(Brand.mono(40, .bold))
                .foregroundStyle(Brand.textPrimary)
                .accessibilityLabel(final
                    ? String(format: NSLocalizedString("%@ found", comment: ""), Fmt.bytes(bytes))
                    : String(format: NSLocalizedString("Scanning, %@ found so far", comment: ""), Fmt.bytes(bytes)))

                if !final {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Tool.clean.accent)
                        Text("Scanning your Mac…").font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                        Button { dryFlow.cancel() } label: {
                            Text("Stop").font(Brand.mono(11)).foregroundStyle(Brand.red)
                        }.buttonStyle(.plain)
                    }
                } else if case .finished(.cancelled) = dryFlow.state {
                    Text("Stopped before the end — results are partial.")
                        .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }

                if !fdaGranted {
                    limitedScanChip
                }
            }
            if final {
                HStack(spacing: 12) {
                    if reviewAvailable {
                        PillButton(title: "Review results") { enterReview() }
                    }
                    PillButton(title: "Rescan", filled: false) { startDry() }
                    Button { dryFlow.reset(); screen = .hero } label: {
                        Text("Back").font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                    }.buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Limited scan active" chip with the demoted gate's explainer.
    private var limitedScanChip: some View {
        LimitedScanChip(onRescanElevated: {
            dryFlow.reset()
            dryFlow.start(dryOperation().elevated())
        })
    }

    private var reviewAvailable: Bool {
        if case .finished(.done(exit: 0)) = dryFlow.state {
            return dryFlow.report?.list?.categories.isEmpty == false
        }
        return false
    }

    private func heroNumber(_ bytes: Int64, final: Bool) -> String {
        final ? String(format: NSLocalizedString("%@ found", comment: "clean result hero"), Fmt.bytes(bytes))
              : Fmt.bytes(bytes)
    }

    private func displayBytes(final: Bool) -> Int64 {
        // The engine's own total is authoritative once the summary line
        // lands; the accumulated figure carries the live count-up.
        if final, let space = dryFlow.report?.summary?.space, !space.isEmpty {
            let parsed = CleanList.parseSize(space)
            if parsed > 0 { return parsed }
        }
        return dryFlow.report?.liveBytes ?? 0
    }

    // MARK: - Review

    private func enterReview() {
        guard let list = dryFlow.report?.list, !list.categories.isEmpty else { return }
        do {
            let user = try InvokingUserIdentity.current()
            reviewSnapshot = try CleanupSnapshot.capture(
                list: list, approvedRootURLs: CleanupSnapshot.approvedRoots(for: user))
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("This preview can't be cleaned safely", comment: "")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModalQuiet()
            return
        }
        reviewList = list
        reviewLocked = CleanLock.lockedPaths(in: list, running: CleanLock.runningApps())
        // Entries the snapshot refused are shown locked, with the reason, and
        // cannot be ticked. They used to take the whole preview down with
        // them: one unrepresentable entry meant no snapshot, no Clean button,
        // and an alert that blamed the preview as a whole.
        for entry in reviewSnapshot?.skipped ?? [] {
            reviewLocked[entry.path] = .notCleanable(reason: entry.reason)
        }
        screen = .review
    }

    /// Confirm from the review pill. Stale previews (TOCTOU window —
    /// caches that appeared after the scan would be cleaned unreviewed)
    /// force a rescan instead of a run.
    private func confirmClean(_ selection: CleanSelection) {
        guard let snapshot = reviewSnapshot else { return }
        if let finished = scanFinishedAt, Date().timeIntervalSince(finished) > Self.reviewFreshSeconds {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("This preview is stale", comment: "")
            alert.informativeText = NSLocalizedString("The scan is more than a few minutes old — caches that appeared since wouldn't have been reviewed. Rescan to get current numbers, then clean.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Rescan", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            if alert.runModalQuiet() == .alertFirstButtonReturn { screen = .hero; startDry() }
            return
        }
        if Store.cacheRemovalMode == .trash {
            trashTicked(selection, snapshot: snapshot)
        } else {
            runRealClean(selection, snapshot: snapshot)
        }
    }

    /// How long a preview stays trustworthy. Tight on purpose: the
    /// whitelist session excludes, it doesn't include, so anything new
    /// since the scan would be cleaned without review.
    static let reviewFreshSeconds: TimeInterval = 300

    // MARK: - The real run (permanent mode)

    private func runRealClean(_ selection: CleanSelection, snapshot: CleanupSnapshot) {
        // Refused entries can never reach a plan — `plan(selectedPaths:)`
        // rejects any path it didn't capture, which would fail the whole run.
        let refused = Set(snapshot.skipped.map(\.path))
        let paths = selection.list.categories.flatMap(\.items).map(\.path)
            .filter { selection.isTicked($0) && !refused.contains($0) }
        let plan: CleanupExecutionPlan
        do {
            plan = try snapshot.plan(selectedPaths: paths)
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("The reviewed files changed", comment: "")
            alert.informativeText = String(format: NSLocalizedString("Nothing was cleaned. Rescan before trying again. (%@)", comment: ""), error.localizedDescription)
            alert.alertStyle = .warning
            alert.runModalQuiet()
            return
        }
        // Plan-then-execute: the ticked paths go into a plan file and Confirm runs the engine
        // over exactly that file (`clean --apply --permanent --plan <file>`). No re-scan — the
        // engine removes only what was reviewed, each path re-checked through its rails — and
        // the stale-review timer above stays as the safety on top. The file is deleted by the
        // operation's `finally` whichever way the run ends. The engine reports every path back
        // (removed / failed / protected-with-reason), so the result screen is the engine's own
        // account of the run rather than the review's optimistic summary.
        let planFile: URL
        do {
            planFile = try plan.writePlanFile()
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("The cleanup plan couldn't be written", comment: "")
            alert.informativeText = String(format: NSLocalizedString("Nothing was cleaned. (%@)", comment: ""), error.localizedDescription)
            alert.alertStyle = .warning
            alert.runModalQuiet()
            return
        }
        screen = .hero
        // The result screen groups what the engine reports back under the review's own
        // categories, so a refused or failed path is shown where the user ticked it.
        var categoryOfPath: [String: String] = [:]
        for category in selection.list.categories {
            for item in category.items { categoryOfPath[item.path] = category.name }
        }
        let lookup = categoryOfPath
        realFlow.start(.reviewedClean(
            plan: plan, planFile: planFile,
            categoryOf: { lookup[$0] },
            label: NSLocalizedString("Cleaning reviewed caches", comment: "")))
    }

    // MARK: - Trash mode

    /// Settings ▸ Maintenance ▸ Cache removal: Trash. Burrow recycles
    /// exactly the reviewed, ticked paths — every one came from the
    /// engine's own dry-run enumeration. Trade-off (stated in Settings):
    /// space frees when Trash empties, and the run isn't in `mo history`
    /// — it lands in Burrow's Activity log instead.
    private func trashTicked(_ selection: CleanSelection, snapshot: CleanupSnapshot) {
        let refused = Set(snapshot.skipped.map(\.path))
        let paths = selection.list.categories.flatMap(\.items).map(\.path)
            .filter { selection.isTicked($0) && !refused.contains($0) }
        // Refuse anything that didn't come from the dry-run enumeration.
        assert(Set(paths).isSubset(of: Set(selection.list.categories.flatMap(\.items).map(\.path))))
        let total = selection.selectedBytes
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Move %d items (%@) to the Trash?", comment: ""), paths.count, Fmt.bytes(total))
        alert.informativeText = NSLocalizedString("They stay recoverable until you empty the Trash. Space frees when it empties; this run won't appear in `mo history`.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Move to Trash", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModalQuiet() == .alertFirstButtonReturn else { return }

        let plan: CleanupExecutionPlan
        do {
            plan = try snapshot.plan(selectedPaths: paths)
        } catch {
            let changed = NSAlert()
            changed.messageText = NSLocalizedString("The reviewed files changed", comment: "")
            changed.informativeText = NSLocalizedString("Nothing was moved. Rescan before trying again.", comment: "")
            changed.alertStyle = .warning
            changed.runModalQuiet()
            return
        }

        screen = .hero
        let opID = UUID()
        OperationCenter.shared.begin(opID, label: NSLocalizedString("Moving caches to Trash", comment: ""),
                                     notifiesOnEnd: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CleanupExecutor.moveToTrash(plan)
            let moved = result.moved, failed = result.failed
            DispatchQueue.main.async {
                OperationCenter.shared.end(opID, success: failed == 0,
                                           detail: String(format: NSLocalizedString("%d moved · %d failed", comment: ""), moved, failed))
                trashResult = failed == 0
                    ? String(format: NSLocalizedString("Moved %d items (%@) to the Trash.", comment: ""), moved, Fmt.bytes(total))
                    : String(format: NSLocalizedString("Moved %d items; %d were locked or already gone.", comment: ""), moved, failed)
                dryFlow.reset()
            }
        }
    }

    // MARK: - Real-run screen (status + receipt, the pre-1.4 layout)

    private var realRunScreen: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if case .running = realFlow.state {
                    ProgressView().controlSize(.small).tint(Tool.clean.accent)
                }
                Text(realStatusText).font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
                Spacer()
                if case .finished = realFlow.state {
                    Button {
                        realFlow.reset(); dryFlow.reset(); screen = .hero
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            if case .finished(.done(exit: 0)) = realFlow.state {
                DoneBanner(accent: Tool.clean.accent, title: "Cleaned", detail: cleanedDetail)
                    .task { await loadLifetime() }
            }
            TaskReportView(groups: realFlow.report?.groups ?? [], accent: Tool.clean.accent)
            if case .finished = realFlow.state {
                ViewLogDisclosure(log: realFlow.rawLog)
            }
        }
    }
    // (Session restore lives with the run watcher in runRealClean — a
    // view-attached onChange would miss runs that finish after the user
    // navigates away.)

    private var realStatusText: String {
        switch realFlow.state {
        case .running: return NSLocalizedString("Cleaning… don't quit.", comment: "")
        case .finished(.done(exit: 0)): return NSLocalizedString("Done — caches cleared.", comment: "")
        case .finished(.done(let code)):
            return String(format: NSLocalizedString("Failed: cleanup exited with status %d.", comment: ""), code)
        case .finished(.cancelled): return NSLocalizedString("Stopped.", comment: "")
        case .finished(.failed(let m)): return String(format: NSLocalizedString("Failed: %@", comment: ""), m)
        case .idle, .gated: return ""
        }
    }

    // (The post-run detail line lives on TaskSummary.completionLine —
    // shared with the completion notification.)

    // MARK: - Dry-run plumbing

    private func dryOperation() -> ToolOperation<CleanDryReport> {
        let bundledEngine = BurrowEngine.isAvailable
        return ToolOperation(label: NSLocalizedString("Scanning caches", comment: ""),
                      arguments: ["clean", "--dry-run"],
                      gate: .fullDiskAccess(adminBypass: true),
                      // The bundled engine streams NDJSON here too (this scan goes through the
                      // same conductor `--stream` path as a real clean/optimize) — reduce with
                      // BurrowStreamReport, not the old human-text parseTaskReport, or every scan
                      // reads back "0 B found" with no summary and no forward path. See BurrowStreamReport.
                       reduce: { lines in
                           CleanDryReport.reduce(lines, bundledEngine: bundledEngine)
                      },
                      hudLine: { BurrowStreamReport.hudLine($0) },
                      // The scan is the step people walk away from — it can run
                      // for minutes on a full disk and, unlike the clean, it ends
                      // by just sitting there with a number. Same opt-in the real
                      // run uses, so it respects the Settings toggle and stays
                      // silent for anyone who turned it off.
                      notifyOnEnd: true,
                      // Without this the notification body is whatever the last
                      // streamed HUD line happened to be — which for a task
                      // report is usually the "=====" separator, so the notice
                      // arrived as a row of equals signs. Say what was found.
                      finalDetail: { report in
                          let items = report.groups.reduce(0) { $0 + $1.items.count }
                          return items == 0
                              ? NSLocalizedString("Nothing to clean.", comment: "")
                              : String(format: NSLocalizedString("%@ found across %d items.", comment: ""),
                                       Fmt.bytes(report.liveBytes), items)
                      })
    }

    private func startDry() {
        trashResult = nil
        reviewList = nil
        reviewSnapshot = nil
        screen = .hero
        dryFlow.reset()
        dryFlow.start(dryOperation())
    }
}

/// "🛡 Limited scan active" info chip (shown when FDA is off) — the
/// demoted gate's explainer lives behind it.
private struct LimitedScanChip: View {
    var onRescanElevated: () -> Void
    @State private var showExplainer = false

    var body: some View {
        Button { showExplainer = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: Brand.scaled(10)))
                Text("Limited scan active · App Support and container caches are skipped")
                    .font(Brand.mono(10))
                Image(systemName: "chevron.right").font(.system(size: Brand.scaled(8), weight: .semibold))
            }
            .foregroundStyle(Brand.amber)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(Brand.amber.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Brand.amber.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("Limited scan active. App Support and container caches are skipped. Open for options.", comment: ""))
        .popover(isPresented: $showExplainer, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Why limited?").font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                Text("Without Full Disk Access, macOS hides most app and container caches from Burrow. Grant it once for full scans — or rerun this scan with administrator rights (one password).")
                    .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 290)
                HStack(spacing: 12) {
                    Button(NSLocalizedString("Open Settings", comment: "")) { Privacy.openFullDiskAccessSettings() }
                        .buttonStyle(.plain).font(Brand.sans(11, .semibold)).foregroundStyle(Brand.green)
                    Button(NSLocalizedString("Scan with admin", comment: "")) {
                        showExplainer = false
                        onRescanElevated()
                    }
                    .buttonStyle(.plain).font(Brand.sans(11, .semibold)).foregroundStyle(Brand.amber)
                }
            }
            .padding(14)
        }
    }
}
