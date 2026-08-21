//
//  SettingsView.swift
//  Burrow
//
//  Settings as a first-class pane — the same header/typography pattern as
//  Home and Software (capsule segments over a hairline, full-bleed) with
//  tabs General | Maintenance | Menu Bar | Advanced. No close chrome: you
//  leave the way you arrived, via the top nav (Esc also returns to the
//  previous pane). The common path (permissions, language, login, Dock)
//  stays in the first tab; everything agentic or experimental (MCP, query
//  server, AI, telemetry, Touch ID, engine) lives in Advanced so it can't
//  ambush a newcomer. Same contract as ever: reads/writes the typed
//  `Store`, surfaces `Maintenance` status, notes which changes need a
//  relaunch.
//

import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, maintenance, menuBar, advanced
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general:     return NSLocalizedString("General", comment: "")
            case .maintenance: return NSLocalizedString("Maintenance", comment: "")
            case .menuBar:     return NSLocalizedString("Menu Bar", comment: "")
            case .advanced:    return NSLocalizedString("Advanced", comment: "")
            }
        }
    }

    /// Anchor for deep-links that want the privileged-helper section on
    /// screen (RootView's Touch ID banner).
    static let helperAnchor = "privileged-helper"

    /// Wired by AppDelegate; the only consumer is "Run maintenance now".
    var onRunMaintenance: (() -> Void)?
    /// Esc leaves Settings (RootView returns to the previous pane). The
    /// pane has no close chrome of its own — navigation lives in the floating rail.
    var onClose: (() -> Void)?
    /// A section anchor to scroll to once the pane lays out. Only set when
    /// something deep-linked here to offer a specific setting.
    var scrollTarget: String?

    @State private var tab: Tab

    init(onRunMaintenance: (() -> Void)? = nil,
         onClose: (() -> Void)? = nil,
         initialTab: Tab = .general,
         scrollTarget: String? = nil) {
        self.onRunMaintenance = onRunMaintenance
        self.onClose = onClose
        self.scrollTarget = scrollTarget
        self._tab = State(initialValue: initialTab)
    }

    // General
    @State private var fdaGranted = Privacy.hasFullDiskAccess()
    /// FDA state when Settings opened. The running process only gains FDA
    /// on relaunch, so a false→true flip (the user granted it just now)
    /// means a relaunch is needed before scans can reach protected caches.
    private let fdaAtOpen = Privacy.hasFullDiskAccess()
    @State private var appLanguage: String = Store.appLanguage
    // Loaded off-main in onAppear — `SMAppService.status` is a synchronous
    // XPC call that hung the main thread when read in this @State initializer.
    @State private var launchAtLogin: Bool = false
    @State private var hideDockIcon: Bool = Store.hideDockIcon
    @State private var skipIntro: Bool = Store.skipIntro
    @State private var notifyOnCompletion: Bool = Store.notifyOnCompletion
    @State private var smartReminders: Bool = Store.smartRemindersEnabled
    @State private var watchStartupItems: Bool = Store.watchStartupItems
    @State private var thresholdAlerts: Bool = Store.thresholdAlertsEnabled
    @State private var cpuAlertThreshold: Int = Store.cpuAlertThreshold
    @State private var memAlertThreshold: Int = Store.memAlertThreshold
    @State private var processWatchdog: Bool = Store.processWatchdogEnabled
    @State private var procWatchdogCPU: Int = Int(Store.processWatchdogCPU)
    @State private var procWatchdogSeconds: Int = Store.processWatchdogSeconds
    @State private var procWatchdogAction: String = Store.processWatchdogAction
    @State private var showRestore = false
    @State private var brewBusy = false
    @State private var brewSnapshotStatus = ""
    @State private var autoCheckUpdates: Bool = Store.autoCheckForUpdates
    @State private var cameraMicIndicator: Bool = Store.cameraMicIndicatorEnabled

    // Maintenance
    @State private var whitelistPatterns: [String] = []
    @State private var newPattern = ""
    @State private var removalMode: CacheRemovalMode = Store.cacheRemovalMode
    @State private var sampleIntervalSeconds: Int = Store.sampleIntervalSeconds
    @State private var retentionDays: Int = Store.retentionDays
    @State private var autoVacuum: Bool = Store.autoVacuum
    @State private var dbSizeText: String = "—"
    @State private var lastMaintenanceText: String = "—"

    // Menu bar
    @State private var showMenuBarIcon: Bool = Store.showMenuBarIcon
    @State private var displayMode: MenuBarDisplayMode = Store.menuBarDisplayMode
    /// The compatibility guard suppresses the menu-bar item on some macOS
    /// builds. Without this the toggle read as on while doing nothing (#319).
    @State private var menuBarSuppressed: Bool = false
    @State private var menuBarSuppressionReason: LaunchRecoveryReason? = nil
    @State private var menuBarItems: [MenuBarItem] = Store.menuBarItems
    /// Which widget's options panel is expanded in the editor (one at a time).
    @State private var expandedMenuBarItem: UUID?
    @State private var popupSections: Set<PopupSection> = Store.popupSections
    @State private var popupTiles: Set<MenuBarMetric> = Store.popupTiles
    @State private var runnerConfig: RunnerConfig = Store.runnerConfig
    @State private var inputLock: Bool = Store.cleanScreenInputLock
    @State private var keepAwakeLidClosed: Bool = Store.keepAwakeLidClosed
    @State private var axTrusted = CleanScreen.inputLockPermitted()

    // Advanced
    @State private var queryServerEnabled: Bool = Store.queryServerEnabled
    @State private var telemetryEnabled: Bool = Store.telemetryEnabled
    @State private var mcpActionsEnabled: Bool = Store.mcpActionsEnabled
    @State private var mcpIrreversibleEnabled: Bool = Store.mcpIrreversibleEnabled
    @State private var aiEnabled: Bool = Store.aiEnabled
    @State private var aiProvider: String = Store.aiProvider
    @State private var aiOllamaModel: String = Store.aiOllamaModel
    @State private var aiOpenAIBaseURL: String = Store.aiOpenAIBaseURL
    @State private var aiOpenAIModel: String = Store.aiOpenAIModel
    @State private var aiOpenAIKey: String = Store.aiOpenAIKey
    @State private var moleVersion: String = "—"
    @State private var moleUpdating = false
    @State private var engineUpdatePolicy: MoleCLI.EngineUpdatePolicy = .unavailable
    @State private var copiedConfig = false
    // The "Touch ID for sudo" row this branch was hardening against the repointed engine
    // ("unknown command: touchid" must not read as a false "Disabled") is gone entirely on
    // main — #346 replaced the whole section with the privileged helper below, which asks
    // macOS for authorization rather than shelling out to `mo touchid`. The engine-support
    // guard has nothing left to guard, so it retires with the feature.
    @State private var helperStatus: HelperRegistrationStatus = .notRegistered
    @State private var helperBusy = false
    @State private var helperError: String?

    /// Drop-in MCP config for Claude Code / Cursor / Codex / Cline — they
    /// all share the same `{command, args}` stdio shape, so one snippet
    /// covers every agent.
    private let mcpConfigJSON = """
    {
      "mcpServers": {
        "burrow": {
          "command": "/Applications/Burrow.app/Contents/MacOS/Burrow",
          "args": ["--mcp"]
        }
      }
    }
    """

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 10)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch tab {
                        case .general:     generalTab
                        case .maintenance: maintenanceTab
                        case .menuBar:     menuBarTab
                        case .advanced:    advancedTab
                        }
                    }
                    // Full-bleed pane, readable column: the cards cap at a
                    // comfortable measure and stay centered in wide windows.
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                // A deep-linked section is often below the fold; the anchor
                // only exists once the tab's content has laid out, so this
                // waits a beat rather than scrolling to nothing.
                .onAppear {
                    guard let scrollTarget else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(scrollTarget, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { onClose?() }
        .sheet(isPresented: $showRestore) {
            VStack(spacing: 0) {
                HStack { Spacer(); Button(NSLocalizedString("Done", comment: "")) { showRestore = false }.padding(12) }
                RestoreView()
            }
            .frame(width: 460, height: 440)
        }
        .onAppear {
            refreshStatusLabels(); loadMoleVersion(); loadLaunchAtLogin()
            loadHelperStatus()
            whitelistPatterns = MoleWhitelist.live.patterns()
            menuBarSuppressed = AppDelegate.shared?.menuBarSuppressedByCompatibilityGuard ?? false
            menuBarSuppressionReason = AppDelegate.shared?.menuBarSuppressionReason
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fdaGranted = Privacy.hasFullDiskAccess()
            axTrusted = CleanScreen.inputLockPermitted()
            // Approving the helper happens in System Settings, outside this
            // app, so the row would otherwise still read "waiting for your
            // approval" after the user came back having already granted it.
            loadHelperStatus()
        }
    }

    // MARK: - Header (capsule segments, same pattern as Home/Software)

    private var header: some View {
        HStack(spacing: 12) {
            segmented
            Spacer()
        }
    }

    private var segmented: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { t in
                let on = t == tab
                Button { withAnimation(.easeOut(duration: 0.14)) { tab = t } } label: {
                    Text(t.label)
                        .font(Brand.mono(12, on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.black : Brand.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background { if on { Capsule().fill(.white) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.22)))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }

    // MARK: - General

    private var generalTab: some View {
        Group {
            section("Permissions", "lock.shield") {
                PermissionRow(
                    title: NSLocalizedString("Full Disk Access", comment: ""),
                    benefit: fdaGranted
                        ? NSLocalizedString("On. Burrow can reach system and app caches.", comment: "")
                        : NSLocalizedString("Off. Safe scan in use — most system caches stay out of reach.", comment: ""),
                    granted: fdaGranted,
                    onOpenSettings: { Privacy.openFullDiskAccessSettings() },
                    onCheck: { fdaGranted = Privacy.hasFullDiskAccess() },
                    // Granted this session → macOS only hands FDA to a fresh
                    // process, so offer a one-click relaunch instead of the
                    // system's "quit it yourself" prompt.
                    onRelaunch: (fdaGranted && !fdaAtOpen) ? { Privacy.relaunch() } : nil)
            }

            section("Language", "globe") {
                HStack {
                    Text(NSLocalizedString("App language", comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                    Spacer()
                    Picker("", selection: $appLanguage) {
                        Text(NSLocalizedString("System", comment: "")).tag("")
                        Text(verbatim: "English").tag("en")
                        Text(verbatim: "简体中文").tag("zh-Hans")
                        Text(verbatim: "繁體中文").tag("zh-Hant")
                        Text(verbatim: "Русский").tag("ru")
                    }
                    .labelsHidden().pickerStyle(.menu).tint(Brand.textSecondary).fixedSize()
                    .onChange(of: appLanguage) { _, v in
                        Store.appLanguage = v
                        promptRelaunch()
                    }
                }
                footnote("Burrow ships English, 简体中文, 繁體中文, and Русский. A language change takes effect after a relaunch.")
            }

            section("Startup & window", "macwindow") {
                toggleRow("Launch at Login", isOn: $launchAtLogin) { on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
                footnote("Starts Burrow quietly at login so sampling and the menu-bar monitor are always on.")
                toggleRow("Hide Dock Icon when window closes", isOn: $hideDockIcon) { on in
                    Store.hideDockIcon = on
                }
                .disabled(!showMenuBarIcon)
                footnote("On: Burrow retreats to the menu bar when you close the window. Off: it stays in the Dock. With the menu-bar icon hidden, the Dock icon always stays — otherwise the app would be unreachable.")
                toggleRow("Skip Intro Screens", isOn: $skipIntro) { Store.skipIntro = $0 }
                footnote("Jumps past the tools' idle screens where a read-only preview can start right away (Clean starts its scan when you open the tab).")
                HStack {
                    Text(NSLocalizedString("Onboarding", comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                    Spacer()
                    PillButton(title: "Replay onboarding", filled: false) {
                        if #available(macOS 14, *) { AppDelegate.shared?.replayOnboarding() }
                    }
                }
                footnote("Shows the first-run slides again (permissions, what's included). Finishing them marks onboarding done as usual.")
            }

            section("Notifications", "bell.badge") {
                toggleRow("Notify when long operations finish", isOn: $notifyOnCompletion) {
                    Store.notifyOnCompletion = $0
                }
                footnote("Clean, Optimize and Uninstall post a notice with the result (e.g. space freed) when they finish while Burrow is in the background. macOS asks for notification permission the first time one fires.")
                toggleRow("Smart reminders", isOn: $smartReminders) { Store.smartRemindersEnabled = $0 }
                footnote("Occasional, throttled nudges: it's been a couple of weeks since your last clean, free disk space dropped under 10%, or the Trash is holding more than 5 GB. Each fires at most once a week, never while you're in the app. Off by default.")
                toggleRow("New startup-item alerts", isOn: $watchStartupItems) { Store.watchStartupItems = $0 }
                footnote("Notifies you when a new login item or LaunchAgent appears — a lightweight persistence check. On by default.")
                toggleRow("CPU / memory threshold alerts", isOn: $thresholdAlerts) { Store.thresholdAlertsEnabled = $0 }
                footnote("Notifies once per episode when CPU stays pegged or memory pressure runs high. Off by default.")
                if thresholdAlerts {
                    Stepper(value: $cpuAlertThreshold, in: 50...100, step: 5) {
                        Text(String(format: NSLocalizedString("Alert when CPU usage stays above %d%%", comment: ""), cpuAlertThreshold))
                            .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                    }
                    .onChange(of: cpuAlertThreshold) { _, v in Store.cpuAlertThreshold = v }
                    Stepper(value: $memAlertThreshold, in: 50...100, step: 5) {
                        Text(String(format: NSLocalizedString("Alert when memory used stays above %d%%", comment: ""), memAlertThreshold))
                            .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                    }
                    .onChange(of: memAlertThreshold) { _, v in Store.memAlertThreshold = v }
                }
                toggleRow("High-CPU process watchdog", isOn: $processWatchdog) { Store.processWatchdogEnabled = $0 }
                footnote("Acts automatically on a process that stays pegged. Off by default — Suspend and Quit only affect your own processes; Notify just warns you.")
                if processWatchdog {
                    Stepper(value: $procWatchdogCPU, in: 50...100, step: 5) {
                        Text(String(format: NSLocalizedString("When a process stays above %d%% CPU", comment: ""), procWatchdogCPU))
                            .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                    }
                    .onChange(of: procWatchdogCPU) { _, v in Store.processWatchdogCPU = Double(v) }
                    Stepper(value: $procWatchdogSeconds, in: 10...300, step: 10) {
                        Text(String(format: NSLocalizedString("for at least %d seconds", comment: ""), procWatchdogSeconds))
                            .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                    }
                    .onChange(of: procWatchdogSeconds) { _, v in Store.processWatchdogSeconds = v }
                    Picker(selection: $procWatchdogAction) {
                        Text(NSLocalizedString("Notify me", comment: "")).tag("notify")
                        Text(NSLocalizedString("Suspend it", comment: "")).tag("suspend")
                        Text(NSLocalizedString("Quit it", comment: "")).tag("quit")
                    } label: {
                        Text(NSLocalizedString("Then", comment: ""))
                            .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: procWatchdogAction) { _, v in Store.processWatchdogAction = v }
                }
            }

            section("About", "info.circle") {
                infoRow("Version", appVersionText)
                toggleRow("Check for updates automatically", isOn: $autoCheckUpdates) { on in
                    AppUpdate.shared.setAutomaticChecks(on)
                }
                Text("Sparkle checks Burrow's signed update feed after startup settles and about once a day. It asks before downloading or installing anything.")
                    .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    PillButton(title: "Check for Updates", filled: false) { UpdateCheck.checkNow() }
                    PillButton(title: "About Burrow", filled: false) { AppDelegate.shared?.showAboutPanel() }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Link(NSLocalizedString("Download Latest Version", comment: ""),
                             destination: UpdateRecovery.manualDownloadURL)
                        Link(NSLocalizedString("Source on GitHub", comment: ""),
                             destination: URL(string: "https://github.com/caezium/Burrow")!)
                        // The harmless UI-only rollout validator (issue #322):
                        // a cached, telemetry-gated boolean that adds one
                        // factual link and does nothing else. OFF by default.
                        if FeatureFlags.isEnabled(.aboutReleaseNotesLink) {
                            Link(NSLocalizedString("Release Notes", comment: ""),
                                 destination: URL(string: "https://github.com/caezium/Burrow/releases")!)
                        }
                    }
                    .font(Brand.sans(11, .semibold)).foregroundStyle(Brand.green)
                }
            }
        }
    }

    private var appVersionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }

    // MARK: - Maintenance

    private var maintenanceTab: some View {
        Group {
            section("Protected Items", "shield.lefthalf.filled") {
                Text("Paths and glob patterns Mole never cleans — `mo clean` and `mo optimize` skip anything matching them. \u{201C}Always skip this\u{201D} in the Clean review writes here too.")
                    .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if whitelistPatterns.isEmpty {
                    Text("No protected items yet.").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                } else {
                    ForEach(whitelistPatterns, id: \.self) { pattern in
                        HStack {
                            Text(pattern).font(Brand.mono(10)).foregroundStyle(Brand.textPrimary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                try? MoleWhitelist.live.remove(pattern)
                                whitelistPatterns = MoleWhitelist.live.patterns()
                            } label: {
                                Image(systemName: "minus.circle").font(.system(size: 11))
                                    .foregroundStyle(Brand.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(format: NSLocalizedString("Remove %@ from protected items", comment: ""), pattern))
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField(NSLocalizedString("Add a path or glob pattern", comment: ""), text: $newPattern)
                        .textFieldStyle(.plain).font(Brand.mono(11))
                    Button(NSLocalizedString("Add", comment: "")) {
                        let p = newPattern.trimmingCharacters(in: .whitespaces)
                        guard !p.isEmpty else { return }
                        try? MoleWhitelist.live.add(p)
                        newPattern = ""
                        whitelistPatterns = MoleWhitelist.live.patterns()
                    }
                    .buttonStyle(.plain).font(Brand.sans(11, .semibold)).foregroundStyle(Brand.green)
                }
                .padding(.top, 2)
            }

            section("Cache removal", "trash") {
                HStack {
                    Text(NSLocalizedString("Removal mode", comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                    Spacer()
                    Picker("", selection: $removalMode) {
                        Text(NSLocalizedString("Permanent", comment: "")).tag(CacheRemovalMode.permanent)
                        Text(NSLocalizedString("Trash", comment: "")).tag(CacheRemovalMode.trash)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                    .onChange(of: removalMode) { _, v in Store.cacheRemovalMode = v }
                }
                footnote("Permanent (default): the engine removes caches outright — freed space is real, immediately. Trash: reviewed, ticked paths go to the Trash instead — recoverable, but space frees only when Trash empties, and the run won't appear in `mo history`.")
            }

            section("Storage", "internaldrive") {
                infoRow("Currently using", dbSizeText)
                infoRow("Last maintenance", lastMaintenanceText)
                HStack(spacing: 8) {
                    Spacer()
                    PillButton(title: "Restore last cleanup…", filled: false) { showRestore = true }
                    PillButton(title: "Run maintenance now", filled: false) {
                        onRunMaintenance?(); refreshStatusLabels()
                    }
                }
                footnote("History lives at ~/Library/Application Support/Burrow/burrow.db. Rows past the retention window are pruned hourly.")
            }

            if BrewClient.isInstalled {
                section("Homebrew", "mug") {
                    Text("Save your Homebrew setup to a Brewfile, and restore it on a new Mac in one step (brew bundle).")
                        .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if brewBusy { ProgressView().controlSize(.small) }
                        Text(brewSnapshotStatus).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                        Spacer()
                        PillButton(title: "Export Brewfile…", filled: false) { exportBrewfile() }
                            .disabled(brewBusy).opacity(brewBusy ? 0.4 : 1)
                        PillButton(title: "Restore…", filled: false) { restoreBrewfile() }
                            .disabled(brewBusy).opacity(brewBusy ? 0.4 : 1)
                    }
                }
            }

            section("History retention", "calendar") {
                pickerRow("Keep history for", selection: $retentionDays,
                          options: [(1, "1 day"), (7, "7 days"), (14, "14 days"),
                                    (30, "30 days"), (90, "90 days"), (180, "180 days"), (365, "1 year")]) {
                    Store.retentionDays = $0
                }
                toggleRow("Vacuum DB after large prunes", isOn: $autoVacuum) { Store.autoVacuum = $0 }
            }

            section("Sampling", "waveform.path.ecg") {
                pickerRow("Sample every", selection: $sampleIntervalSeconds,
                          options: [(5, "5 sec"), (15, "15 sec"), (30, "30 sec"),
                                    (60, "60 sec"), (120, "2 min"), (300, "5 min")]) {
                    Store.sampleIntervalSeconds = $0
                }
                footnote("With Mole 1.44+ Burrow streams `mo status --watch` for live status; on older mo it falls back to polling `mo status --json` at this cadence. 60 s is plenty for charts; tighter intervals give finer detail at the cost of more subprocess churn.")
            }
        }
    }

    // MARK: - Menu bar

    /// Shown in place of a toggle that cannot act. The recovery alert fires
    /// once per macOS build, so without this the only lasting explanation for
    /// a missing menu-bar icon was a checked switch that did nothing (#319).
    /// Only the macOS-build guard is about macOS. The other reason is "a
    /// previous launch of Burrow ended badly while the item was being
    /// created", and telling that user to update macOS sends them to do
    /// something that cannot help.
    private var menuBarNoticeTitle: String {
        switch menuBarSuppressionReason {
        case .macOS27Beta4:
            return NSLocalizedString("Menu bar item paused on this macOS build", comment: "")
        default:
            return NSLocalizedString("Menu bar item paused after a failed start", comment: "")
        }
    }

    private var menuBarNoticeBody: String {
        switch menuBarSuppressionReason {
        case .macOS27Beta4:
            return NSLocalizedString("Creating it could freeze system input on this build, so Burrow runs from the Dock instead. It returns automatically once you update macOS.", comment: "")
        default:
            return NSLocalizedString("Burrow stopped unexpectedly while creating the menu bar item last time, so it started from the Dock instead. It returns on its own the next time Burrow runs normally.", comment: "")
        }
    }

    private var menuBarCompatibilityNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.amber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(menuBarNoticeTitle)
                    .font(Brand.sans(11, .semibold)).foregroundStyle(Brand.textPrimary)
                Text(menuBarNoticeBody)
                    .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.amber.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.amber.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var menuBarTab: some View {
        Group {
            section("Menu bar", "menubar.rectangle") {
                if menuBarSuppressed { menuBarCompatibilityNotice }
                toggleRow("Show menu bar icon", isOn: $showMenuBarIcon) { on in
                    Store.showMenuBarIcon = on
                    AppDelegate.shared?.applyMenuBarVisibility(on)
                }
                .disabled(menuBarSuppressed)
                .opacity(menuBarSuppressed ? 0.5 : 1)
                footnote(menuBarSuppressed
                    ? "Paused on this macOS build. The setting is kept and applies again as soon as Burrow can create the menu bar item safely."
                    : "Applies immediately. When off, Burrow shows a Dock icon instead so it stays reachable — a Dock click reopens the window.")
                HStack {
                    Text(NSLocalizedString("Display", comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                    Spacer()
                    Picker("", selection: $displayMode) {
                        Text(NSLocalizedString("Icon", comment: "")).tag(MenuBarDisplayMode.icon)
                        Text(NSLocalizedString("Metrics", comment: "")).tag(MenuBarDisplayMode.metrics)
                        Text(NSLocalizedString("Runner", comment: "")).tag(MenuBarDisplayMode.runner)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 240)
                    .onChange(of: displayMode) { _, v in
                        Store.menuBarDisplayMode = v
                        AppDelegate.shared?.applyMenuBarVisibility(Store.showMenuBarIcon)
                    }
                }
                .disabled(menuBarSuppressed)
                .opacity(menuBarSuppressed ? 0.5 : 1)
                footnote("Choose which metrics appear in the menu bar and how each is shown — refreshed with the sampler. Each metric has its own text size in its options (⚙︎).")
                if displayMode == .metrics { menuBarMetricsEditor }
                toggleRow("Show camera & mic in-use indicator", isOn: $cameraMicIndicator) {
                    Store.cameraMicIndicatorEnabled = $0
                }
                footnote("A small \u{201C}in use\u{201D} chip in the popover when the camera or microphone is active — the same system signal as Control Center, so it also lights for Siri, dictation and Continuity Camera. Off by default.")
            }

            section("Animated icon", "hare") {
                footnote("A RunCat-style animated icon whose speed tracks a metric. Pick \u{201C}Runner\u{201D} above to show it on its own, or turn on \u{201C}Before widgets\u{201D} to animate it ahead of the metric row.")
                runnerEditor
            }

            section("Popup contents", "macwindow") {
                footnote("Choose which sections and metric tiles the menu-bar popover shows.")
                popupContentsEditor
            }

            section("Keyboard shortcuts", "keyboard") {
                shortcutRow("Open Burrow", action: .openBurrow)
                shortcutRow("Keep Screen On", action: .keepScreenOn)
                shortcutRow("Clean Screen", action: .cleanScreen)
                footnote("System-wide. Click a chip, press a combination with ⌃, ⌥ or ⌘; Esc cancels, × clears.")
            }

            section("Keep Screen On", "sun.max") {
                toggleRow("Also keep working with the lid closed", isOn: $keepAwakeLidClosed) { on in
                    Store.keepAwakeLidClosed = on
                }
                footnote("Adds a stronger sleep assertion so a backup or render survives shutting the lid. Off by default — it changes power behaviour; best on AC power. Takes effect next time you start Keep Screen On.")
            }

            section("Clean Screen", "rectangle.inset.filled") {
                toggleRow("Block keys while wiping", isOn: $inputLock) { on in
                    Store.cleanScreenInputLock = on
                }
                if inputLock, !axTrusted {
                    PermissionRow(
                        title: NSLocalizedString("Accessibility", comment: ""),
                        benefit: NSLocalizedString("Needed to swallow key presses while you wipe. Esc always exits.", comment: ""),
                        granted: axTrusted,
                        onOpenSettings: { CleanScreen.openAccessibilitySettings() },
                        onCheck: { axTrusted = CleanScreen.inputLockPermitted() })
                }
                footnote("Off: Clean Screen still works, keys just aren't blocked. Esc always exits either way.")
            }
        }
    }

    private func shortcutRow(_ label: String, action: HotKeyAction) -> some View {
        HStack {
            Text(NSLocalizedString(label, comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
            Spacer()
            ShortcutRecorder(action: action)
        }
    }

    // MARK: - Advanced

    private var advancedTab: some View {
        Group {
            section("Ask your AI about your Mac (MCP)", "sparkles") {
                Text("Burrow exposes your Mac's recorded history to coding agents — Claude Code, Cursor, Codex, Cline — over MCP. Add the config below, then ask in plain language. The server starts on demand over stdio; there's no port and no always-on listener.")
                    .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                codeBlock(mcpConfigJSON)

                infoRow("Read tools", "snapshot · history · top_processes · process_usage · info · analyze")
                infoRow("Cleanup tools", "clean · optimize · uninstall · purge · installer")

                subLabel("Try asking")
                promptRow("What's my Mac's CPU and memory usage right now?")
                promptRow("What's taking up space in my home folder?")
                promptRow("Preview what a cleanup would free, then clean it up.")
                promptRow("Uninstall Slack and remove its leftovers.")

                Divider().padding(.vertical, 2)
                toggleRow("Let agents run cleanups for real", isOn: $mcpActionsEnabled) {
                    Store.mcpActionsEnabled = $0
                }
                footnote("OFF by default. Agents can always read metrics and run dry-run previews. With this on, an agent can run a real `mo clean` / `optimize` — but ONLY when it also passes an explicit confirm flag, so a deletion is never one stray sentence away. Turn it off and agents are read-only again. Data stays on this Mac.")
                toggleRow("Also allow uninstalls & permanent deletes", isOn: $mcpIrreversibleEnabled) {
                    Store.mcpIrreversibleEnabled = $0
                }
                .disabled(!mcpActionsEnabled)
                footnote("A second key for what the Trash can't undo: real `mo uninstall`, and `permanent:true` deletes. Needs the cleanup switch above too; an uninstall also aborts unless mo matches exactly the requested apps.")
            }

            section("Local HTTP query server", "antenna.radiowaves.left.and.right") {
                toggleRow("Enable HTTP query server", isOn: $queryServerEnabled) { Store.queryServerEnabled = $0 }
                infoRow("Endpoint", "127.0.0.1:\(Store.queryServerPort)")
                infoRow("Authentication", NSLocalizedString("Bearer token required", comment: "query server auth"))
                footnote("Optional REST surface for dashboards or curl: /health, /info, /snapshot, /metrics over localhost. Every request needs the per-install token; retrieve it locally with `defaults read dev.caezium.Burrow query_auth_token`. Separate from the MCP stdio server above; toggle + port changes take effect after a relaunch.")
            }

            section("Explain (AI) — experimental", "sparkles") {
                toggleRow("Enable the Explain lens", isOn: $aiEnabled) { Store.aiEnabled = $0 }
                HStack {
                    Text("Backend").font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                    Spacer()
                    Picker("", selection: $aiProvider) {
                        Text("Local · Ollama").tag("ollama")
                        Text("LM Studio / API").tag("openai")
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 230)
                    .onChange(of: aiProvider) { _, v in Store.aiProvider = v }
                }
                if aiProvider == "ollama" {
                    aiField("Ollama model", placeholder: "llama3.2", text: $aiOllamaModel) { Store.aiOllamaModel = $0 }
                    footnote("Runs against a local Ollama model — nothing leaves this Mac. Start it with `ollama run <model>`.")
                } else {
                    aiField("Base URL", placeholder: "http://127.0.0.1:1234/v1", text: $aiOpenAIBaseURL) { Store.aiOpenAIBaseURL = $0 }
                    aiField("Model", placeholder: "local-model", text: $aiOpenAIModel) { Store.aiOpenAIModel = $0 }
                    aiField("API key (optional)", placeholder: "blank for LM Studio", text: $aiOpenAIKey, secure: true) { Store.aiOpenAIKey = $0 }
                    footnote("Any OpenAI-compatible server. For LM Studio: load a model, open Developer ▸ Start Server, and leave the key blank — the default URL is already LM Studio's. A hosted endpoint (e.g. OpenAI) needs a key and sends the metrics summary off-device (never file contents).")
                }
                footnote("Adds an \u{201C}Explain\u{201D} button to Status that reads your latest snapshot and explains it in plain English, optionally suggesting Clean/Purge/Installers.")
            }

            section("Anonymous usage", "chart.bar") {
                toggleRow("Share anonymous usage & diagnostics", isOn: $telemetryEnabled) { on in
                    Telemetry.setEnabled(on)
                }
                footnote("Sends anonymous product analytics (PostHog) plus crash, hang, startup, update, and sampled performance diagnostics (Sentry): random install IDs, app and exact macOS build, CPU type, screens and features used, and fixed-name diagnostic milestones. Never screenshots, screen recordings, your file names, contents, user paths, URLs, or metrics. On by default; turn it off and both stop. Full list in TELEMETRY.md.")
            }

            section("Privileged helper", "lock.shield") {
                infoRow("Status", helperStatusLabel)
                HStack {
                    Spacer()
                    if helperBusy { ProgressView().controlSize(.small).padding(.trailing, 4) }
                    PillButton(title: helperInstalled ? "Remove" : "Install", filled: false) { toggleHelper() }
                }
                if let helperError {
                    footnote(helperError)
                }
                footnote("Runs Burrow's admin operations — scan, clean, optimize — through a small signed helper instead of a password-only prompt, so macOS can offer Touch ID. Installing it needs your approval once and grants no standing access: you're asked to authenticate for each operation you start. The helper can only perform those three operations — it cannot be asked to run anything else.")
            }
            .id(Self.helperAnchor)

            section("Engine", "shippingbox") {
                infoRow("Version", moleVersion)
                // This branch had hidden the update button outright, because the bundled
                // engine has no `update` arm and pressing it could only ever fail. Main's
                // policy gate says the same thing more precisely: `.bundledWithApp` shows
                // no button at all (the case the branch was fixing), and `.external` keeps
                // it for a source build pointed at an engine outside the app bundle, which
                // really can update itself.
                if engineUpdatePolicy == .external {
                    HStack {
                        Spacer()
                        if moleUpdating { ProgressView().controlSize(.small).padding(.trailing, 4) }
                        PillButton(title: moleUpdating ? "Updating…" : "Update external engine", filled: false) { updateMole() }
                    }
                    footnote("This source build is using an engine outside Burrow.app, so its own updater remains available.")
                } else if engineUpdatePolicy == .bundledWithApp {
                    footnote("Included with Burrow. Engine updates arrive through signed Burrow releases so the app's Developer ID seal stays valid.")
                } else {
                    footnote("The bundled engine is missing. Reinstall Burrow to restore the signed app bundle.")
                }
            }
        }
    }

    // MARK: - Engine

    /// Show the engine's version WITH its product name ("burrow-engine 0.1.0"), not a bare
    /// "v0.1.0". Two reasons: the bundled engine numbers itself on its own 0.x line, so a
    /// lone 0.1.0 sitting a few rows under Burrow's own 0.11.x reads like the app is
    /// misreporting itself; and this row can just as easily be showing a separately
    /// installed mo on the 1.4x line, which the number alone gives no way to tell apart.
    private func loadMoleVersion() {
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = MoleCLI.versionReport()
            let policy = MoleCLI.currentEngineUpdatePolicy
            DispatchQueue.main.async {
                // Same fallback string, and the same localization, as `AppDelegate.showAboutPanel`
                // — the two rows report the identical fact one panel apart, and only this one was
                // hard-coded, so a zh build read "burrow-engine 0.1.0" in the About panel and a
                // bare English "not found" in Settings.
                moleVersion = engine?.display ?? NSLocalizedString("not found", comment: "")
                engineUpdatePolicy = policy
            }
        }
    }

    /// Read the login-item status off-main — `SMAppService.status` is a
    /// synchronous XPC call (a mach send-and-wait) that hung the main thread
    /// when it ran in the view's @State initializer (App-Hang).
    private func loadLaunchAtLogin() {
        DispatchQueue.global(qos: .userInitiated).async {
            let on = SMAppService.mainApp.status == .enabled
            DispatchQueue.main.async { launchAtLogin = on }
        }
    }

    /// ONLY reachable for `.external` — the caller gates the button on the update policy, and
    /// that gate is load-bearing rather than cosmetic. The bundled engine (post-repoint) has no
    /// self-update command at all: `burrow-engine`'s `cli.rs` dispatch table has no `update`
    /// arm, so it answers "unknown command: update". Running it there and reporting that as
    /// "Update didn't complete, try running it in a terminal" would be actively misleading — a
    /// terminal run hits the exact same bundled binary and fails the exact same way — and the
    /// bundled copy can only change when Burrow itself does anyway (bundle-burrow.sh stages a
    /// fresh one on every release). An external engine is a different animal: it lives outside
    /// the app bundle, nothing about Burrow's Developer ID seal depends on it, and if it's a
    /// separately installed mo then `mo update` is exactly the right thing to run.
    private func updateMole() {
        guard !moleUpdating else { return }
        moleUpdating = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = try? MoleCLI.run(args: ["update"], timeout: 600)
            let newVersion = MoleCLI.versionReport()
            DispatchQueue.main.async {
                moleUpdating = false
                if let newVersion { moleVersion = newVersion.display }
                let ok = (res?.exitCode ?? 1) == 0
                let alert = NSAlert()
                alert.messageText = NSLocalizedString(
                    ok ? "External engine is up to date" : "Update didn't complete",
                    comment: ""
                )
                alert.informativeText = ok
                    ? String(format: NSLocalizedString("Now on %@.", comment: ""), moleVersion)
                    : (res?.stderr.isEmpty == false ? String(res!.stderr.prefix(300))
                                                    : NSLocalizedString("The external engine updater exited non-zero. Try running `mo update` in a terminal.", comment: ""))
                alert.runModalQuiet()
            }
        }
    }

    // MARK: - Privileged helper

    private var helperInstalled: Bool { helperStatus != .notRegistered }

    private var helperStatusLabel: String {
        switch helperStatus {
        case .enabled: return "Installed"
        case .requiresApproval: return "Waiting for your approval in Login Items & Extensions"
        case .notRegistered: return "Not installed"
        }
    }

    private func loadHelperStatus() {
        let status = PrivilegedHelperClient.shared.registrationStatus
        DispatchQueue.main.async { helperStatus = status }
    }

    /// Watch for the approval landing.
    ///
    /// `register()` returns as soon as the request is filed, but the daemon
    /// stays in `.requiresApproval` until the user allows it in System
    /// Settings ▸ General ▸ Login Items & Extensions. That approval is
    /// asynchronous and happens in another process, with no notification back
    /// to us, so a one-shot read right after `register()` almost always
    /// reports the pre-approval state and then never corrects itself.
    ///
    /// Polling for a bounded window is the whole fix. It stops as soon as the
    /// status settles, and gives up rather than running forever if the user
    /// walks away or dismisses the prompt.
    private func pollHelperApproval(deadline: Date = Date().addingTimeInterval(90)) {
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let status = PrivilegedHelperClient.shared.registrationStatus
            helperStatus = status
            guard status == .requiresApproval else { return }
            pollHelperApproval(deadline: deadline)
        }
    }

    /// Install or remove the daemon. Both directions can throw — macOS refuses
    /// registration if the user declines, and we surface that rather than
    /// leaving the row silently unchanged.
    private func toggleHelper() {
        guard !helperBusy else { return }
        helperBusy = true
        helperError = nil
        let install = !helperInstalled
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                if install {
                    try PrivilegedHelperClient.shared.register()
                } else {
                    try PrivilegedHelperClient.shared.unregister()
                }
            } catch {
                // Show the real reason, not a shrug. The interesting failures
                // here are all indistinguishable from each other in a generic
                // message — a stale registration left by a previous build of
                // the app, a signature the system won't accept, or the user
                // declining — and the underlying code is what tells them
                // apart. `kSMErrorAlreadyRegistered` in particular is
                // actionable: the launchd job survives, bound to the old app
                // identity, and has to be removed before a new install works.
                let ns = error as NSError
                let detail = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
                if install {
                    let stale = ns.domain == "SMAppServiceErrorDomain" && ns.code == 134
                    failure = stale
                        ? "A helper from an earlier build of Burrow is still registered. Remove Burrow under System Settings ▸ General ▸ Login Items & Extensions, then install again. (\(detail))"
                        : "Couldn't install the helper — Burrow keeps using the password prompt. (\(detail))"
                } else {
                    failure = "Couldn't remove the helper. You can also turn it off in System Settings ▸ General ▸ Login Items & Extensions. (\(detail))"
                }
            }
            let status = PrivilegedHelperClient.shared.registrationStatus
            DispatchQueue.main.async {
                helperBusy = false
                helperError = failure
                helperStatus = status
                // Installing files the request; the user approves it elsewhere.
                if install, status == .requiresApproval { pollHelperApproval() }
            }
        }
    }

    // MARK: - Language relaunch

    private func promptRelaunch() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Relaunch to change language?", comment: "")
        alert.informativeText = NSLocalizedString("Burrow needs to relaunch to apply the new language.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Relaunch Now", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        guard alert.runModalQuiet() == .alertFirstButtonReturn else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    // MARK: - Section + row helpers

    // MARK: - Homebrew snapshots (brew bundle)

    private func exportBrewfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Brewfile"
        panel.canCreateDirectories = true
        guard CrashReporter.withoutAppHangTracking({ panel.runModal() }) == .OK, let url = panel.url else { return }
        brewBusy = true
        brewSnapshotStatus = NSLocalizedString("Exporting…", comment: "")
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                BrewClient.run(["bundle", "dump", "--file=\(url.path)", "--force"])
            }.value
            brewBusy = false
            if r.code == 0 {
                brewSnapshotStatus = NSLocalizedString("Exported.", comment: "")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                brewSnapshotStatus = NSLocalizedString("Export failed — check Homebrew.", comment: "")
            }
        }
    }

    private func restoreBrewfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard CrashReporter.withoutAppHangTracking({ panel.runModal() }) == .OK, let url = panel.url else { return }
        brewBusy = true
        brewSnapshotStatus = NSLocalizedString("Restoring — installing from your Brewfile can take a while…", comment: "")
        Task {
            // brew bundle installs each entry; user-scope, no elevation. Generous
            // timeout — a full restore on a new Mac is many packages.
            let r = await Task.detached(priority: .userInitiated) {
                BrewClient.run(["bundle", "--file=\(url.path)"], timeout: 1800)
            }.value
            brewBusy = false
            brewSnapshotStatus = r.code == 0
                ? NSLocalizedString("Restore complete.", comment: "")
                : NSLocalizedString("Restore finished with errors — check Homebrew.", comment: "")
        }
    }

    private func section<C: View>(_ title: String, _ glyph: String, @ViewBuilder content: @escaping () -> C) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: title, glyph: glyph, color: Brand.textSecondary)
                content()
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(NSLocalizedString(label, comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
            Spacer()
            Text(value).font(Brand.mono(11)).foregroundStyle(Brand.textPrimary)
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(NSLocalizedString(text, comment: "")).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Small all-caps section sub-heading (e.g. "TRY ASKING").
    private func subLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(Brand.mono(9, .bold)).tracking(0.6)
            .foregroundStyle(Brand.textTertiary).padding(.top, 2)
    }

    /// One example prompt with a one-click copy button (the text isn't
    /// selectable, so the button is the only way to grab it).
    private func promptRow(_ text: String) -> some View { PromptRow(text: text) }

    private struct PromptRow: View {
        let text: String
        @State private var copied = false
        @State private var hovering = false

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Brand.green).accessibilityHidden(true)
                Text("\u{201C}\(text)\u{201D}").font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(copied ? Brand.green : (hovering ? Brand.textSecondary : Brand.textTertiary))
                }
                .buttonStyle(.plain)
                .help("Copy prompt")
                .accessibilityLabel("Copy prompt")
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }

    /// Monospace config block with a one-click copy button.
    private func codeBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(Brand.mono(10)).foregroundStyle(Brand.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copiedConfig = true
                    // Reset the label so a later copy confirms again.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedConfig = false }
                } label: {
                    Label(copiedConfig ? "Copied" : "Copy config",
                          systemImage: copiedConfig ? "checkmark" : "doc.on.doc")
                        .font(Brand.mono(10)).foregroundStyle(Brand.green)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: isOn) {
            Text(NSLocalizedString(label, comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
        }
        .toggleStyle(.switch)
        .tint(Brand.green)
        .onChange(of: isOn.wrappedValue) { _, n in onChange(n) }
    }

    /// Trailing-aligned text-field row that persists on every keystroke, so
    /// closing Settings never loses an in-progress edit.
    // LocalizedStringKey (not String): a String label/placeholder reaches the
    // verbatim Text/TextField overload and skips localization. Example-value
    // placeholders (model ids, the LM Studio URL) simply have no translation
    // and fall back to themselves.
    private func aiField(_ label: LocalizedStringKey, placeholder: LocalizedStringKey,
                         text: Binding<String>, secure: Bool = false,
                         onChange: @escaping (String) -> Void) -> some View {
        HStack {
            Text(label).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
            Spacer()
            Group {
                // Secrets (the hosted-API key) render masked so a screen
                // share or screenshot doesn't leak them.
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain).font(Brand.mono(11))
            .multilineTextAlignment(.trailing).frame(width: 200)
            .onChange(of: text.wrappedValue) { _, v in onChange(v) }
        }
    }

    private func pickerRow(_ label: String, selection: Binding<Int>,
                           options: [(Int, String)], onChange: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(NSLocalizedString(label, comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
            Spacer()
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { Text(NSLocalizedString($0.1, comment: "")).tag($0.0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Brand.textSecondary)
            .fixedSize()
            .onChange(of: selection.wrappedValue) { _, n in onChange(n) }
        }
    }

    // MARK: - Menu bar metrics editor (issue #82)

    /// Reorderable list of widgets, each expandable into its full options
    /// (style, colour, label/value toggles, and style-specific extras), plus
    /// an "Add metric" menu. Changes persist + re-render the status item live.
    @ViewBuilder
    private var menuBarMetricsEditor: some View {
        VStack(spacing: 4) {
            if !menuBarItems.isEmpty { menuBarPreview }
            if menuBarItems.isEmpty {
                Text(NSLocalizedString("No metrics yet — add one below.", comment: ""))
                    .font(Brand.sans(11)).foregroundStyle(Brand.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(menuBarItems.enumerated()), id: \.element.id) { idx, item in
                VStack(spacing: 6) {
                    menuBarMetricRow(index: idx, item: item)
                    if expandedMenuBarItem == item.id {
                        menuBarItemOptions(index: idx, item: item)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(expandedMenuBarItem == item.id ? Brand.cardFill : Color.clear))
            }
            HStack(spacing: 12) {
                Menu {
                    ForEach(MenuBarMetric.allCases) { m in
                        Button { addMenuBarMetric(m) } label: { Label(m.title, systemImage: m.glyph) }
                    }
                } label: {
                    Label(NSLocalizedString("Add metric", comment: ""), systemImage: "plus.circle")
                        .font(Brand.sans(12)).foregroundStyle(Brand.green)
                }
                .menuStyle(.borderlessButton).fixedSize()
                Menu {
                    ForEach(Self.menuBarPresets, id: \.name) { preset in
                        Button(preset.name) { applyMenuBarPreset(preset.items) }
                    }
                } label: {
                    Label(NSLocalizedString("Presets", comment: ""), systemImage: "square.grid.2x2")
                        .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    /// Live preview of the configured row, rendered with the real sampler values
    /// (refreshed ~1 s) so it matches what's actually in the menu bar.
    private var menuBarPreview: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack {
                Spacer()
                if let img = MenuBarRenderer.image(items: menuBarItems, values: liveMenuBarValues) {
                    Image(nsImage: img)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Brand.cardFill))
                }
                Spacer()
            }
        }
        .padding(.bottom, 4)
    }

    /// The real values the menu-bar row would draw, from the running sampler;
    /// falls back to representative numbers before the first sample.
    private var liveMenuBarValues: MenuBarMetricValues {
        guard let live = AppDelegate.shared?.producer?.live else { return Self.menuBarPreviewValues }
        var v = MenuBarMetricValues()
        if let s = live.lastSnapshot {
            v.primary[.cpu] = s.cpu.usage
            v.primary[.memory] = s.memory.usedPercent
            if let g = s.gpu?.first, g.usage >= 0 { v.primary[.gpu] = g.usage }
            if let d = s.disks.first { v.primary[.diskUsage] = d.usedPercent }
            if let t = s.thermal {
                if t.fanSpeed > 0 || (t.fanCount ?? 0) > 0 { v.primary[.fan] = Double(t.fanSpeed) }
                if let temp = t.bestTemp { v.primary[.temperature] = temp }
                if t.systemPower > 0 { v.primary[.power] = t.systemPower }
            }
            if let b = s.batteries?.first {
                v.primary[.battery] = b.percent
                v.batteryCharging = b.status.lowercased().contains("charg")
            }
        }
        v.primary[.network] = live.rxMBs; v.secondary[.network] = live.txMBs
        v.primary[.diskIO]  = live.readMBs; v.secondary[.diskIO]  = live.writeMBs
        v.memoryPressurePercent = MemoryPressure.percent()
        return v
    }

    /// Representative values for the Settings preview only.
    private static let menuBarPreviewValues: MenuBarMetricValues = {
        var v = MenuBarMetricValues()
        v.primary = [.cpu: 42, .memory: 68, .gpu: 31, .diskUsage: 55, .network: 8.4,
                     .diskIO: 3.1, .fan: 2200, .temperature: 74, .battery: 86, .power: 14]
        v.secondary = [.network: 1.2, .diskIO: 0.6]
        v.histories = [.cpu: [30, 44, 38, 52, 42], .memory: [60, 63, 66, 68],
                       .gpu: [18, 26, 31], .network: [4, 7, 8.4, 6, 8.4],
                       .diskIO: [1, 2.4, 3.1], .power: [10, 12, 14, 13, 14]]
        return v
    }()

    /// One-click starting layouts for the metric row.
    private struct MenuBarPreset { let name: String; let items: [MenuBarItem] }
    private static let menuBarPresets: [MenuBarPreset] = [
        .init(name: NSLocalizedString("CPU · RAM", comment: ""),
              items: [MenuBarItem(metric: .cpu, style: .value),
                      MenuBarItem(metric: .memory, style: .value, color: .pressure)]),
        .init(name: NSLocalizedString("CPU · RAM · Net · Disk", comment: ""),
              items: [MenuBarItem(metric: .cpu, style: .value),
                      MenuBarItem(metric: .memory, style: .value, color: .pressure),
                      MenuBarItem(metric: .network, style: .speed), MenuBarItem(metric: .diskUsage, style: .bar)]),
        .init(name: NSLocalizedString("Everything", comment: ""),
              items: MenuBarMetric.allCases.map { MenuBarItem(metric: $0, style: $0.styles.first ?? .value, color: $0.defaultColor) }),
    ]

    private func applyMenuBarPreset(_ items: [MenuBarItem]) {
        menuBarItems = items
        expandedMenuBarItem = nil
        commitMenuBarItems()
    }

    private func menuBarMetricRow(index idx: Int, item: MenuBarItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.metric.glyph).font(.system(size: 11))
                .foregroundStyle(Brand.textSecondary).frame(width: 16)
            Text(item.metric.title).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
            Text(item.resolvedStyle.title).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
            Spacer(minLength: 6)
            Button { moveMenuBarItem(idx, by: -1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.textTertiary)
            }
            .buttonStyle(.plain).disabled(idx == 0).accessibilityLabel(NSLocalizedString("Move up", comment: ""))
            Button { moveMenuBarItem(idx, by: 1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.textTertiary)
            }
            .buttonStyle(.plain).disabled(idx == menuBarItems.count - 1).accessibilityLabel(NSLocalizedString("Move down", comment: ""))
            Button {
                expandedMenuBarItem = (expandedMenuBarItem == item.id) ? nil : item.id
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundStyle(expandedMenuBarItem == item.id ? Brand.green : Brand.textTertiary)
            }
            .buttonStyle(.plain).accessibilityLabel(NSLocalizedString("Options", comment: ""))
            Button { removeMenuBarItem(idx) } label: {
                Image(systemName: "minus.circle.fill").font(.system(size: 12)).foregroundStyle(Brand.textTertiary)
            }
            .buttonStyle(.plain).accessibilityLabel(NSLocalizedString("Remove", comment: ""))
        }
    }

    /// The expanded per-widget options — style, colour, label/value toggles,
    /// and the style-specific extras (à la a desktop monitor's widget settings).
    @ViewBuilder
    private func menuBarItemOptions(index idx: Int, item: MenuBarItem) -> some View {
        let style = item.resolvedStyle
        VStack(spacing: 6) {
            optionPicker("Style", value: style.title) {
                ForEach(item.metric.styles) { st in
                    Button(st.title) { updateMenuBarItem(idx) { $0.style = st } }
                }
            }
            optionPicker("Color", value: item.color.title) {
                ForEach(item.metric.colorModes) { c in
                    Button(c.title) { updateMenuBarItem(idx) { $0.color = c } }
                }
            }
            optionPicker("Text size", value: item.textSize.title) {
                ForEach(MenuBarTextSize.allCases) { s in
                    Button(s.title) { updateMenuBarItem(idx) { $0.textSize = s } }
                }
            }
            if style == .bar || style == .sparkline || style == .speed || style == .battery {
                optionToggle("Show label", isOn: item.showLabel) { updateMenuBarItem(idx) { $0.showLabel.toggle() } }
            }
            if style == .bar || style == .sparkline || style == .battery {
                optionToggle("Show value", isOn: item.showValue) { updateMenuBarItem(idx) { $0.showValue.toggle() } }
            }
            if style == .sparkline {
                optionToggle("Filled", isOn: item.fill) { updateMenuBarItem(idx) { $0.fill.toggle() } }
                optionPicker("History", value: "\(item.historyPoints)") {
                    ForEach([30, 60, 90, 120], id: \.self) { n in
                        Button("\(n)") { updateMenuBarItem(idx) { $0.historyPoints = n } }
                    }
                }
            }
            if style == .speed {
                optionPicker("Indicator", value: item.pictogram.title) {
                    ForEach(SpeedPictogram.allCases) { p in
                        Button(p.title) { updateMenuBarItem(idx) { $0.pictogram = p } }
                    }
                }
                optionToggle("Units", isOn: item.showUnits) { updateMenuBarItem(idx) { $0.showUnits.toggle() } }
            }
        }
    }

    /// Settings sub-row: title on the left, a borderless menu on the right.
    private func optionPicker<C: View>(_ label: String, value: String, @ViewBuilder _ menu: () -> C) -> some View {
        HStack {
            Text(NSLocalizedString(label, comment: "")).font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
            Spacer()
            Menu { menu() } label: {
                Text(value).font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    /// Settings sub-row: title on the left, a compact switch on the right.
    private func optionToggle(_ label: String, isOn: Bool, _ toggle: @escaping () -> Void) -> some View {
        HStack {
            Text(NSLocalizedString(label, comment: "")).font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in toggle() }))
                .labelsHidden().toggleStyle(.switch).tint(Brand.green).controlSize(.mini)
        }
    }

    private func updateMenuBarItem(_ idx: Int, _ mutate: (inout MenuBarItem) -> Void) {
        guard menuBarItems.indices.contains(idx) else { return }
        mutate(&menuBarItems[idx]); commitMenuBarItems()
    }

    private func addMenuBarMetric(_ m: MenuBarMetric) {
        menuBarItems.append(MenuBarItem(metric: m, style: m.styles.first ?? .value, color: m.defaultColor))
        commitMenuBarItems()
    }

    private func moveMenuBarItem(_ idx: Int, by delta: Int) {
        let j = idx + delta
        guard menuBarItems.indices.contains(j) else { return }
        menuBarItems.swapAt(idx, j); commitMenuBarItems()
    }

    private func removeMenuBarItem(_ idx: Int) {
        guard menuBarItems.indices.contains(idx) else { return }
        if expandedMenuBarItem == menuBarItems[idx].id { expandedMenuBarItem = nil }
        menuBarItems.remove(at: idx); commitMenuBarItems()
    }

    /// Persist + re-render the status item (applyMenuBarVisibility re-runs the
    /// display mode when the icon is shown).
    private func commitMenuBarItems() {
        Store.menuBarItems = menuBarItems
        AppDelegate.shared?.applyMenuBarVisibility(Store.showMenuBarIcon)
    }

    // MARK: - Popup contents editor (issue #82)

    @ViewBuilder
    private var popupContentsEditor: some View {
        VStack(spacing: 6) {
            ForEach(PopupSection.allCases) { sec in
                popupToggle(sec.title, on: popupSections.contains(sec)) {
                    if popupSections.contains(sec) { popupSections.remove(sec) } else { popupSections.insert(sec) }
                    Store.popupSections = popupSections
                }
            }
            Rectangle().fill(Brand.hairline).frame(height: 1).padding(.vertical, 2)
            subLabel("Metric tiles")
            ForEach(MenuBarMetric.popupGrid) { m in
                popupToggle(m.title, on: popupTiles.contains(m)) {
                    if popupTiles.contains(m) { popupTiles.remove(m) } else { popupTiles.insert(m) }
                    Store.popupTiles = popupTiles
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func popupToggle(_ label: String, on: Bool, _ toggle: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { _ in toggle() }))
                .labelsHidden().toggleStyle(.switch).tint(Brand.green).controlSize(.small)
        }
    }

    // MARK: - Animated runner editor (RunCat-style)

    @ViewBuilder
    private var runnerEditor: some View {
        VStack(spacing: 8) {
            HStack {
                Text(NSLocalizedString("Animation", comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                Spacer()
                Menu {
                    ForEach(RunnerCatalog.all) { b in
                        Button(b.title) { setRunnerSource(.builtIn(b.id)) }
                    }
                    Divider()
                    Button(NSLocalizedString("Choose GIF…", comment: "")) { importRunnerGIF() }
                } label: {
                    Text(runnerSourceLabel).font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            HStack {
                Text(NSLocalizedString("Speed tracks", comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                Spacer()
                Menu {
                    ForEach(MenuBarMetric.allCases) { m in
                        Button(m.title) { runnerConfig.metric = m; commitRunner() }
                    }
                } label: {
                    Text(runnerConfig.metric.title).font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            HStack {
                Text(NSLocalizedString("Sensitivity", comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
                Spacer()
                Slider(value: Binding(get: { runnerConfig.sensitivity },
                                      set: { runnerConfig.sensitivity = $0; commitRunner() }), in: 0.5...2.0)
                    .frame(width: 160).tint(Brand.green)
            }
            popupToggle(NSLocalizedString("Show value next to runner", comment: ""), on: runnerConfig.showValue) {
                runnerConfig.showValue.toggle(); commitRunner()
            }
            popupToggle(NSLocalizedString("Before widgets (in Metrics mode)", comment: ""), on: runnerConfig.prependToRow) {
                runnerConfig.prependToRow.toggle(); commitRunner()
            }
            footnote("Built-in animations are drawn by Burrow; \u{201C}Choose GIF…\u{201D} plays your own. Speed scales with the chosen metric — busier is faster.")
        }
        .padding(.vertical, 2)
    }

    private var runnerSourceLabel: String {
        switch runnerConfig.source {
        case .builtIn(let id): return RunnerCatalog.all.first { $0.id == id }?.title ?? id
        case .gif:             return NSLocalizedString("Custom GIF", comment: "")
        }
    }

    private func setRunnerSource(_ s: RunnerSource) { runnerConfig.source = s; commitRunner() }

    /// Pick a GIF and copy it into App Support. The picker blocks the main
    /// thread by design, so pause the app-hang monitor for its duration.
    private func importRunnerGIF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let resp = CrashReporter.withoutAppHangTracking { panel.runModal() }
        guard resp == .OK, let url = panel.url, let stored = RunnerGIF.importGIF(from: url) else { return }
        runnerConfig.source = .gif(stored)
        commitRunner()
    }

    private func commitRunner() {
        Store.runnerConfig = runnerConfig
        AppDelegate.shared?.applyMenuBarVisibility(Store.showMenuBarIcon)
    }

    // MARK: - Status labels

    private func refreshStatusLabels() {
        // The maintenance label is cheap (in-memory) — set it synchronously.
        if let last = AppDelegate.shared?.maintenance?.lastRunAt {
            let delta = Int(Date().timeIntervalSince(last))
            self.lastMaintenanceText = String(format: NSLocalizedString("%ds ago · pruned %d rows", comment: ""),
                                              delta, AppDelegate.shared?.maintenance?.lastPruneDeleted ?? 0)
        } else {
            self.lastMaintenanceText = NSLocalizedString("not yet run", comment: "")
        }
        // Sizing the support dir walks every file under it (the metrics SQLite
        // store grows large over time) — off the main thread so opening
        // Settings can't hang on a deep enumeration (App-Hang).
        DispatchQueue.global(qos: .utility).async {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
                .appendingPathComponent("Burrow", isDirectory: true)
            var total: Int64 = 0
            if let enumerator = FileManager.default.enumerator(at: support,
                                                               includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in enumerator {
                    if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                        total += Int64(size)
                    }
                }
            }
            let text = Fmt.bytes(total)
            DispatchQueue.main.async { self.dbSizeText = text }
        }
    }
}
