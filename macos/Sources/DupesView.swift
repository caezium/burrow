//
//  DupesView.swift
//  Burrow
//
//  The Duplicates tab — a conductor-tool surface that reads like the rest of the app:
//  Analyze's toolbar idiom (up arrow + breadcrumbs + icon buttons), the Clean review
//  checklist idiom (tri-state group cards + ticked item rows), and Clean's Trash flow
//  (alert -> FileManager.trashItem -> DoneBanner). Scanning runs `burrow dupes <dir>
//  --json` off the main thread through the pure DupesModel parser.
//
//  Acting, two ways — both explain-before-act:
//    * "Move to Trash · X" removes the TICKED copies (default: all but one per group,
//      keep-one guarded by DupesSelection) via the native Trash — recoverable, exactly
//      like Clean's trash mode.
//    * "Reclaim via clones…" keeps every path and converts whole-scan duplicates to APFS
//      clones (`burrow dupes dedupe`), confirmed with fclones' own dry-run plan.
//
//  Degrade: dev/CI builds without the vendor/burrow-cli submodule have no bundled
//  conductor — the pane explains instead of dead-ending.
//

import SwiftUI
import AppKit

struct DupesView: View {
    @StateObject private var model = DupesModel()
    @State private var trashResult: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            ZStack {
                if !BurrowEngine.isAvailable {
                    conductorMissing
                } else if model.scanning {
                    scanningProgress
                } else if let err = model.error {
                    errorState(err)
                } else if let report = model.report {
                    if report.groups.isEmpty { cleanState } else { results(report) }
                } else {
                    idleState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            if let result = trashResult {
                DoneBanner(accent: Tool.dupes.accent, title: NSLocalizedString("Moved to Trash", comment: ""), detail: result)
                    .padding(.horizontal, 18).padding(.bottom, 10)
                    .onTapGesture { trashResult = nil }
            }
        }
    }

    // MARK: Toolbar (Analyze's idiom: up + crumbs + info + icon buttons)

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.goUp() } label: {
                Image(systemName: "arrow.up").font(.system(size: Brand.scaled(11), weight: .semibold))
                    .foregroundStyle(model.canGoUp ? Brand.textSecondary : Brand.textTertiary.opacity(0.35))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!model.canGoUp)
            .help(NSLocalizedString("Scan the parent folder", comment: ""))

            if model.crumbs.isEmpty {
                Text(NSLocalizedString("Choose a folder to scan", comment: ""))
                    .font(Brand.mono(12)).foregroundStyle(Brand.textTertiary)
            }
            ForEach(Array(model.crumbs.enumerated()), id: \.offset) { idx, crumb in
                if idx > 0 {
                    Image(systemName: "chevron.right").font(.system(size: Brand.scaled(9), weight: .semibold))
                        .foregroundStyle(Brand.textTertiary)
                }
                Button { model.goToCrumb(idx) } label: {
                    Text(crumb.name)
                        .font(Brand.mono(12, idx == model.crumbs.count - 1 ? .semibold : .regular))
                        .foregroundStyle(idx == model.crumbs.count - 1 ? Brand.textPrimary : Brand.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let report = model.report {
                Text(summaryLine(report))
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            Button { pickFolder() } label: {
                Image(systemName: "folder").font(.system(size: Brand.scaled(11), weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(!BurrowEngine.isAvailable)
            .help(NSLocalizedString("Choose a folder…", comment: ""))
            Button { model.rescan() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: Brand.scaled(11), weight: .semibold))
                    .foregroundStyle(model.folder == nil ? Brand.textTertiary.opacity(0.35) : Brand.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(!BurrowEngine.isAvailable || model.folder == nil || model.scanning)
            .help(NSLocalizedString("Rescan", comment: ""))
        }
    }

    /// "N groups · X reclaimable" — the one number this pane exists for.
    private func summaryLine(_ report: DupesReport) -> String {
        String(format: NSLocalizedString("%d groups · %@ reclaimable", comment: ""),
               report.groups.count, Fmt.bytes(report.redundantBytes))
    }

    private func pickFolder() {
        ConductorScanStates.pickFolder(current: model.folder) { model.scan($0) }
    }

    // MARK: States

    private var conductorMissing: some View {
        ConductorScanStates.conductorMissing(NSLocalizedString("Duplicate scanning runs through the bundled `burrow` CLI. This build shipped without it — a dev build without the vendor/burrow-cli submodule. Release builds include it.", comment: ""))
    }

    private var idleState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.doc").font(.system(size: Brand.scaled(26))).foregroundStyle(Tool.dupes.accent)
            Text(NSLocalizedString("Find what you've stashed twice", comment: ""))
                .font(Brand.serif(17, .medium)).foregroundStyle(Brand.textPrimary)
            Text(NSLocalizedString("Choose a folder and Burrow finds byte-identical copies, preselects all but one of each, and moves the extras to the Trash — or reclaims their space with APFS clones, deleting nothing.", comment: ""))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            Button { pickFolder() } label: {
                Text(NSLocalizedString("Choose a folder…", comment: ""))
                    .font(Brand.sans(12, .semibold)).foregroundStyle(Brand.onInverse)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Brand.inverse))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private var scanningProgress: some View {
        VStack(spacing: 12) {
            Text(NSLocalizedString("Hunting duplicates", comment: ""))
                .font(Brand.serif(18, .medium)).foregroundStyle(Brand.textPrimary)
            HStack(spacing: 8) {
                PulsingDot(color: Tool.dupes.accent)
                Text((model.folder.map { ($0 as NSString).abbreviatingWithTildeInPath }) ?? "")
                    .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 380)
            }
            Text(NSLocalizedString("Hashing candidate files — large folders can take a minute.", comment: ""))
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("Scanning for duplicates", comment: ""))
    }

    private func errorState(_ message: String) -> some View {
        ConductorScanStates.errorState(message)
    }

    private var cleanState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: Brand.scaled(24))).foregroundStyle(Tool.dupes.accent)
            Text(NSLocalizedString("No duplicates here", comment: ""))
                .font(Brand.serif(17, .medium)).foregroundStyle(Brand.textPrimary)
            Text(NSLocalizedString("Every file in this folder is one of a kind.", comment: ""))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
        }
    }

    // MARK: Results (Clean review's checklist idiom)

    private func results(_ report: DupesReport) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString("Review duplicates", comment: ""))
                        .font(Brand.serif(22, .medium)).foregroundStyle(Brand.textPrimary)
                    Text(NSLocalizedString("Ticked copies go to the Trash; every group always keeps at least one. Untick anything you'd rather hold on to.", comment: ""))
                        .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(report.groups.prefix(200)) { group in
                        groupCard(group, report: report)
                    }
                    if report.groups.count > 200 {
                        Text(String(format: NSLocalizedString("…and %d smaller groups. Narrow the folder to see them.", comment: ""),
                                    report.groups.count - 200))
                            .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                            .padding(.vertical, 8)
                    }
                    Color.clear.frame(height: 56) // room for the floating footer pill
                }
                .padding(.horizontal, 18).padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
        }
        .overlay(alignment: .bottom) { footer(report) }
    }

    private func groupCard(_ group: DupeGroup, report: DupesReport) -> some View {
        let isOpen = model.openGroups.contains(group.id)
        return VStack(spacing: 0) {
            Button {
                if isOpen { model.openGroups.remove(group.id) } else { model.openGroups.insert(group.id) }
            } label: {
                HStack(spacing: 10) {
                    triStateBox(model.selection.groupState(group)) { model.toggleGroup(group) }
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: Brand.scaled(13))).foregroundStyle(Tool.dupes.accent)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(String(format: NSLocalizedString("%@ × %d copies", comment: ""),
                                        Fmt.bytes(group.fileLen), group.files.count))
                                .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                            Text(verbatim: "\(model.selection.selectedCount(in: group))/\(group.files.count) selected")
                                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                        }
                        Text((group.files.first.map { ($0 as NSString).abbreviatingWithTildeInPath }) ?? "")
                            .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(verbatim: "\(Fmt.bytes(group.fileLen * Int64(model.selection.selectedCount(in: group)))) / \(Fmt.bytes(group.redundantBytes))")
                        .font(Brand.mono(11, .medium)).foregroundStyle(Tool.dupes.accent)
                    Image(systemName: "chevron.right")
                        .font(.system(size: Brand.scaled(10), weight: .semibold)).foregroundStyle(Brand.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: NSLocalizedString("%@ times %d copies, %d selected", comment: ""),
                                       Fmt.bytes(group.fileLen), group.files.count,
                                       model.selection.selectedCount(in: group)))
            .accessibilityAddTraits(.isButton)

            if isOpen {
                Rectangle().fill(Brand.hairline).frame(height: 1).padding(.horizontal, 13)
                VStack(spacing: 0) {
                    ForEach(group.files, id: \.self) { path in
                        copyRow(path, group: group, report: report)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private func triStateBox(_ state: DupesSelection.GroupState, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(state == .none ? Brand.chipFill : Tool.dupes.accent.opacity(0.9))
                    .frame(width: 17, height: 17)
                switch state {
                case .all:
                    Image(systemName: "checkmark").font(.system(size: Brand.scaled(9), weight: .bold)).foregroundStyle(.black)
                case .mixed:
                    Image(systemName: "minus").font(.system(size: Brand.scaled(9), weight: .bold)).foregroundStyle(.black)
                case .none:
                    EmptyView()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Brand.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("Toggle group", comment: ""))
    }

    private func copyRow(_ path: String, group: DupeGroup, report: DupesReport) -> some View {
        let ticked = model.selection.isTicked(path)
        let kept = model.selection.isKeptCopy(path, in: group)
        return HStack(spacing: 10) {
            Button { model.toggle(path) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(ticked ? Tool.dupes.accent.opacity(0.9) : Brand.chipFill)
                        .frame(width: 15, height: 15)
                    if ticked {
                        Image(systemName: "checkmark").font(.system(size: Brand.scaled(8), weight: .bold)).foregroundStyle(.black)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Brand.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel((path as NSString).lastPathComponent)
            .disabled(model.deduping)
            .accessibilityValue(ticked ? NSLocalizedString("selected", comment: "") : NSLocalizedString("not selected", comment: ""))

            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                    .font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if kept {
                Text(NSLocalizedString("kept", comment: ""))
                    .font(Brand.mono(9, .medium)).foregroundStyle(Tool.dupes.accent)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Tool.dupes.accent.opacity(0.16)))
                    .help(NSLocalizedString("Every group keeps at least one copy — tick a different one to keep instead.", comment: ""))
            }
            Text(Fmt.bytes(group.fileLen)).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .frame(minWidth: 56, alignment: .trailing)
            Button { AnalyzeIcons.reveal(path) } label: {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: Brand.scaled(12))).foregroundStyle(Brand.textTertiary)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Reveal in Finder", comment: ""))
        }
        .padding(.horizontal, 13).padding(.vertical, 5)
    }

    // MARK: Footer (Clean review's confirm-pill idiom)

    private func footer(_ report: DupesReport) -> some View {
        HStack(spacing: 10) {
            Button { startDedupe(report) } label: {
                Text(NSLocalizedString("Reclaim via clones…", comment: ""))
                    .font(Brand.sans(12, .semibold)).foregroundStyle(Brand.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Brand.chipFill))
                    .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(model.deduping || model.scanning)
            .help(NSLocalizedString("Keep every file; duplicates share storage via APFS clones. Nothing is deleted.", comment: ""))

            Button { trashTicked(report) } label: {
                Text(String(format: NSLocalizedString("Move to Trash · %@", comment: "confirm pill"),
                            Fmt.bytes(model.selection.selectedBytes(in: report))))
                    .font(Brand.sans(12, .semibold))
                    .foregroundStyle(model.selection.isEmpty ? Brand.textTertiary : Brand.onInverse)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Capsule().fill(model.selection.isEmpty ? Brand.chipFill : Brand.inverse))
            }
            .buttonStyle(.plain)
            .disabled(model.selection.isEmpty || model.deduping || model.scanning || model.trashSnapshot == nil)
            if model.deduping { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 18).padding(.bottom, 12)
    }

    /// Clean's exact trash flow: alert with count+size -> FileManager.trashItem per path
    /// (recoverable) -> HUD + banner -> rescan for the post-move truth.
    private func trashTicked(_ report: DupesReport) {
        guard !model.deduping, !model.scanning else { return }
        let paths = model.selection.selectedPaths(in: report)
        guard !paths.isEmpty else { return }
        let plan: DupeTrashSnapshot.Plan
        do {
            guard let snapshot = model.trashSnapshot else { throw CleanupSnapshot.SnapshotError.staleOrChanged }
            plan = try snapshot.plan(selectedPaths: paths)
        } catch {
            model.error = NSLocalizedString("The duplicate files changed. Scan again before moving copies to Trash.", comment: "")
            return
        }
        let total = model.selection.selectedBytes(in: report)
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Move %d duplicate copies (%@) to the Trash?", comment: ""),
                                   paths.count, Fmt.bytes(total))
        alert.informativeText = NSLocalizedString("Every group keeps at least one copy. The moved copies stay recoverable until you empty the Trash.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Move to Trash", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModalQuiet() == .alertFirstButtonReturn else { return }
        guard model.beginTrashAction() else { return }

        let opID = UUID()
        OperationCenter.shared.begin(opID, label: NSLocalizedString("Moving duplicates to Trash", comment: ""),
                                     notifiesOnEnd: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = plan.moveToTrash()
            let moved = result.moved, failed = result.failed
            DispatchQueue.main.async {
                model.deduping = false
                OperationCenter.shared.end(opID, success: failed == 0,
                                           detail: String(format: NSLocalizedString("%d moved · %d failed", comment: ""), moved, failed))
                trashResult = failed == 0
                    ? String(format: NSLocalizedString("Moved %d copies (%@) to the Trash.", comment: ""), moved, Fmt.bytes(total))
                    : String(format: NSLocalizedString("Moved %d copies; %d were locked or already gone.", comment: ""), moved, failed)
                model.rescan()
            }
        }
    }

    /// The non-destructive path: conductor dedupe preview -> confirm with fclones' own
    /// `cp -c` plan -> --apply -> rescan.
    private func startDedupe(_ report: DupesReport) {
        model.dedupePreview { preview in
            guard let preview else { return } // model.error carries the reason
            let alert = NSAlert()
            if preview.skipped || preview.plan.isEmpty {
                alert.messageText = NSLocalizedString("Nothing to deduplicate", comment: "")
                alert.informativeText = NSLocalizedString("Every duplicate here is protected, cross-volume, or already a clone — there is nothing safe to reclaim.", comment: "")
                alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                alert.runModalQuiet()
                return
            }
            alert.messageText = String(
                format: NSLocalizedString("Reclaim %@ by clone-deduplicating?", comment: ""),
                Fmt.bytes(report.redundantBytes))
            let shown = preview.plan.prefix(6).map { "  " + $0 }.joined(separator: "\n")
            let more = preview.plan.count > 6
                ? "\n" + String(format: NSLocalizedString("  …and %d more", comment: ""), preview.plan.count - 6)
                : ""
            alert.informativeText = String(
                format: NSLocalizedString("%d groups become APFS clones — every file keeps its path and contents; the copies share storage. Nothing is deleted, and edits to one copy no longer affect the others.\n\nPlanned clones:\n%@%@", comment: ""),
                preview.groups, shown, more)
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("Reclaim", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            guard alert.runModalQuiet() == .alertFirstButtonReturn else { return }
            model.dedupeApply()
        }
    }
}

// MARK: - Model

@MainActor
final class DupesModel: ConductorScanModel<DupesReport> {
    @Published var deduping = false
    /// The Clean-review checklist state over the current report.
    @Published var selection = DupesSelection(report: DupesReport(groups: [], redundantBytes: 0))
    /// Which group cards are expanded (collapsed by default, like Clean's categories).
    @Published var openGroups: Set<String> = []
    @Published private(set) var trashSnapshot: DupeTrashSnapshot?

    /// `dupes` needs a subcommand (`group|dedupe|remove|link`) — a bare path errors with "needs a
    /// subcommand" (`burrow-engine`'s `cli.rs::dupes`). `group` is the read-only report this scan
    /// wants; see `dupes.golden.provenance.txt`, captured with argv `dupes group <path>`. The
    /// envelope's `data` is fclones' group report, decoded by the pure DupesReport.parse.
    init() {
        super.init(command: Command(
            name: "dupes",
            arguments: { folder in ["group", folder ?? ""] },
            timeout: 300,
            parse: { DupesReport.parse($0) },
            beginLabel: { name in String(format: NSLocalizedString("Finding duplicates in %@", comment: ""), name ?? "") },
            successDetail: { r in String(format: NSLocalizedString("%d groups · %@", comment: ""),
                                         r.groups.count, Fmt.bytes(r.redundantBytes)) },
            unreadable: NSLocalizedString("burrow dupes returned an unreadable report", comment: "")))
    }

    override func didLoad(_ report: DupesReport) {
        selection = DupesSelection(report: report)
        trashSnapshot = nil
        let reviewedFolder = folder
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = reviewedFolder.flatMap {
                try? DupeTrashSnapshot(report: report, root: URL(fileURLWithPath: $0))
            }
            Task { @MainActor in
                guard !self.deduping, self.folder == reviewedFolder, self.report == report else { return }
                self.trashSnapshot = snapshot
            }
        }
        openGroups = Set(report.groups.prefix(3).map(\.id)) // biggest wins start open
    }

    // MARK: Selection passthroughs (keep the view dumb)

    func toggle(_ path: String) {
        guard !deduping, let report else { return }
        selection.toggle(path, in: report)
    }

    func toggleGroup(_ group: DupeGroup) {
        guard !deduping else { return }
        selection.toggleGroup(group)
    }

    func beginTrashAction() -> Bool {
        guard !deduping, !scanning, trashSnapshot != nil else { return false }
        deduping = true
        trashSnapshot = nil
        return true
    }

    // MARK: Dedupe (the non-destructive act)

    /// Run the engine's dedupe PREVIEW (`dupes dedupe <dir>`, no --apply) and hand the
    /// parsed plan to the caller on the main actor. nil = the preview itself failed
    /// (self.error carries the reason).
    func dedupePreview(_ completion: @escaping @MainActor (DedupePreview?) -> Void) {
        guard let folder, !deduping else { return }
        deduping = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let preview: DedupePreview?
            var failure: String?
            do {
                let envelope = try BurrowEngine.capture("dupes", ["dedupe", folder], timeout: 300)
                preview = envelope.data.flatMap { DedupePreview.parse($0) }
                if preview == nil {
                    failure = NSLocalizedString("burrow returned an unreadable dedupe preview", comment: "")
                }
            } catch {
                preview = nil
                failure = error.localizedDescription
            }
            Task { @MainActor in
                self.deduping = false
                if let failure { self.error = failure }
                completion(preview)
            }
        }
    }

    /// The confirmed action: `dupes dedupe <dir> --apply` — APFS clones, nothing deleted.
    /// On success the folder is re-scanned so the pane shows the post-reclaim truth.
    func dedupeApply() {
        guard let folder, !deduping else { return }
        deduping = true
        error = nil
        let name = (folder as NSString).lastPathComponent
        let actId = UUID()
        OperationCenter.shared.begin(actId, label: String(format: NSLocalizedString("Deduplicating %@", comment: ""), name),
                                     notifiesOnEnd: true)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                _ = try BurrowEngine.capture("dupes", ["dedupe", folder, "--apply"], timeout: 600)
            } catch {
                failure = error.localizedDescription
            }
            Task { @MainActor in
                self.deduping = false
                if let failure {
                    self.error = failure
                    OperationCenter.shared.end(actId, success: false,
                                               detail: NSLocalizedString("dedupe failed", comment: ""))
                    return
                }
                OperationCenter.shared.end(actId, success: true,
                                           detail: NSLocalizedString("duplicates now share storage", comment: ""))
                self.rescan()
            }
        }
    }
}
