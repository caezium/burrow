//
//  UpdatesView.swift
//  Burrow
//
//  The Software → Updates pane (design 2.3): one unified list across
//  update mechanisms with per-source badges — Sparkle, App Store,
//  Electron, Homebrew — split into "Updates available" / "Up to date" /
//  "Not checkable". Source detection is local bundle inspection (free);
//  version checks contact Apple / vendor appcast servers, so they run
//  ONLY when the user clicks Check — never silently (the network story
//  in SECURITY.md depends on this).
//
//  Supported Sparkle apps update through Sparkle's signed installer;
//  generic electron-builder feeds stage a SHA-512 checked, code-signature
//  matched replacement; Homebrew runs serially in-process; App Store and
//  unsupported vendor mechanisms are explicit handoffs and never claim an
//  install Burrow did not perform.
//

import SwiftUI
import AppKit

struct OutdatedItem: Identifiable, Equatable {
    let id: String
    let name: String
    let installed: String
    let latest: String
    let kind: String   // "formula" | "cask"
}

/// What one `brew outdated` pass produced: the rows, or why there are none.
/// A failed or timed-out brew used to come back as an empty list, which the
/// pane showed as "nothing to update" (#424); now the reason travels with it.
struct BrewOutdated: Equatable {
    enum Problem: Equatable {
        case notInstalled
        case failed(String)
    }
    var items: [OutdatedItem] = []
    var problem: Problem?
    static let empty = BrewOutdated()
}

/// The two halves of the pane. They have different network stories — Mac
/// apps are checked only on click, Homebrew's local index is free — so each
/// gets its own header with its own single action instead of one shared
/// button sitting above a mixed list.
enum UpdatesSource: Hashable {
    case apps, homebrew
}

/// One GUI app in the unified list.
struct AppUpdateItem: Identifiable {
    let id: String
    let name: String
    let path: String
    let bundleID: String
    let installedVersion: String
    let sizeStr: String
    let source: UpdateSources.Source
    var latestVersion: String?
    var pageURL: URL?
    var releaseNotesURL: URL?
    var lastUsed: Date?
    /// App Store: the macOS this update requires (from the iTunes lookup).
    var minimumOS: String?

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        guard UpdateCheck.isNewer(latest, than: installedVersion) else { return false }
        // Hide an App Store update that needs a newer macOS than we run (PRD §Software).
        let v = Foundation.ProcessInfo.processInfo.operatingSystemVersion
        let running = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return OSUpdateGate.isInstallable(minimumOS: minimumOS, running: running)
    }
}

/// One source-check response. Keeping this value independent from the view
/// model makes forced responses deterministic in tests and keeps retries from
/// smuggling partial state into the main actor.
struct AppUpdateCheckResult: Equatable, Sendable {
    let id: String
    var latestVersion: String?
    var pageURL: URL?
    var releaseNotesURL: URL?
    var minimumOS: String?
    var electronDescriptor: ElectronUpdateDescriptor?
    var phase: UpdatePhase

    static func failure(id: String, failure: UpdateFailure) -> Self {
        Self(
            id: id,
            latestVersion: nil,
            pageURL: nil,
            releaseNotesURL: nil,
            minimumOS: nil,
            electronDescriptor: nil,
            phase: .failed(failure)
        )
    }

    static func available(
        id: String,
        version: String,
        electronDescriptor: ElectronUpdateDescriptor? = nil
    ) -> Self {
        Self(
            id: id,
            latestVersion: version,
            pageURL: nil,
            releaseNotesURL: nil,
            minimumOS: nil,
            electronDescriptor: electronDescriptor,
            phase: .available
        )
    }

    static func completed(id: String, version: String? = nil) -> Self {
        Self(
            id: id,
            latestVersion: version,
            pageURL: nil,
            releaseNotesURL: nil,
            minimumOS: nil,
            electronDescriptor: nil,
            phase: .completed
        )
    }
}

struct UpdatesView: View {
    @ObservedObject var model: UpdatesModel
    var apps: [InstalledApp] = []

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.vertical, 11)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            switch model.source {
            case .apps: appsList
            case .homebrew: brewList
            }
        }
        .onAppear { model.prepare(apps: apps); model.autoSurface() }
        .onChange(of: apps) { _, latest in model.prepare(apps: latest) }
    }

    // MARK: Header — source picker on the left, that source's actions on the right

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                sourceTab("Mac apps", .apps, count: model.checked && !model.availableItems.isEmpty ? model.availableItems.count : nil)
                sourceTab("Homebrew", .homebrew, count: model.brewItems.isEmpty ? nil : model.brewItems.count)
            }
            .padding(2)
            .background(Capsule().fill(Brand.hairline.opacity(0.5)))
            Spacer()
            switch model.source {
            case .apps: appsActions
            case .homebrew: brewActions
            }
        }
    }

    private func sourceTab(_ title: String, _ value: UpdatesSource, count: Int?) -> some View {
        let on = model.source == value
        return Button { model.source = value } label: {
            HStack(spacing: 5) {
                Text(NSLocalizedString(title, comment: "")).font(Brand.mono(11, on ? .semibold : .regular))
                if let count {
                    Text(verbatim: "\(count)").font(Brand.mono(10, .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(on ? Brand.onInverse.opacity(0.18) : Tool.apps.accent.opacity(0.14)))
                }
            }
            .foregroundStyle(on ? Brand.onInverse : Brand.textSecondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background { if on { Capsule().fill(Brand.inverse) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { String(format: NSLocalizedString($0 == 1 ? "%d update" : "%d updates", comment: ""), $0) }
                            .map { "\(NSLocalizedString(title, comment: "")) — \($0)" } ?? NSLocalizedString(title, comment: ""))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Mac apps: the explicit network check, then the batch once results exist.
    @ViewBuilder
    private var appsActions: some View {
        if model.checking {
            progressLabel(NSLocalizedString("Checking…", comment: ""))
        } else if !model.checked {
            Text("Checking app versions contacts Apple and vendor servers.")
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
        }
        PillButton(title: model.checked ? "Check again" : "Check for updates", filled: !model.checked) {
            model.checkNow()
        }
        .keyboardShortcut("r", modifiers: .command)
        if model.updateAllRunning, model.updateAllSource == .apps {
            batchControls
        } else if model.checked, !model.availableItems.isEmpty {
            PillButton(title: "Update all", filled: false) { model.updateAllApps() }
        }
    }

    /// Homebrew: rows come from the local index for free; Refresh is the
    /// network step (`brew update`), and the batch is available as soon as
    /// there is anything to upgrade.
    @ViewBuilder
    private var brewActions: some View {
        if model.brewLoading {
            progressLabel(NSLocalizedString(model.brewRefreshing ? "Refreshing…" : "Checking Homebrew…", comment: ""))
        } else if model.brewProblem == nil {
            Text("Listed from Homebrew's local index — Refresh contacts Homebrew's update feeds.")
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
        }
        if model.brewProblem != .notInstalled {
            PillButton(title: "Refresh", filled: false) { model.refreshBrew() }
                .keyboardShortcut("r", modifiers: .command)
        }
        if model.updateAllRunning, model.updateAllSource == .homebrew {
            batchControls
        } else if !model.brewItems.isEmpty {
            PillButton(title: "Update all", filled: !model.brewLoading) { model.upgradeAllBrews() }
        }
    }

    private var batchControls: some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(model.updateAllCompleted)/\(model.updateAllTotal)")
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                .accessibilityLabel(String(
                    format: NSLocalizedString("%d of %d update steps processed", comment: ""),
                    model.updateAllCompleted,
                    model.updateAllTotal
                ))
            PillButton(title: model.cancelUpdateAllAfterCurrent
                        ? "Stopping after current…" : "Stop after current",
                       filled: false) {
                model.cancelUpdateAll()
            }
            .disabled(model.cancelUpdateAllAfterCurrent)
        }
    }

    private func progressLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
        }
    }

    // MARK: Lists

    @ViewBuilder
    private var appsList: some View {
        if model.checking && model.appItems.isEmpty {
            center { ProgressView("Checking update sources…").controlSize(.large).tint(Tool.apps.accent).font(Brand.mono(11)) }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let error = model.error {
                        noteRow(error, color: Brand.amber)
                    }
                    if model.checked, model.availableItems.isEmpty {
                        upToDateBanner
                    }
                    if !model.availableItems.isEmpty {
                        sectionHeader(NSLocalizedString("Updates available", comment: ""), count: model.availableItems.count)
                        ForEach(model.availableItems) { appRow($0) }
                    }
                    if model.checked, !model.upToDateItems.isEmpty {
                        sectionHeader(NSLocalizedString("Up to date", comment: ""), count: model.upToDateItems.count)
                        ForEach(model.upToDateItems) { appRow($0) }
                    }
                    if !model.checked {
                        sectionHeader(NSLocalizedString("Apps with an update mechanism", comment: ""), count: model.appItems.count)
                        ForEach(model.appItems) { appRow($0) }
                    }
                    if !model.uncheckableApps.isEmpty {
                        sectionHeader(NSLocalizedString("Not checkable", comment: ""), count: model.uncheckableApps.count)
                        Text("No App Store receipt, Sparkle feed, or known updater inside these bundles.")
                            .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                            .padding(.horizontal, 14).padding(.bottom, 4)
                        ForEach(model.uncheckableApps, id: \.id) { app in
                            plainRow(app)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .scrollIndicators(.visible)
        }
    }

    @ViewBuilder
    private var brewList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch model.brewProblem {
                case .notInstalled:
                    noteRow(NSLocalizedString("Homebrew (`brew`) not found on this Mac.", comment: ""), color: Brand.textTertiary)
                case let .failed(message):
                    noteRow(message, color: Brand.amber)
                case nil:
                    EmptyView()
                }
                if model.brewLoaded, model.brewItems.isEmpty, model.brewProblem == nil {
                    upToDateBanner
                }
                if !model.brewItems.isEmpty {
                    sectionHeader(NSLocalizedString("Updates available", comment: ""), count: model.brewItems.count)
                    ForEach(model.brewItems) { brewRow($0) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .scrollIndicators(.visible)
    }

    private var upToDateBanner: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: Brand.scaled(30))).foregroundStyle(Brand.green)
            Text("Everything's up to date").font(Brand.serif(18)).foregroundStyle(Brand.textPrimary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 36)
    }

    private func noteRow(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Brand.mono(10)).foregroundStyle(color)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .accessibilityLabel(text)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(Brand.mono(10, .bold)).tracking(0.7).foregroundStyle(Brand.textTertiary)
            Text(verbatim: "\(count)").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
    }

    // MARK: Rows

    private func appRow(_ item: AppUpdateItem) -> some View {
        let phase = model.phase(for: item.id)
        return HStack(spacing: 12) {
            Image(nsImage: SoftwareIcons.icon(item.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(item.name).font(Brand.sans(13, .medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                    Chip(text: item.source.badge, color: Brand.textSecondary)
                }
                metaLine(version: item.installedVersion, latest: item.latestVersion,
                         size: item.sizeStr, lastUsed: item.lastUsed)
                if phase != .idle, phase != .available, phase != .completed {
                    Text(phase.accessibilityValue)
                        .font(Brand.mono(9))
                        .foregroundStyle(phaseColor(phase))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if item.releaseNotesURL != nil || item.pageURL != nil {
                Button("Release notes") { model.openReleaseNotes(item) }
                    .buttonStyle(.plain)
                    .font(Brand.mono(9)).foregroundStyle(Brand.textSecondary)
            }
            appAction(item, phase: phase)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityValue(phase.accessibilityValue)
    }

    @ViewBuilder
    private func appAction(_ item: AppUpdateItem, phase: UpdatePhase) -> some View {
        switch phase {
        case .readyToInstall where item.source == .electron:
            updateButton("Install & Restart") { model.installReady(item) }
        case let .failed(failure) where failure.canRetry:
            updateButton("Retry") { model.retry(item) }
        case .failed(.unsupported(_)) where item.source == .electron:
            updateButton("Open updater", filled: false) { model.update(item) }
        case .handedOff(_) where item.source == .appStore:
            updateButton("Open App Store", filled: false) { model.update(item) }
        case .handedOff(_):
            updateButton("Open updater", filled: false) { model.update(item) }
        case .downloading(_) where item.source == .electron:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancel(item) }
                    .buttonStyle(.plain).font(Brand.mono(9)).foregroundStyle(Brand.textSecondary)
            }
        case .checking, .downloading(_), .verifying, .installing, .waitingForRestart:
            ProgressView().controlSize(.small).frame(width: 64)
        default:
            if item.updateAvailable {
                updateButton("Update") { model.update(item) }
            }
        }
    }

    private func updateButton(
        _ title: String,
        filled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(NSLocalizedString(title, comment: "")).font(Brand.sans(11, .semibold))
                .foregroundStyle(filled ? Color.white : Tool.apps.accent)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(filled ? Tool.apps.accent : Tool.apps.accent.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func phaseColor(_ phase: UpdatePhase) -> Color {
        if case .failed = phase { return Brand.red }
        if case .handedOff = phase { return Brand.amber }
        return Tool.apps.accent
    }

    private func brewRow(_ item: OutdatedItem) -> some View {
        let phase = model.phase(for: item.id)
        return HStack(spacing: 12) {
            Image(systemName: item.kind == "cask" ? "macwindow" : "shippingbox")
                .font(.system(size: Brand.scaled(14))).foregroundStyle(Tool.apps.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(item.name).font(Brand.sans(13, .medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                    Chip(text: UpdateSources.Source.homebrew.badge, color: Brand.textSecondary)
                }
                if model.upgrading.contains(item.id), !model.brewPhrase.isEmpty {
                    Text(model.brewPhrase)
                        .font(Brand.mono(10)).foregroundStyle(Tool.apps.accent).lineLimit(1)
                } else {
                    Text(verbatim: "\(item.installed) → \(item.latest)")
                        .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                }
                if case let .failed(failure) = phase {
                    Text(failure.message).font(Brand.mono(9)).foregroundStyle(Brand.red).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if model.upgrading.contains(item.id) {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 64)
            } else {
                Button { model.upgrade(item) } label: {
                    Text("Update").font(Brand.sans(11, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Tool.apps.accent))
                }.buttonStyle(.plain).frame(width: 64)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityValue(phase.accessibilityValue)
    }

    private func plainRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: SoftwareIcons.icon(app.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(Brand.sans(13, .medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                Text(verbatim: "\(SoftwareIcons.version(app.path).map { "v\($0)" } ?? "—") · \(app.sizeStr)")
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    /// `version · size · active 7 months ago` — recency phrase amber when stale.
    private func metaLine(version: String, latest: String?, size: String, lastUsed: Date?) -> some View {
        let versionText = latest.map { l in
            UpdateCheck.isNewer(l, than: version) ? "v\(version) → v\(l)" : "v\(version)"
        } ?? "v\(version)"
        let recency = Self.recencyPhrase(lastUsed)
        let stale = Self.isStale(lastUsed)
        return HStack(spacing: 0) {
            Text(verbatim: "\(versionText) · \(size) · ")
                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            Text(recency)
                .font(Brand.mono(10)).foregroundStyle(stale ? Brand.amber : Brand.textTertiary)
        }
    }

    private static let recencyFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f
    }()
    static func recencyPhrase(_ date: Date?) -> String {
        guard let date else { return NSLocalizedString("never opened", comment: "") }
        let interval = Date().timeIntervalSince(date)
        if interval < 3600 { return NSLocalizedString("active now", comment: "") }
        return String(format: NSLocalizedString("opened %@", comment: "recency"),
                      Self.recencyFmt.localizedString(for: date, relativeTo: Date()))   // cached (#240)
    }

    static func isStale(_ date: Date?) -> Bool {
        guard let date else { return true }
        return Date().timeIntervalSince(date) > 30 * 86_400
    }

    private func center<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class UpdatesModel: ObservableObject {
    @Published var appItems: [AppUpdateItem] = []
    @Published var uncheckableApps: [InstalledApp] = []
    @Published var brewItems: [OutdatedItem] = []
    /// Which half of the pane is showing. Lives here rather than in the view
    /// so switching Software segments and back doesn't reset it.
    @Published var source: UpdatesSource = .apps
    @Published var checking = false
    @Published var checked = false
    @Published var error: String?
    @Published var upgrading: Set<String> = []
    @Published private(set) var phases: [String: UpdatePhase] = [:]
    @Published private(set) var updateAllRunning = false
    @Published private(set) var updateAllCompleted = 0
    @Published private(set) var updateAllTotal = 0
    /// Which source the running batch belongs to, so only that header shows
    /// its progress and stop control.
    @Published private(set) var updateAllSource: UpdatesSource?
    /// Live brew step during an upgrade (H: brew-upgrade streaming).
    @Published var brewPhrase: String = ""
    /// Two flags rather than one enum because they answer different
    /// questions: `brewLoading` gates every brew action (no upgrade or second
    /// load under a list still being produced, whichever kind), while
    /// `brewRefreshing` only picks the spinner's copy — a local read finishes
    /// in a second, a refresh can sit on the network for minutes, and the
    /// user should know which one they are waiting on.
    @Published private(set) var brewLoading = false
    @Published private(set) var brewRefreshing = false
    /// A list has been produced at least once this session, so an empty one
    /// means "up to date" rather than "not looked yet".
    @Published private(set) var brewLoaded = false
    /// Why the Homebrew list is empty or stale, shown in place of the rows.
    @Published private(set) var brewProblem: BrewOutdated.Problem?
    private struct InventoryFingerprint: Equatable {
        let id: String
        let bundleID: String
        let path: String
        let source: String
        let detectionMetadata: String
    }

    private var preparedInventory: [InventoryFingerprint] = []
    private var prepareGeneration = 0
    private var checkGeneration = 0
    private let sourceDetector: (InstalledApp) -> UpdateSources.Source?
    private let sourceFingerprinter: (InstalledApp) -> String
    private let checkItem: (AppUpdateItem) async -> AppUpdateCheckResult
    private let retrySleep: (UInt64) async -> Void
    private let retryDelayNanoseconds: UInt64
    /// `refresh: true` runs `brew update` first (network); false reads the
    /// local index only.
    private let loadBrewOutdated: (Bool) async -> BrewOutdated
    /// Runs `brew upgrade <name>`, streaming progress lines; returns the exit code.
    private let upgradeBrew: (OutdatedItem, @escaping (String) -> Void) async -> Int32
    private let stageElectron: (String, ElectronUpdateDescriptor) async -> ElectronStageOutcome
    private let installElectron: @MainActor (StagedElectronUpdate) async -> ElectronInstallOutcome
    private let confirmRestart: @MainActor (AppUpdateItem) -> Bool
    private var brewSurfaced = false
    private var electronDescriptors: [String: ElectronUpdateDescriptor] = [:]
    private var stagedElectronUpdates: [String: StagedElectronUpdate] = [:]
    private var checkFailureIDs: Set<String> = []
    private struct TrackedSparkleSession {
        let generation: UInt64
        let session: ExternalSparkleUpdateSession
    }
    private var sparkleSessions: [String: TrackedSparkleSession] = [:]
    private var sparkleSessionGeneration: UInt64 = 0
    private struct TrackedAppTask {
        let generation: UInt64
        let task: Task<Void, Never>
    }
    private enum AppUpdateOwner {
        case row(UInt64)
        case updateAll(inventoryGeneration: Int)
    }
    private var appTasks: [String: TrackedAppTask] = [:]
    private var appTaskGeneration: UInt64 = 0
    private var updateAllTask: Task<Void, Never>?
    /// Published, and not private, because the header button reads it: the
    /// stop only takes effect after the in-flight item, so without a visible
    /// state change the click looked ignored for however long that took.
    @Published private(set) var cancelUpdateAllAfterCurrent = false

    init(
        detectSource: ((InstalledApp) -> UpdateSources.Source?)? = nil,
        sourceFingerprint: ((InstalledApp) -> String)? = nil,
        checkItem: ((AppUpdateItem) async -> AppUpdateCheckResult)? = nil,
        retrySleep: ((UInt64) async -> Void)? = nil,
        retryDelayNanoseconds: UInt64 = 750_000_000,
        loadBrewOutdated: ((Bool) async -> BrewOutdated)? = nil,
        upgradeBrew: ((OutdatedItem, @escaping (String) -> Void) async -> Int32)? = nil,
        stageElectron: ((String, ElectronUpdateDescriptor) async -> ElectronStageOutcome)? = nil,
        installElectron: (@MainActor (StagedElectronUpdate) async -> ElectronInstallOutcome)? = nil,
        confirmRestart: (@MainActor (AppUpdateItem) -> Bool)? = nil
    ) {
        sourceDetector = detectSource ?? { UpdateSources.detect(appPath: $0.path) }
        sourceFingerprinter = sourceFingerprint ?? { UpdateSources.detectionFingerprint(appPath: $0.path) }
        self.checkItem = checkItem ?? { await Self.check($0) }
        self.retrySleep = retrySleep ?? { delay in try? await Task.sleep(nanoseconds: delay) }
        self.retryDelayNanoseconds = min(retryDelayNanoseconds, 2_000_000_000)
        self.loadBrewOutdated = loadBrewOutdated ?? { await Self.loadBrewOutdated(refresh: $0) }
        self.upgradeBrew = upgradeBrew ?? { await Self.runBrewUpgrade($0, onLine: $1) }
        self.stageElectron = stageElectron ?? { await ElectronReplacementInstaller.stage(appPath: $0, descriptor: $1) }
        self.installElectron = installElectron ?? { await ElectronReplacementInstaller.install($0) }
        self.confirmRestart = confirmRestart ?? { Self.confirmRestartBeforeInstalling($0) }
    }

    var availableItems: [AppUpdateItem] { appItems.filter(\.updateAvailable) }
    var upToDateItems: [AppUpdateItem] {
        appItems.filter { !$0.updateAvailable && $0.latestVersion != nil }
    }

    func phase(for id: String) -> UpdatePhase { phases[id] ?? .idle }

    /// Local-only pass: detect each app's update mechanism from bundle
    /// shape. No network.
    func prepare(apps: [InstalledApp]) {
        let fingerprinter = sourceFingerprinter
        let inventory = apps.map { app in
            InventoryFingerprint(
                id: app.id,
                bundleID: app.bundleId,
                path: app.path,
                source: app.source,
                detectionMetadata: fingerprinter(app)
            )
        }.sorted {
            ($0.id, $0.path, $0.bundleID, $0.source) < ($1.id, $1.path, $1.bundleID, $1.source)
        }
        guard inventory != preparedInventory else { return }

        let previousByID = Dictionary(grouping: preparedInventory, by: \.id).compactMapValues(\.first)
        let nextByID = Dictionary(grouping: inventory, by: \.id).compactMapValues(\.first)
        let unchangedIDs = Set(nextByID.compactMap { id, fingerprint in
            previousByID[id] == fingerprint ? id : nil
        })
        let nextIDs = Set(nextByID.keys)
        let invalidatedIDs = Set(previousByID.keys).subtracting(unchangedIDs)
        preparedInventory = inventory
        prepareGeneration &+= 1
        checkGeneration &+= 1
        checking = false
        let generation = prepareGeneration
        let detector = sourceDetector
        let preserved = Dictionary(uniqueKeysWithValues: appItems
            .filter { unchangedIDs.contains($0.id) }
            .map { ($0.id, $0) })

        // Stop showing rows whose app disappeared or whose bundle/source
        // metadata changed while the new local inspection is in flight.
        appItems.removeAll { !unchangedIDs.contains($0.id) }
        uncheckableApps.removeAll { !unchangedIDs.contains($0.id) }
        phases = phases.filter { nextIDs.contains($0.key) && unchangedIDs.contains($0.key) }
        checkFailureIDs.formIntersection(unchangedIDs)
        electronDescriptors = electronDescriptors.filter { unchangedIDs.contains($0.key) }
        for id in invalidatedIDs {
            stagedElectronUpdates.removeValue(forKey: id)?.discard()
            cancelAppTask(for: id)
        }

        guard !apps.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var detected: [AppUpdateItem] = []
            var unknown: [InstalledApp] = []
            for app in apps {
                if let source = detector(app) {
                    var item = AppUpdateItem(
                        id: app.id, name: app.name, path: app.path, bundleId: app.bundleId, app: app, source: source)
                    if let old = preserved[app.id] {
                        item.latestVersion = old.latestVersion
                        item.pageURL = old.pageURL
                        item.releaseNotesURL = old.releaseNotesURL
                        item.minimumOS = old.minimumOS
                        item.lastUsed = old.lastUsed
                    }
                    detected.append(item)
                } else {
                    unknown.append(app)
                }
            }
            Task { @MainActor in
                guard let self, generation == self.prepareGeneration else { return }
                self.appItems = detected
                self.uncheckableApps = unknown
            }
        }
    }

    /// Surface Homebrew's list on tab open from its LOCAL index only
    /// (`HOMEBREW_NO_AUTO_UPDATE=1`): no network, so it's instant and works
    /// offline, and nothing leaves the Mac without a click — the same rule
    /// the app checks follow. Once per session; Refresh is the network step.
    func autoSurface() {
        guard !brewSurfaced else { return }
        brewSurfaced = true
        loadBrew(refresh: false)
    }

    /// The explicit Homebrew network step: `brew update` against the user's
    /// configured feeds (mirrors included, #424), then the local list again.
    func refreshBrew() {
        loadBrew(refresh: true)
    }

    private func loadBrew(refresh: Bool) {
        guard !brewLoading, upgrading.isEmpty, updateAllSource != .homebrew else { return }
        brewLoading = true
        brewRefreshing = refresh
        let loadBrewOutdated = self.loadBrewOutdated
        Task { @MainActor [weak self] in
            let result = await loadBrewOutdated(refresh)
            guard let self else { return }
            self.apply(result)
            self.brewLoading = false
            self.brewRefreshing = false
        }
    }

    private func apply(_ result: BrewOutdated) {
        brewItems = result.items
        brewProblem = result.problem
        brewLoaded = true
        // Rows that vanished from the list take their finished phases with
        // them; a row that is still outdated keeps its failure visible.
        let live = Set(result.items.map(\.id))
        phases = phases.filter { entry in
            let isBrew = entry.key.hasPrefix("formula:") || entry.key.hasPrefix("cask:")
            return !isBrew || live.contains(entry.key)
        }
    }

    /// The manual check: Sparkle appcasts + iTunes lookups, bounded
    /// concurrency. Homebrew has its own Refresh; this never touches it.
    func checkNow() {
        guard !checking, !updateAllRunning, appTasks.isEmpty, sparkleSessions.isEmpty, upgrading.isEmpty else { return }
        checking = true
        error = nil
        checkGeneration &+= 1
        let generation = checkGeneration
        let items = appItems
        let checkItem = self.checkItem
        let retrySleep = self.retrySleep
        let retryDelayNanoseconds = self.retryDelayNanoseconds
        for item in items {
            phases[item.id] = .checking
            checkFailureIDs.remove(item.id)
        }
        Task {
            var results: [AppUpdateCheckResult] = []
            await withTaskGroup(of: AppUpdateCheckResult.self) { group in
                var iterator = items.makeIterator()
                func enqueue(_ item: AppUpdateItem) {
                    group.addTask {
                        await Self.checkWithRetry(
                            item,
                            checkItem: checkItem,
                            retrySleep: retrySleep,
                            retryDelayNanoseconds: retryDelayNanoseconds
                        )
                    }
                }
                // Prime the window; the `for await` below keeps exactly one
                // task in flight per completion, so the count never needed
                // tracking after this point.
                for _ in 0..<6 {
                    guard let next = iterator.next() else { break }
                    enqueue(next)
                }
                for await result in group {
                    results.append(result)
                    if let next = iterator.next() { enqueue(next) }
                }
            }
            await MainActor.run {
                guard generation == self.checkGeneration else { return }
                let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
                self.appItems = self.appItems.map { live in
                    guard let result = byID[live.id] else { return live }
                    var copy = live
                    // A failed, cached, or otherwise older response never
                    // erases a release we already confirmed. Apply metadata as
                    // one versioned unit so an older Electron descriptor cannot
                    // be paired with the preserved newer version.
                    let acceptsResultMetadata: Bool
                    if let latest = result.latestVersion {
                        if let known = live.latestVersion,
                           UpdateCheck.isNewer(known, than: latest) {
                            acceptsResultMetadata = false
                        } else {
                            copy.latestVersion = latest
                            acceptsResultMetadata = true
                        }
                    } else {
                        acceptsResultMetadata = false
                    }
                    if acceptsResultMetadata {
                        if let pageURL = result.pageURL { copy.pageURL = pageURL }
                        if let releaseNotesURL = result.releaseNotesURL { copy.releaseNotesURL = releaseNotesURL }
                        if let minimumOS = result.minimumOS { copy.minimumOS = minimumOS }
                        if let descriptor = result.electronDescriptor {
                            self.electronDescriptors[live.id] = descriptor
                        }
                    }
                    if case .failed = result.phase {
                        self.checkFailureIDs.insert(live.id)
                        self.phases[live.id] = result.phase
                    } else {
                        self.checkFailureIDs.remove(live.id)
                        self.phases[live.id] = copy.updateAvailable ? .available : result.phase
                    }
                    return copy
                }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.checking = false
                self.checked = true
                let failures = results.filter { if case .failed = $0.phase { return true }; return false }.count
                self.error = failures == 0 ? nil : String(
                    format: NSLocalizedString("%d update checks failed. Known versions were preserved.", comment: ""),
                    failures
                )
            }
        }
        // Recency for the meta line, cheap filesystem dates.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var dates: [String: Date] = [:]
            for item in items {
                let url = URL(fileURLWithPath: item.path)
                if let vals = try? url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey]) {
                    dates[item.id] = vals.contentAccessDate ?? vals.contentModificationDate
                }
            }
            Task { @MainActor in
                guard let self, generation == self.checkGeneration else { return }
                self.appItems = self.appItems.map { item in
                    var copy = item
                    if let date = dates[item.id] { copy.lastUsed = date }
                    return copy
                }
            }
        }
    }

    private static func checkWithRetry(
        _ item: AppUpdateItem,
        checkItem: (AppUpdateItem) async -> AppUpdateCheckResult,
        retrySleep: (UInt64) async -> Void,
        retryDelayNanoseconds: UInt64
    ) async -> AppUpdateCheckResult {
        let first = await checkItem(item)
        guard case let .failed(failure) = first.phase, failure.canRetry else { return first }
        await retrySleep(retryDelayNanoseconds)
        guard !Task.isCancelled else { return first }
        return await checkItem(item)
    }

    private static func check(_ item: AppUpdateItem) async -> AppUpdateCheckResult {
        var result = AppUpdateCheckResult(
            id: item.id,
            latestVersion: nil,
            pageURL: nil,
            releaseNotesURL: nil,
            minimumOS: nil,
            electronDescriptor: nil,
            phase: .idle
        )
        switch item.source {
        case .sparkle:
            guard let feed = UpdateSources.feedURL(appPath: item.path) else {
                result.phase = .failed(.unsupported(NSLocalizedString("This app's Sparkle feed URL is invalid.", comment: "")))
                return result
            }
            switch await UpdateHTTP.fetch(feed) {
            case let .success(data):
                guard let latest = UpdateSources.parseAppcast(data) else {
                    result.phase = .failed(.decoding)
                    return result
                }
                result.latestVersion = latest
                result.phase = UpdateCheck.isNewer(latest, than: item.installedVersion) ? .available : .completed
            case let .failure(failure):
                result.phase = .failed(failure)
            }
        case .appStore:
            guard !item.bundleID.isEmpty else {
                result.phase = .failed(.decoding)
                return result
            }
            switch await UpdateHTTP.fetch(UpdateSources.itunesLookupURL(bundleID: item.bundleID)) {
            case let .success(data):
                guard let lookup = UpdateSources.parseITunesLookup(data) else {
                    result.phase = .failed(.decoding)
                    return result
                }
                result.latestVersion = lookup.version
                result.pageURL = lookup.pageURL
                result.minimumOS = lookup.minimumOsVersion
                let newer = UpdateCheck.isNewer(lookup.version, than: item.installedVersion)
                let installable = OSUpdateGate.isInstallable(
                    minimumOS: lookup.minimumOsVersion,
                    running: Self.runningOSVersion
                )
                result.phase = newer && installable ? .available : .completed
            case let .failure(failure):
                result.phase = .failed(failure)
            }
        case .electron:
            guard let feed = ElectronFeedConfiguration.read(appPath: item.path) else {
                result.phase = .failed(.unsupported(NSLocalizedString(
                    "This Electron updater uses a provider Burrow cannot safely replace. Use the app's own updater.",
                    comment: ""
                )))
                return result
            }
            switch await UpdateHTTP.fetch(feed.latestYAMLURL) {
            case let .success(data):
                guard let descriptor = ElectronUpdateDescriptor.parse(data, relativeTo: feed.latestYAMLURL) else {
                    result.phase = .failed(.decoding)
                    return result
                }
                result.electronDescriptor = descriptor
                result.latestVersion = descriptor.version
                result.phase = UpdateCheck.isNewer(descriptor.version, than: item.installedVersion) ? .available : .completed
            case let .failure(failure):
                result.phase = .failed(failure)
            }
        case .homebrew:
            result.phase = .completed
        }
        return result
    }

    private nonisolated static var runningOSVersion: String {
        let version = Foundation.ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    func update(_ item: AppUpdateItem) {
        guard !updateAllRunning,
              updateAllTask == nil,
              appTasks[item.id] == nil,
              !phase(for: item.id).isBusy else { return }
        let generation = nextAppTaskGeneration()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performUpdate(item, owner: .row(generation))
            self.finishAppTask(for: item.id, generation: generation)
        }
        appTasks[item.id] = TrackedAppTask(generation: generation, task: task)
    }

    func retry(_ item: AppUpdateItem) {
        if checkFailureIDs.contains(item.id) { checkNow() }
        else if item.updateAvailable { update(item) }
        else { checkNow() }
    }

    func installReady(_ item: AppUpdateItem) {
        guard !updateAllRunning, updateAllTask == nil else { return }
        let inventoryGeneration = prepareGeneration
        let capturedFingerprint = inventoryFingerprint(for: item)
        guard isLiveUpdateIdentity(item),
              let staged = stagedElectronUpdates[item.id],
              confirmRestart(item) else { return }
        // The restart alert runs a modal event loop. Any inventory/fingerprint
        // change while it is open invalidates this consent, even if the same ID
        // is detected and republished before the user returns.
        guard prepareGeneration == inventoryGeneration,
              inventoryFingerprint(for: item) == capturedFingerprint,
              isLiveUpdateIdentity(item) else { return }
        guard let currentStaged = stagedElectronUpdates[item.id],
              isSameStagedUpdate(currentStaged, staged) else {
            staged.discard()
            return
        }
        stagedElectronUpdates.removeValue(forKey: item.id)
        cancelAppTask(for: item.id)
        let generation = nextAppTaskGeneration()
        let task = Task { @MainActor [weak self] in
            guard let self else { staged.discard(); return }
            await self.install(staged, for: item.id, owner: .row(generation))
            self.finishAppTask(for: item.id, generation: generation)
        }
        appTasks[item.id] = TrackedAppTask(generation: generation, task: task)
    }

    private func nextAppTaskGeneration() -> UInt64 {
        appTaskGeneration &+= 1
        return appTaskGeneration
    }

    private func finishAppTask(for id: String, generation: UInt64) {
        guard appTasks[id]?.generation == generation else { return }
        appTasks.removeValue(forKey: id)
    }

    private func isCurrentAppUpdate(for id: String, owner: AppUpdateOwner) -> Bool {
        switch owner {
        case let .row(generation):
            return appTasks[id]?.generation == generation
                && appItems.contains(where: { $0.id == id })
        case let .updateAll(inventoryGeneration):
            return updateAllRunning && prepareGeneration == inventoryGeneration
                && appItems.contains(where: { $0.id == id })
        }
    }

    private func cancelAppTask(for id: String) {
        appTasks.removeValue(forKey: id)?.task.cancel()
    }

    private func inventoryFingerprint(for item: AppUpdateItem) -> InventoryFingerprint? {
        preparedInventory.first {
            $0.id == item.id && $0.bundleID == item.bundleID && $0.path == item.path
        }
    }

    private func isLiveUpdateIdentity(_ expected: AppUpdateItem) -> Bool {
        appItems.contains {
            $0.id == expected.id
                && $0.path == expected.path
                && $0.bundleID == expected.bundleID
                && $0.installedVersion == expected.installedVersion
                && $0.source == expected.source
        }
    }

    private func isSameStagedUpdate(
        _ lhs: StagedElectronUpdate,
        _ rhs: StagedElectronUpdate
    ) -> Bool {
        lhs.targetURL.standardizedFileURL == rhs.targetURL.standardizedFileURL
            && lhs.candidateURL.standardizedFileURL == rhs.candidateURL.standardizedFileURL
            && lhs.stagingDirectory.standardizedFileURL == rhs.stagingDirectory.standardizedFileURL
    }

    private func confirmedStagedUpdate(for item: AppUpdateItem) -> StagedElectronUpdate? {
        guard let staged = stagedElectronUpdates[item.id], confirmRestart(item) else { return nil }
        stagedElectronUpdates.removeValue(forKey: item.id)
        return staged
    }

    private static func confirmRestartBeforeInstalling(_ item: AppUpdateItem) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString("Install and restart %@?", comment: ""),
            item.name
        )
        alert.informativeText = String(
            format: NSLocalizedString(
                "Save any work in %@ before continuing. Burrow will ask the app to quit, replace its verified app bundle, and reopen it. Choosing Not Yet leaves the verified update ready to install.",
                comment: ""
            ),
            item.name
        )
        alert.addButton(withTitle: NSLocalizedString("Install & Restart", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Not Yet", comment: ""))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModalQuiet() == .alertFirstButtonReturn
    }

    func cancel(_ item: AppUpdateItem) {
        guard !updateAllRunning, updateAllTask == nil else { return }
        cancelAppTask(for: item.id)
        // Cancelling the task does NOT resume a checked continuation, so a
        // Sparkle session left registered here would keep every
        // `sparkleSessions.isEmpty` gate shut for the rest of the launch.
        // Its onFinish handler does the removal and the single resume.
        sparkleSessions[item.id]?.session.cancelSession()
        stagedElectronUpdates.removeValue(forKey: item.id)?.discard()
        phases[item.id] = .failed(.cancelled)
    }

    func openReleaseNotes(_ item: AppUpdateItem) {
        if let url = item.releaseNotesURL ?? item.pageURL { NSWorkspace.shared.open(url) }
    }

    private func performUpdate(_ item: AppUpdateItem, owner: AppUpdateOwner) async {
        guard isCurrentAppUpdate(for: item.id, owner: owner) else { return }
        switch item.source {
        case .sparkle:
            await runSparkle(item, owner: owner)
        case .electron:
            guard let descriptor = electronDescriptors[item.id] else {
                handOffToOwnUpdater(item)
                return
            }
            phases[item.id] = .downloading(progress: nil)
            let outcome = await stageElectron(item.path, descriptor)
            guard isCurrentAppUpdate(for: item.id, owner: owner) else {
                if case let .ready(staged) = outcome { staged.discard() }
                return
            }
            guard !Task.isCancelled else {
                if case let .ready(staged) = outcome { staged.discard() }
                phases[item.id] = .failed(.cancelled)
                return
            }
            switch outcome {
            case let .ready(staged):
                stagedElectronUpdates[item.id]?.discard()
                stagedElectronUpdates[item.id] = staged
                phases[item.id] = .readyToInstall
            case let .failure(failure):
                phases[item.id] = .failed(failure)
                if case .unsupported = failure { handOffToOwnUpdater(item) }
            }
        case .appStore:
            if let page = item.pageURL { NSWorkspace.shared.open(page) }
            else if let updates = URL(string: "macappstore://showUpdatesPage") { NSWorkspace.shared.open(updates) }
            phases[item.id] = .handedOff(NSLocalizedString("App Store", comment: ""))
        case .homebrew:
            break
        }
    }

    private func runSparkle(_ item: AppUpdateItem, owner: AppUpdateOwner) async {
        guard isCurrentAppUpdate(for: item.id, owner: owner) else { return }
        sparkleSessionGeneration &+= 1
        let sessionGeneration = sparkleSessionGeneration
        await withCheckedContinuation { continuation in
            guard let session = ExternalSparkleUpdateSession(
                appPath: item.path,
                onPhase: { [weak self] phase in
                    guard let self,
                          self.isCurrentSparkleSession(for: item.id, generation: sessionGeneration),
                          self.isCurrentAppUpdate(for: item.id, owner: owner),
                          self.appItems.contains(where: { $0.id == item.id }) else { return }
                    self.phases[item.id] = phase
                },
                onMetadata: { [weak self] version, releaseNotesURL in
                    guard let self,
                          self.isCurrentSparkleSession(for: item.id, generation: sessionGeneration),
                          self.isCurrentAppUpdate(for: item.id, owner: owner) else { return }
                    self.appItems = self.appItems.map { live in
                        guard live.id == item.id else { return live }
                        var copy = live
                        copy.latestVersion = version
                        copy.releaseNotesURL = releaseNotesURL
                        return copy
                    }
                },
                onFinish: { [weak self] in
                    self?.finishSparkleSession(for: item.id, generation: sessionGeneration)
                    continuation.resume()
                }
            ) else {
                phases[item.id] = .failed(.unsupported(NSLocalizedString(
                    "Sparkle could not open this app bundle. Use the app's own updater.",
                    comment: ""
                )))
                handOffToOwnUpdater(item)
                continuation.resume()
                return
            }
            sparkleSessions[item.id] = TrackedSparkleSession(
                generation: sessionGeneration,
                session: session
            )
            if session.begin() != nil {
                finishSparkleSession(for: item.id, generation: sessionGeneration)
                handOffToOwnUpdater(item)
            }
        }
    }

    private func isCurrentSparkleSession(for id: String, generation: UInt64) -> Bool {
        sparkleSessions[id]?.generation == generation
    }

    private func finishSparkleSession(for id: String, generation: UInt64) {
        guard isCurrentSparkleSession(for: id, generation: generation) else { return }
        sparkleSessions.removeValue(forKey: id)
    }

    private func install(
        _ staged: StagedElectronUpdate,
        for id: String,
        owner: AppUpdateOwner
    ) async {
        guard isCurrentAppUpdate(for: id, owner: owner) else {
            staged.discard()
            return
        }
        phases[id] = .installing
        let outcome = await installElectron(staged)
        guard isCurrentAppUpdate(for: id, owner: owner) else {
            staged.discard()
            return
        }
        switch outcome {
        case .installed:
            phases[id] = .completed
        case let .failure(failure):
            phases[id] = .failed(failure)
        }
    }

    private func handOffToOwnUpdater(_ item: AppUpdateItem) {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: item.path),
            configuration: NSWorkspace.OpenConfiguration()
        )
        phases[item.id] = .handedOff(NSLocalizedString("the app's updater", comment: ""))
    }

    // MARK: Homebrew (the existing flow)

    func upgrade(_ item: OutdatedItem) {
        guard upgrading.isEmpty, !updateAllRunning, !brewLoading else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performBrewUpdate(item)
            await self.reloadBrewAfterUpgrade()
        }
    }

    /// Processes every available Mac app serially. Electron replacements stop
    /// at the visible ready-to-install boundary; only an explicit Install &
    /// Restart confirmation may let the batch or row quit and replace it.
    /// Cancellation is deliberately a boundary between apps: interrupting a
    /// download halfway through is less safe than finishing the current item
    /// and stopping before the next one.
    func updateAllApps() {
        guard canStartBatch else { return }
        let apps = availableItems
        guard !apps.isEmpty else { return }
        let owner = AppUpdateOwner.updateAll(inventoryGeneration: prepareGeneration)
        beginBatch(source: .apps, total: apps.count)
        updateAllTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for item in apps {
                guard !self.cancelUpdateAllAfterCurrent,
                      self.isCurrentAppUpdate(for: item.id, owner: owner) else { break }
                await self.performUpdate(item, owner: owner)
                guard self.isCurrentAppUpdate(for: item.id, owner: owner) else { break }
                if let staged = self.confirmedStagedUpdate(for: item) {
                    await self.install(staged, for: item.id, owner: owner)
                    guard self.isCurrentAppUpdate(for: item.id, owner: owner) else { break }
                }
                self.updateAllCompleted += 1
            }
            self.endBatch()
        }
    }

    /// `brew upgrade` every listed formula and cask, one at a time — the same
    /// boundary rule as the app batch: a stop lands between transactions.
    func upgradeAllBrews() {
        guard canStartBatch, !brewLoading else { return }
        let brews = brewItems
        guard !brews.isEmpty else { return }
        beginBatch(source: .homebrew, total: brews.count)
        updateAllTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for item in brews {
                guard !self.cancelUpdateAllAfterCurrent else { break }
                await self.performBrewUpdate(item)
                self.updateAllCompleted += 1
            }
            self.endBatch()
            await self.reloadBrewAfterUpgrade()
        }
    }

    func cancelUpdateAll() {
        guard updateAllRunning else { return }
        cancelUpdateAllAfterCurrent = true
    }

    /// One batch at a time across both sources, and never over a row that
    /// is already mid-update.
    private var canStartBatch: Bool {
        !updateAllRunning && updateAllTask == nil && upgrading.isEmpty
            && appTasks.isEmpty && sparkleSessions.isEmpty
    }

    private func beginBatch(source: UpdatesSource, total: Int) {
        cancelUpdateAllAfterCurrent = false
        updateAllRunning = true
        updateAllSource = source
        updateAllCompleted = 0
        updateAllTotal = total
    }

    private func endBatch() {
        updateAllRunning = false
        updateAllSource = nil
        updateAllTask = nil
        cancelUpdateAllAfterCurrent = false
    }

    /// Re-read the local index after an upgrade so finished rows drop out
    /// and a failed one stays, with its message, for another try.
    private func reloadBrewAfterUpgrade() async {
        guard !brewLoading else { return }
        brewLoading = true
        let result = await loadBrewOutdated(false)
        apply(result)
        brewLoading = false
    }

    private func performBrewUpdate(_ item: OutdatedItem) async {
        guard BrewClient.isInstalled else {
            phases[item.id] = .failed(.unsupported(NSLocalizedString("Homebrew is no longer available.", comment: "")))
            return
        }
        guard upgrading.isEmpty else { return }
        upgrading.insert(item.id)
        phases[item.id] = .installing
        let code = await upgradeBrew(item) { line in
            guard let phrase = BrewProgress.phrase(line) else { return }
            Task { @MainActor [weak self] in self?.brewPhrase = phrase }
        }
        brewPhrase = ""
        upgrading.remove(item.id)
        phases[item.id] = code == 0
            ? .completed
            : .failed(.installation(String(
                format: NSLocalizedString("Homebrew exited with status %d. Retry after resolving its message.", comment: ""),
                code
            )))
    }

    // MARK: Homebrew process seam

    /// Produce the outdated list. `refresh` first runs `brew update` — the
    /// only network call in this half of the pane — and a failure there
    /// still falls through to the local list, so the rows stay useful and
    /// the reason shows beside them. The list itself always runs with
    /// auto-update off; without that, `brew outdated` fetches taps from
    /// GitHub first, which is what stalled for two minutes and then showed
    /// as "nothing to update" (#424).
    nonisolated static func loadBrewOutdated(refresh: Bool) async -> BrewOutdated {
        guard BrewClient.isInstalled else { return BrewOutdated(problem: .notInstalled) }
        return await Task.detached(priority: .userInitiated) {
            var problem: BrewOutdated.Problem?
            if refresh {
                let update = BrewClient.run(["update"], timeout: 600)
                if update.code != 0 {
                    problem = .failed(String(
                        format: NSLocalizedString("Homebrew couldn't refresh: %@", comment: ""),
                        brewProblemMessage(update)))
                }
            }
            let outdated = BrewClient.run(["outdated", "--json=v2"], timeout: 120, autoUpdate: false)
            guard outdated.code == 0 else {
                return BrewOutdated(problem: .failed(String(
                    format: NSLocalizedString("Homebrew couldn't list outdated packages: %@", comment: ""),
                    brewProblemMessage(outdated))))
            }
            return BrewOutdated(items: parseOutdated(outdated.out), problem: problem)
        }.value
    }

    /// The one line worth showing from a failed brew run: the deadline if
    /// that is what ended it, else brew's last stderr line, else the status.
    nonisolated static func brewProblemMessage(_ result: BrewClient.Result) -> String {
        if result.timedOut { return NSLocalizedString("Homebrew didn't respond in time.", comment: "") }
        let lines = result.err.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let last = lines.last(where: { !$0.isEmpty }) { return last }
        return String(format: NSLocalizedString("Homebrew exited with status %d.", comment: ""), result.code)
    }

    /// `brew upgrade <name>`, streamed line by line (H: live progress). The
    /// readability handler drains the pipe so waitUntilExit can't deadlock;
    /// a work item terminates on timeout.
    nonisolated static func runBrewUpgrade(_ item: OutdatedItem, onLine: @escaping (String) -> Void) async -> Int32 {
        guard let brew = BrewClient.path() else { return -1 }
        return await Task.detached(priority: .userInitiated) {
            runBrewStreaming(brew, ["upgrade", item.name], timeout: 1800, onLine: onLine)
        }.value
    }

    private nonisolated static func runBrewStreaming(_ brew: String, _ args: [String],
                                                     timeout: TimeInterval,
                                                     onLine: @escaping (String) -> Void) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = args
        p.environment = BrewClient.environment(brew: brew)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                onLine(line)
            }
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        do { try p.run() } catch { handle.readabilityHandler = nil; return -1 }
        p.waitUntilExit()
        killer.cancel()
        handle.readabilityHandler = nil
        return p.terminationStatus
    }

    /// Pure parser for `brew outdated --json=v2` — unit-tested against captured
    /// brew output, like the other `mo`/CLI parsers.
    nonisolated static func parseOutdated(_ json: String) -> [OutdatedItem] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [OutdatedItem] = []
        func add(_ arr: [[String: Any]]?, kind: String) {
            for d in arr ?? [] {
                guard let name = d["name"] as? String else { continue }
                let installed = (d["installed_versions"] as? [String])?.first ?? "?"
                let latest = d["current_version"] as? String ?? "?"
                out.append(OutdatedItem(id: "\(kind):\(name)", name: name,
                                        installed: installed, latest: latest, kind: kind))
            }
        }
        add(root["formulae"] as? [[String: Any]], kind: "formula")
        add(root["casks"] as? [[String: Any]], kind: "cask")
        return out
    }
}

private extension AppUpdateItem {
    init(id: String, name: String, path: String, bundleId: String,
         app: InstalledApp, source: UpdateSources.Source) {
        self.init(id: id, name: name, path: path, bundleID: bundleId,
                  installedVersion: SoftwareIcons.version(path) ?? "0",
                  sizeStr: app.sizeStr, source: source,
                  latestVersion: nil, pageURL: nil, releaseNotesURL: nil, lastUsed: nil)
    }
}
