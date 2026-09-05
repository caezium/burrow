//
//  SweepView.swift
//  Burrow
//
//  Purge (dev build artifacts) and Installers (leftover .dmg/.pkg) on the same run-a-tool
//  lifecycle Clean uses: a dry run that streams what would go, a confirmation naming the
//  count and size, then the real run streaming what went. `purge --stream` speaks clean's
//  NDJSON vocabulary (`would_remove` … `done`; `removed`/`failed`/`protected` … `done`), so
//  `BurrowStreamReport` reduces both; `installer` has no `--stream` in the engine and runs
//  buffered, its one envelope line reduced by the same reducer.
//
//  This replaces the PTY checklist (`MoInteractiveView`) that drove mo's interactive TUI. The
//  bundled engine is never interactive — it answers JSON — so that view had nothing to talk
//  to. What is lost with it is per-project ticking: the engine has no way to purge a subset,
//  so the preview IS the list and the real run removes all of it (to the Trash, the engine's
//  default, so a mistake is recoverable).
//

import SwiftUI
import AppKit

struct SweepConfig {
    let tool: Tool
    let command: String
    let scanLabel: String
    let runLabel: String
    let scanningText: String
    let emptyText: String
    let confirmTitle: (_ count: Int, _ bytes: Int64) -> String
    let confirmNote: String

    static let purge = SweepConfig(
        tool: .purge, command: "purge",
        scanLabel: NSLocalizedString("Scanning projects", comment: ""),
        runLabel: NSLocalizedString("Purging build artifacts", comment: ""),
        scanningText: NSLocalizedString("Scanning projects for build artifacts…", comment: ""),
        emptyText: NSLocalizedString("No project build artifacts found.", comment: ""),
        confirmTitle: { count, bytes in
            String(format: NSLocalizedString("Move %d build artifacts (%@) to the Trash?", comment: "purge confirm"),
                   count, Fmt.bytes(bytes))
        },
        confirmNote: NSLocalizedString("node_modules, build and target folders regenerate on the next build. They stay recoverable until you empty the Trash.", comment: ""))

    static let installer = SweepConfig(
        tool: .installer, command: "installer",
        scanLabel: NSLocalizedString("Scanning for installers", comment: ""),
        runLabel: NSLocalizedString("Removing installers", comment: ""),
        scanningText: NSLocalizedString("Scanning for leftover installers…", comment: ""),
        emptyText: NSLocalizedString("No leftover installers found.", comment: ""),
        confirmTitle: { count, bytes in
            String(format: NSLocalizedString("Move %d installer files (%@) to the Trash?", comment: "installer confirm"),
                   count, Fmt.bytes(bytes))
        },
        confirmNote: NSLocalizedString("Disk images and packages you already installed from. They stay recoverable until you empty the Trash.", comment: ""))
}

/// The two operations, as data — pure so the argv is pinned by a test.
enum SweepOperations {
    /// The dry run: mo-style `<cmd> --dry-run`, which OperationFlow translates to the engine's
    /// preview (+ `--stream` for purge). Live bytes count up from `would_remove` lines.
    static func preview(_ cfg: SweepConfig) -> ToolOperation<CleanDryReport> {
        let title = cfg.tool.title
        return ToolOperation(label: cfg.scanLabel,
                             arguments: [cfg.command, "--dry-run"],
                             reduce: { lines in
                                 let (groups, summary) = BurrowStreamReport.reduce(lines, title: title)
                                 let bytes = lines.reduce(Int64(0)) { $0 + BurrowStreamReport.streamedBytes($1) }
                                 return CleanDryReport(groups: groups, summary: summary, liveBytes: bytes, list: nil)
                             },
                             hudLine: { BurrowStreamReport.hudLine($0) })
    }

    /// The real run: mo-style `<cmd>` → the engine's `--apply` (+ `--stream` for purge). Not
    /// elevated — project trees and Downloads are the user's own — and to the Trash by default.
    static func apply(_ cfg: SweepConfig) -> ToolOperation<TaskRunReport> {
        let title = cfg.tool.title
        return ToolOperation(label: cfg.runLabel,
                             arguments: [cfg.command],
                             reduce: { BurrowStreamReport.reduce($0, title: title) },
                             hudLine: { BurrowStreamReport.hudLine($0) },
                             notifyOnEnd: true,
                             finalDetail: { $0.summary?.completionLine ?? "" })
    }
}

struct SweepView: View {
    private let cfg: SweepConfig
    @StateObject private var dryFlow = OperationFlow<CleanDryReport>()
    @StateObject private var realFlow = OperationFlow<TaskRunReport>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ cfg: SweepConfig) { self.cfg = cfg }

    var body: some View {
        Group {
            switch realFlow.state {
            case .running, .finished:
                runScreen
            default:
                switch dryFlow.state {
                case .idle:
                    ToolHero(tool: cfg.tool, title: cfg.tool.title, subtitle: cfg.tool.tagline) {
                        PillButton(title: "Scan") { startScan() }
                    }
                case .gated(let pending):
                    FullDiskAccessRequired(
                        accent: cfg.tool.accent,
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
                    resultsScreen
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scan

    private func startScan() {
        realFlow.reset()
        dryFlow.reset()
        dryFlow.start(SweepOperations.preview(cfg))
    }

    private var foundBytes: Int64 {
        if let space = dryFlow.report?.summary?.space, !space.isEmpty {
            let parsed = Fmt.parseSize(space)
            if parsed > 0 { return parsed }
        }
        return dryFlow.report?.liveBytes ?? 0
    }

    private var foundItems: [TaskItem] { dryFlow.report?.groups.flatMap(\.items) ?? [] }

    private func scanHero(final: Bool) -> some View {
        let bytes = foundBytes
        return VStack(spacing: 18) {
            Spacer()
            HeroOrb(accent: cfg.tool.accent, size: 110)
            VStack(spacing: 10) {
                Group {
                    if reduceMotion {
                        Text(Fmt.bytes(bytes))
                    } else {
                        Text(Fmt.bytes(bytes))
                            .contentTransition(.numericText(value: Double(bytes)))
                            .animation(.easeOut(duration: 0.25), value: bytes)
                    }
                }
                .font(Brand.mono(40, .bold))
                .foregroundStyle(Brand.textPrimary)
                .accessibilityLabel(String(format: NSLocalizedString("Scanning, %@ found so far", comment: ""), Fmt.bytes(bytes)))
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(cfg.tool.accent)
                    Text(cfg.scanningText).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    Button { dryFlow.cancel() } label: {
                        Text("Stop").font(Brand.mono(11)).foregroundStyle(Brand.red)
                    }.buttonStyle(.plain)
                }
            }
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results

    private var resultsScreen: some View {
        let items = foundItems
        let nothing = items.isEmpty
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(resultsStatusText).font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
                Spacer()
                Button { startScan() } label: {
                    Label("Rescan", systemImage: "arrow.clockwise").font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }.buttonStyle(.plain)
                Button { dryFlow.reset() } label: {
                    Label("Back", systemImage: "chevron.left").font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            if nothing {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.seal").font(.system(size: 24)).foregroundStyle(cfg.tool.accent)
                    Text(cfg.emptyText).font(Brand.sans(13)).foregroundStyle(Brand.textSecondary)
                    Spacer(); Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TaskReportView(groups: dryFlow.report?.groups ?? [], accent: cfg.tool.accent)
            }
            if case .finished = dryFlow.state {
                ViewLogDisclosure(log: dryFlow.rawLog)
            }
        }
        .overlay(alignment: .bottom) {
            if !nothing, case .finished(.done(exit: 0)) = dryFlow.state {
                HStack {
                    Text(String(format: NSLocalizedString("%d found · %@", comment: "sweep footer"), items.count, Fmt.bytes(foundBytes)))
                        .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    Spacer()
                    Button { confirmRemoval(count: items.count, bytes: foundBytes) } label: {
                        Text(String(format: NSLocalizedString("Move to Trash · %@", comment: "confirm pill"), Fmt.bytes(foundBytes)))
                            .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.onInverse)
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(Capsule().fill(Brand.inverse))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(
                    LinearGradient(colors: [Brand.nearBlack.opacity(0), Brand.nearBlack.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false))
            }
        }
    }

    private var resultsStatusText: String {
        switch dryFlow.state {
        case .finished(.done(exit: 0)): return NSLocalizedString("Scan complete.", comment: "")
        case .finished(.done(let code)):
            return String(format: NSLocalizedString("Scan exited with status %d.", comment: ""), code)
        case .finished(.cancelled): return NSLocalizedString("Stopped before the end — results are partial.", comment: "")
        case .finished(.failed(let m)): return String(format: NSLocalizedString("Failed: %@", comment: ""), m)
        default: return ""
        }
    }

    private func confirmRemoval(count: Int, bytes: Int64) {
        let alert = NSAlert()
        alert.messageText = cfg.confirmTitle(count, bytes)
        alert.informativeText = cfg.confirmNote
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Move to Trash", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModalQuiet() == .alertFirstButtonReturn else { return }
        realFlow.reset()
        realFlow.start(SweepOperations.apply(cfg))
    }

    // MARK: - Real run

    private var runScreen: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if case .running = realFlow.state {
                    ProgressView().controlSize(.small).tint(cfg.tool.accent)
                }
                Text(runStatusText).font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
                Spacer()
                if realFlow.canCancel {
                    Button { realFlow.cancel() } label: {
                        Label("Stop", systemImage: "stop.fill").font(Brand.mono(11)).foregroundStyle(Brand.red)
                    }.buttonStyle(.plain)
                }
                if case .finished = realFlow.state {
                    Button { realFlow.reset(); dryFlow.reset() } label: {
                        Label("Back", systemImage: "chevron.left").font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            if case .finished(.done(exit: 0)) = realFlow.state {
                DoneBanner(accent: cfg.tool.accent, title: "Removed",
                           detail: realFlow.report?.summary?.completionLine)
            }
            TaskReportView(groups: realFlow.report?.groups ?? [], accent: cfg.tool.accent)
            if case .finished = realFlow.state {
                ViewLogDisclosure(log: realFlow.rawLog)
            }
        }
    }

    private var runStatusText: String {
        switch realFlow.state {
        case .running: return NSLocalizedString("Removing… don't quit.", comment: "")
        case .finished(.done(exit: 0)): return NSLocalizedString("Done — leftovers removed.", comment: "")
        case .finished(.done(let code)):
            return String(format: NSLocalizedString("Finished with errors (exit %d). The run log lists each one.", comment: ""), code)
        case .finished(.cancelled): return NSLocalizedString("Stopped.", comment: "")
        case .finished(.failed(let m)): return String(format: NSLocalizedString("Failed: %@", comment: ""), m)
        case .idle, .gated: return ""
        }
    }
}
