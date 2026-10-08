//
//  AppDelegate.swift
//  Burrow
//
//  Launch order (matters):
//
//    1. Verify `mo` is on PATH. Hard requirement — if missing, modal
//       alert with the install command, then quit.
//    2. Open the SQLite history DB.
//    3. Start QueryServer (Store-gated).
//    4. Start SnapshotProducer (Store-configured cadence).
//    5. Start Maintenance (hourly prune).
//    6. Install the NSStatusItem.
//
//  Windows: v0.3 collapsed the four separate windows (History,
//  DiskMap, Cleanup, Settings) into one main window with a sidebar.
//  `openMainWindow(initial:)` is the one entry point — the popover's
//  action buttons just deep-link by passing the section they want
//  selected.
//

import Cocoa
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Singleton handle so SwiftUI views can reach the live
    /// Maintenance / SnapshotProducer / DB without threading them through every
    /// initializer.
    static private(set) var shared: AppDelegate?

    private(set) var db: DB?
    private(set) var producer: SnapshotProducer?
    private(set) var maintenance: Maintenance?
    private var queryServer: QueryServer?
    private var statusBar: StatusBarController?
    /// Dev/verify only: standalone window hosting the HUD (BURROW_OPEN_ON_LAUNCH=hud).
    private var hudPreview: NSWindow?

    /// The one feed hub (issue #53): shared, demand-counted pumps keyed by
    /// query — views bind to feeds instead of owning timers.
    let feeds = FeedHub()

    /// Single main window. Holds the sidebar + content router.
    private var mainWC: NSWindowController?

    private var installWC: NSWindowController?
    private var onboardingWC: NSWindowController?
    private let launchJournal = LaunchJournal.live
    private let runtimeEnvironment = RuntimeEnvironment.current
    private var lastLaunch: LaunchRecord?
    private var previousIncompleteLaunch: LaunchRecord?
    private var recoveryReason: LaunchRecoveryReason?
    private var updaterRecoveryReason: LaunchRecoveryReason?
    private var safeModeActive = false
    /// True while the compatibility guard is suppressing the menu-bar item on
    /// this macOS build. Settings reads it so the "Show menu bar icon" toggle
    /// can say what is actually happening rather than flipping on and quietly
    /// doing nothing (#319).
    var menuBarSuppressedByCompatibilityGuard: Bool { recoveryReason != nil }

    /// Why the menu-bar item is paused, so Settings can say something true.
    /// The two reasons need different advice: only the macOS-build guard is
    /// fixed by updating macOS.
    var menuBarSuppressionReason: LaunchRecoveryReason? { recoveryReason }
    private var recoveryNoticePresented = false
    private var launchCompleted = false
    private var initialStatusItemCreationTask: Task<Void, Never>?
    private var statusItemStabilityTask: Task<Void, Never>?
    private var statusItemStabilityGeneration = 0
    private var statusItemStabilitySpan: DiagnosticSpan?
    private var automaticUpdaterStartTask: Task<Void, Never>?
    private var automaticUpdaterSchedulingArmed = false
    private var databaseOpenInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Under XCTest this process is only a TEST_HOST shell. Starting the
        // real services would bind the query port, spawn `mo`, fire telemetry,
        // and let the maintenance timer prune the developer's real history DB
        // mid-suite. Stay inert; tests construct exactly what they need.
        if Foundation.ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        lastLaunch = launchJournal.lastRecord()
        previousIncompleteLaunch = launchJournal.begin(environment: runtimeEnvironment)
        recoveryReason = LaunchRecovery.reason(environment: runtimeEnvironment, previous: lastLaunch)

        // Move 0.10.5's update settings before Sparkle's controller is ever
        // constructed, so it sees both the opt-out and last-check timestamp
        // on its first 0.11 launch.
        _ = Store.migrateLegacyUpdatePreferences()
        if Store.autoCheckForUpdates {
            updaterRecoveryReason = AutomaticUpdateRecovery.reason(
                environment: runtimeEnvironment,
                previous: lastLaunch
            )
        }

        // (BURROW_ENGINE_DIR used to be exported here, pointing the bundled conductor at a
        // separate bundled engine. The repoint collapsed those two binaries into one, so
        // there is no second directory to point at and `BurrowEngine.engineDir()` is gone.)

        // Product analytics + crash reporting (PostHog + Sentry). Opt-out, on
        // by default, and inert without release-injected keys. Started before
        // the `mo` gate so a launch with the engine missing still counts.
        Telemetry.start()
        CrashReporter.startLaunchTrace()
        CrashReporter.setLaunchPhase(.launchStarted)
        CrashReporter.setStatusItemState(.notRequested)
        markLaunch(.telemetryStarted)
        recordPriorLaunchDiagnostics()

        // No engine yet → guided install instead of a dead-end quit. The
        // window's Recheck calls startServices() once `mo` is found.
        //
        // Discovery can shell out to `which mo` (EngineCLI.discover) when mo
        // isn't in a trusted Homebrew path — a blocking Process wait that must
        // never run on the main thread at launch (issue #72 / Sentry BURROW-1:
        // a ~2 s+ app-hang on cold launch). Probe off-main, then gate startup
        // back on the main thread. The brief window with no UI is fine; the
        // status item / install window appear a beat later instead of after a
        // freeze.
        markLaunch(.engineProbeStarted)
        let engineProbeSpan = CrashReporter.startLaunchSpan("engine_probe")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = EngineCLI.findExecutable() != nil
            engineProbeSpan?.finish()
            DispatchQueue.main.async {
                guard let self else { return }
                self.markLaunch(.engineProbeFinished)
                if found {
                    self.startServices()
                } else {
                    Telemetry.capture("engine_missing")
                    self.showInstallWindow()
                }
            }
        }
    }

    /// Guided onboarding window when `mo` is missing. Stays a regular Dock
    /// app so the window is reachable; we never run an installer ourselves.
    private func showInstallWindow() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            // Sized with the interface text scale so larger type doesn't clip
            // in a fixed, non-resizable frame.
            contentRect: NSRect(x: 0, y: 0, width: Brand.scaled(460), height: Brand.scaled(320)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        let view = MoleInstallView(onReady: { [weak self] in
            self?.installWC?.close()
            self?.installWC = nil
            self?.startServices()
        })
        window.contentViewController = NSHostingController(rootView: view)
        let wc = NSWindowController(window: window)
        self.installWC = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        markLaunch(.installWindowReady)
        CrashReporter.finishLaunchTrace()
        Telemetry.capture("install_window_ready")
    }

    /// The `mo`-dependent startup: open the DB, start the server/sampler/
    /// maintenance, and install the status item. Called either directly at
    /// launch or after the guided install finds `mo`.
    private func startServices() {
        // A second call while an open is in flight (a double Recheck) would
        // run two opens, and two recovery ladders, against one file.
        guard !databaseOpenInFlight else { return }
        databaseOpenInFlight = true
        markLaunch(.databaseOpening)
        let databaseSpan = CrashReporter.startLaunchSpan("database_open")
        // Off the main thread: opening can replay a WAL left by an unclean
        // quit, wait on another Burrow process's lock (up to 2 s a
        // statement), or run the repair ladder. On the main thread that is a
        // frozen app (Sentry BURROW-AP, an App-Hang in `database_opening`).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try DB.openDefaultWaitingOutContention() }
            DispatchQueue.main.async {
                databaseSpan?.finish()
                guard let self else { return }
                self.databaseOpenInFlight = false
                switch result {
                case .success(let db):
                    self.startServices(with: db)
                case .failure(let error):
                    self.databaseOpenFailed(error)
                }
            }
        }
    }

    private func databaseOpenFailed(_ error: Error) {
        CrashReporter.logError("database_open_failed", data: [
            "error_domain": (error as NSError).domain,
            "error_code": (error as NSError).code,
        ])
        CrashReporter.captureDiagnostic("database_open_failed", error: error)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Couldn't open Burrow's history database", comment: "")
        alert.informativeText = String(format: NSLocalizedString("%@\n\nThe app will quit.", comment: ""),
                                       error.localizedDescription)
        alert.alertStyle = .critical
        alert.runModalQuiet()
        CrashReporter.finishLaunchTrace()
        NSApp.terminate(nil)
    }

    /// The rest of startup, once the history DB is open.
    private func startServices(with db: DB) {
        markLaunch(.databaseReady)
        self.db = db

        if Store.queryServerEnabled {
            let port = UInt16(clamping: Store.queryServerPort)
            self.queryServer = QueryServer(db: db, port: port)
            self.queryServer?.start()
        }

        // One engine for everything metric-shaped: the periodic `mo status`
        // snapshot (patched, persisted, published) AND the 1 s live net/disk
        // feed for tiles and charts. See SnapshotProducer.swift.
        let producer = SnapshotProducer(deps: .live(db: db))
        self.producer = producer
        producer.start()

        let maintenance = Maintenance(db: db)
        self.maintenance = maintenance
        maintenance.start()
        markLaunch(.servicesStarted)

        // Completion notices + opt-in smart reminders. The delegate must
        // be set before any notification is delivered or clicked.
        // startReminders() also requests notification permission up front
        // (when a notifying feature is on) so the grant is settled at launch,
        // not mid-notification. (Main-actor hop: the notifier is @MainActor,
        // this delegate callback isn't.)
        Task { @MainActor in
            UNUserNotificationCenter.current().delegate = BurrowNotifier.shared
            BurrowNotifier.shared.startReminders()
        }

        safeModeActive = Store.showMenuBarIcon && recoveryReason != nil
        if StatusItemStartupPolicy.shouldScheduleInitialCreation(
            showMenuBarIcon: Store.showMenuBarIcon,
            recoveryReason: recoveryReason
        ) {
            scheduleInitialStatusItemCreation(db: db, producer: producer)
        } else if safeModeActive, let recoveryReason {
            CrashReporter.setStatusItemState(.compatibilityMode)
            NSApp.setActivationPolicy(.regular)
            let properties: [String: Any] = [
                "reason": recoveryReason.rawValue,
                "os_build": runtimeEnvironment.osBuild,
                "menu_bar_mode": Store.menuBarDisplayMode.rawValue,
            ]
            Telemetry.capture("compatibility_fallback_activated", properties)
            CrashReporter.logWarning("compatibility_fallback_activated", data: properties)
        } else {
            CrashReporter.setStatusItemState(.notRequested)
        }
        self.setupMainMenu()

        // Sparkle is the only new launch-time component in 0.11. Its automatic
        // start is armed here but cannot run until the status item has survived
        // its full 30-second responsive window. That separation lets the local
        // journal identify which component preceded a freeze and suppress only
        // the automatic updater after an updater-specific failure. Manual
        // checks remain available; downloads and installs remain user-driven.
        armAutomaticUpdaterIfNeeded()

        // Crash safety for the Clean review's whitelist session: a fenced
        // block left by a previous run must never outlive it.
        DispatchQueue.global(qos: .utility).async { try? MoleWhitelist.live.endSession() }

        // Global shortcuts (recorded in Settings ▸ Menu Bar).
        HotKeyCenter.shared.handlers[.openBurrow] = { [weak self] in
            guard #available(macOS 14, *) else { return }
            if let window = self?.mainWC?.window, window.isVisible, NSApp.isActive {
                window.performClose(nil)
            } else {
                self?.openMainWindow(initial: .home)
            }
        }
        HotKeyCenter.shared.handlers[.keepScreenOn] = {
            Awake.shared.isActive ? Awake.shared.stop() : Awake.shared.start(.untilOff)
        }
        HotKeyCenter.shared.handlers[.cleanScreen] = { CleanScreen.shared.toggle() }
        HotKeyCenter.shared.applyAll()

        // First run (after the mo gate — MoleInstallView is slide 0): the
        // two onboarding slides, once. Finishing sets the flag; closing the
        // window without finishing shows it again next launch. The dev
        // open-on-launch affordance below bypasses it (BURROW_OPEN_ON_LAUNCH
        // targets a specific pane; "onboarding" targets these slides).
        let devLaunchTab = Foundation.ProcessInfo.processInfo.environment["BURROW_OPEN_ON_LAUNCH"]
        if (devLaunchTab == nil && !Store.onboardingCompleted) || devLaunchTab == "onboarding",
           #available(macOS 14, *) {
            self.showOnboardingWindow()
            completeLaunch(presentRecoveryNotice: false)
            return
        }

        // Without the menu-bar icon there's no agent entry point (the app is
        // LSUIElement, so no Dock icon either). Run as a regular Dock app and
        // open the window on launch so it stays reachable (issue #4).
        if (!Store.showMenuBarIcon || safeModeActive), #available(macOS 14, *) {
            NSApp.setActivationPolicy(.regular)
            self.openMainWindow(initial: .home)
        }

        // Dev affordance: launch with BURROW_OPEN_ON_LAUNCH=1 to pop the
        // main window straight away (used for screenshot/verify loops).
        if let tab = devLaunchTab,
           #available(macOS 14, *) {
            if tab == "hud" {
                // Dev/verify: render the HUD content in a normal window so it can
                // be screenshotted (the real popover needs a menu-bar click).
                let host = NSHostingView(rootView: PopupView(db: db, live: producer.live,
                                                             feeds: self.feeds, delegate: self))
                let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Brand.scaled(334), height: 720),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
                win.title = "HUD Preview (dev)"
                win.contentView = host
                win.setContentSize(host.fittingSize)
                win.center()
                NSApp.setActivationPolicy(.regular)
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.hudPreview = win
            } else {
                let pane: Pane
                if tab == "settings" { pane = .settings }
                else if tab == "home" || tab == "status" || tab == "history" || tab == "activity" { pane = .home }
                else if let tool = Tool(rawValue: tab), Tool.navOrder.contains(tool) { pane = .tool(tool) }
                else { pane = .home }
                self.openMainWindow(initial: pane)
            }
        }
        completeLaunch(presentRecoveryNotice: safeModeActive || updaterRecoveryReason != nil)
    }

    /// Settings ▸ General ▸ "Replay onboarding": clear the seen flag and
    /// present the slides again right away — the same window path as first
    /// run, so finishing them re-sets the flag and lands on Home.
    @available(macOS 14, *)
    func replayOnboarding() {
        Store.onboardingCompleted = false
        if let wc = onboardingWC {
            wc.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        showOnboardingWindow()
    }

    /// First-run onboarding window: plain chrome, traffic lights only.
    /// Finishing marks onboarding complete and opens the main window.
    @available(macOS 14, *)
    private func showOnboardingWindow() {
        // Engine gate, restated at the onboarding door: the launch path
        // already checks `mo` before startServices(), but onboarding can
        // also be forced (BURROW_OPEN_ON_LAUNCH=onboarding) and the engine
        // can vanish between gate and slides. The slides assume a working
        // engine, so route into the guided install instead — its Recheck
        // re-enters startServices() and lands back here.
        guard EngineCLI.findExecutable() != nil else {
            showInstallWindow()
            return
        }
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            // Sized with the interface text scale so larger type doesn't clip
            // in a fixed, non-resizable frame.
            contentRect: NSRect(x: 0, y: 0, width: Brand.scaled(720), height: Brand.scaled(560)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        let view = OnboardingView(onFinish: { [weak self] in
            Store.onboardingCompleted = true
            Telemetry.capture("onboarding_completed")
            // Settle notification permission now the user has finished setup —
            // up front, before any completion notice or reminder needs it.
            // (Hop to the main actor: the notifier is @MainActor, this
            // SwiftUI callback isn't isolated.)
            Task { @MainActor in BurrowNotifier.shared.requestAuthorizationForEnabledFeatures() }
            self?.onboardingWC?.close()
            self?.onboardingWC = nil
            self?.openMainWindow(initial: .home)
            self?.presentRecoveryNoticeIfNeeded()
        })
        window.contentViewController = NSHostingController(rootView: view)
        let wc = NSWindowController(window: window)
        self.onboardingWC = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        initialStatusItemCreationTask?.cancel()
        initialStatusItemCreationTask = nil
        statusItemStabilityTask?.cancel()
        statusItemStabilityTask = nil
        statusItemStabilitySpan?.finish()
        statusItemStabilitySpan = nil
        automaticUpdaterStartTask?.cancel()
        automaticUpdaterStartTask = nil
        self.producer?.stop()
        self.queryServer?.stop()
        self.maintenance?.stop()
        Awake.shared.stop()
        CleanScreen.shared.hide()
        Telemetry.capture("app_terminated")
        Telemetry.flush()
        CrashReporter.finishLaunchTrace()
        launchJournal.mark(.terminatedNormally)
        CrashReporter.setLaunchPhase(.terminatedNormally)
        // Final flush so any just-changed setting survives an app replacement
        // during an update.
        UserDefaults.standard.synchronize()
    }

    // MARK: - Window

    /// Open the main window, focusing the requested section. If the
    /// window already exists, just selects the section and brings the
    /// window forward. Used by every popover action button —
    /// `openMainWindow(initial: .cleanup)` etc.
    @available(macOS 14.0, *)
    func openMainWindow(initial: Pane = .home) {
        // If already open, just switch to the requested pane and bring the
        // window forward. NEVER reinstall the content view here — that
        // would discard live tool state (a running clean's report, scan
        // caches, purge selections) and orphan the old hosting tree's
        // timers; the live RootView switches itself on the notification.
        if let wc = self.mainWC, let window = wc.window {
            NotificationCenter.default.post(name: .burrowSelectPane, object: initial)
            NotificationCenter.default.post(name: .burrowWindowVisibility, object: true)
            NSApp.setActivationPolicy(.regular)   // Dock icon while open
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard self.db != nil, self.producer != nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // Frameless-feeling translucent shell: transparent titlebar with
        // the traffic lights floating over content, a clear non-opaque
        // window so the behind-window vibrancy can sample the wallpaper,
        // and drag-anywhere so there's no visible chrome bar.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = NSLocalizedString("Burrow", comment: "")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        // Derived from the rail's own height — see WindowMetrics. The window
        // uses fullSizeContentView, so the frame minimum IS the content
        // minimum; there is no title bar to subtract.
        window.minSize = NSSize(width: WindowMetrics.minimumSize.width,
                                height: WindowMetrics.minimumSize.height)
        window.delegate = self

        // Show a Dock icon (and Cmd-Tab presence) while the dashboard is
        // open; we drop back to a pure menu-bar agent when it closes. The
        // icon itself comes from Assets.xcassets/AppIcon.
        NSApp.setActivationPolicy(.regular)

        let wc = NSWindowController(window: window)
        self.mainWC = wc
        self.installMainContent(into: window, initial: initial)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Bring Burrow forward without forcing a pane switch — notification
    /// clicks land here so a completion notice doesn't navigate away from
    /// the finished run's receipt. Reopens the main window only when
    /// nothing is visible.
    @available(macOS 14.0, *)
    func bringForward() {
        if mainWC?.window?.isVisible == true {
            NSApp.setActivationPolicy(.regular)
            mainWC?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openMainWindow(initial: .home)
        }
    }

    @available(macOS 14.0, *)
    private func installMainContent(into window: NSWindow, initial: Pane) {
        guard let db = self.db, let producer = self.producer else { return }
        let root = RootView(db: db, producer: producer, feeds: feeds, delegate: self, initialPane: initial)
        let host = NSHostingController(rootView: root)
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        window.contentViewController = host
    }

    // MARK: - Window delegate

    func windowWillClose(_ notification: Notification) {
        // Retreat to a pure menu-bar agent only when the menu-bar icon is
        // the actual entry point — keyed off what we installed at launch,
        // not the live Store value (which a mid-session toggle could change
        // before a relaunch, stranding the app). With no status item, keep
        // the Dock icon so the app stays reachable (issue #4). "Hide Dock
        // Icon" off (Settings ▸ General) keeps the Dock presence too.
        if statusBar != nil, Store.hideDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
        // No live chart on screen → drop back to the idle sample cadence,
        // and tell the kept-alive content to park its polling timers.
        self.producer?.setForeground(false)
        NotificationCenter.default.post(name: .burrowWindowVisibility, object: false)
    }

    /// Clicking the Dock icon (menu-bar-disabled mode) reopens the window.
    /// When windows are already visible we return false so AppKit performs
    /// its default raise-windows behaviour rather than us suppressing it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return false }
        // Services never started (mo still missing): the main window can't
        // exist, so bring back the guided installer instead of leaving a
        // Dock icon whose clicks do nothing.
        if self.db == nil {
            if let wc = self.installWC {
                wc.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                self.showInstallWindow()
            }
            return true
        }
        if #available(macOS 14, *) { self.openMainWindow(initial: .home) }
        return true
    }

    // MARK: - Menu-bar visibility (live)

    /// Apply the "Show menu bar icon" setting immediately, without a relaunch.
    /// Installs/removes the status item, and when hiding it keeps a Dock
    /// presence + an open window so the app never becomes unreachable.
    func applyMenuBarVisibility(_ show: Bool) {
        guard let db = db, let producer = producer else { return }
        if show {
            if recoveryReason != nil {
                safeModeActive = true
                CrashReporter.setStatusItemState(.compatibilityMode)
                NSApp.setActivationPolicy(.regular)
                if #available(macOS 14, *), mainWC?.window?.isVisible != true {
                    openMainWindow(initial: .home)
                }
                Telemetry.capture("compatibility_fallback_reaffirmed", [
                    "reason": recoveryReason?.rawValue ?? "unknown",
                    "os_build": runtimeEnvironment.osBuild,
                    "menu_bar_mode": Store.menuBarDisplayMode.rawValue,
                ])
                presentRecoveryNoticeIfNeeded()
                return
            }
            if statusBar == nil, initialStatusItemCreationTask == nil {
                createStatusItem(db: db, producer: producer, source: "settings")
            } else {
                statusBar?.applyDisplayMode()   // Icon ↔ Metrics flip
            }
        } else {
            cancelStatusItemStabilityMarker(state: .disabled)
            statusBar = nil   // StatusBarController.deinit removes the item
            if #available(macOS 14, *) {
                NSApp.setActivationPolicy(.regular)
                // mainWC is retained (isReleasedWhenClosed = false), so its
                // window is non-nil even when closed — check visibility, not nil,
                // so hiding the menu bar always leaves a visible window.
                if mainWC?.window?.isVisible != true { openMainWindow(initial: .home) }
            }
        }
    }

    // MARK: - Launch recovery

    private func markLaunch(_ phase: LaunchPhase) {
        launchJournal.mark(phase)
        CrashReporter.setLaunchPhase(phase)
    }

    private func scheduleInitialStatusItemCreation(db: DB, producer: SnapshotProducer) {
        initialStatusItemCreationTask?.cancel()
        CrashReporter.setStatusItemState(.scheduled)
        Telemetry.capture("status_item_creation_scheduled", ["source": "launch"])
        initialStatusItemCreationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: StatusItemStartupPolicy.initialDelayNanoseconds
                )
            } catch {
                return
            }
            guard let self else { return }
            self.initialStatusItemCreationTask = nil
            guard Store.showMenuBarIcon,
                  self.recoveryReason == nil,
                  self.statusBar == nil else {
                if self.launchCompleted { CrashReporter.finishLaunchTrace() }
                return
            }
            self.createStatusItem(db: db, producer: producer, source: "launch")
        }
    }

    private func createStatusItem(
        db: DB,
        producer: SnapshotProducer,
        source: String
    ) {
        markLaunch(.statusItemCreating)
        let statusItemSpan = CrashReporter.startLaunchSpan("status_item_create")
        statusBar = StatusBarController(db: db, producer: producer, delegate: self)
        statusItemSpan?.finish()
        markLaunch(.statusItemReady)
        scheduleStatusItemStabilityMarker(source: source)
    }

    private func scheduleStatusItemStabilityMarker(source: String) {
        statusItemStabilityTask?.cancel()
        statusItemStabilitySpan?.finish()
        if automaticUpdaterSchedulingArmed {
            // A new AppKit stability window supersedes the menu-bar-disabled
            // quiet period. Sparkle must wait until this item proves stable.
            automaticUpdaterStartTask?.cancel()
            automaticUpdaterStartTask = nil
        }
        statusItemStabilityGeneration += 1
        let generation = statusItemStabilityGeneration
        statusItemStabilitySpan = CrashReporter.startLaunchSpan("status_item_stabilizing")
        CrashReporter.setStatusItemState(.stabilizing)
        Telemetry.capture("status_item_stability_started", ["source": source])

        statusItemStabilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self,
                  self.statusItemStabilityGeneration == generation,
                  self.statusBar != nil,
                  self.recoveryReason == nil,
                  !Task.isCancelled else { return }
            self.statusItemStabilityTask = nil
            self.launchJournal.markStatusItemStable()
            self.statusItemStabilitySpan?.finish()
            self.statusItemStabilitySpan = nil
            CrashReporter.setStatusItemState(.stable)
            CrashReporter.breadcrumb("status_item_stable", category: "launch")
            Telemetry.capture("status_item_stabilized", ["source": source])
            if self.launchCompleted { CrashReporter.finishLaunchTrace() }
            if self.automaticUpdaterSchedulingArmed {
                self.scheduleAutomaticUpdaterStart(afterNanoseconds: 0)
            }
        }
    }

    private func cancelStatusItemStabilityMarker(state: StatusItemDiagnosticState) {
        initialStatusItemCreationTask?.cancel()
        initialStatusItemCreationTask = nil
        statusItemStabilityGeneration += 1
        statusItemStabilityTask?.cancel()
        statusItemStabilityTask = nil
        statusItemStabilitySpan?.finish()
        statusItemStabilitySpan = nil
        if state == .disabled { launchJournal.markStatusItemDisabled() }
        CrashReporter.setStatusItemState(state)
        if launchCompleted { CrashReporter.finishLaunchTrace() }
        if automaticUpdaterSchedulingArmed {
            // A user removing the item during its guard window is not proof of
            // stability. Give the updater its own fresh quiet window instead
            // of starting it on the same run-loop turn.
            scheduleAutomaticUpdaterStart(afterNanoseconds: 30_000_000_000)
        }
    }

    private func armAutomaticUpdaterIfNeeded() {
        guard Store.autoCheckForUpdates else { return }
        if let reason = recoveryReason ?? updaterRecoveryReason {
            let properties: [String: Any] = [
                "reason": reason.rawValue,
                "os_build": runtimeEnvironment.osBuild,
                "app_build": runtimeEnvironment.appBuild,
            ]
            Telemetry.capture("automatic_updater_suppressed", properties)
            CrashReporter.logWarning("automatic_updater_suppressed", data: properties)
            return
        }

        automaticUpdaterSchedulingArmed = true
        if statusItemStabilityTask == nil {
            // Menu-bar-disabled launches have no AppKit marker to release the
            // gate, so give the rest of startup the same 30-second quiet window.
            scheduleAutomaticUpdaterStart(afterNanoseconds: 30_000_000_000)
        }
    }

    private func scheduleAutomaticUpdaterStart(afterNanoseconds delay: UInt64) {
        guard automaticUpdaterSchedulingArmed else { return }
        automaticUpdaterStartTask?.cancel()
        automaticUpdaterStartTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, !Task.isCancelled else { return }
            self.automaticUpdaterStartTask = nil
            guard self.automaticUpdaterSchedulingArmed, Store.autoCheckForUpdates else {
                self.automaticUpdaterSchedulingArmed = false
                return
            }
            self.automaticUpdaterSchedulingArmed = false

            AppUpdate.shared.begin()
        }
    }

    private func completeLaunch(presentRecoveryNotice: Bool) {
        guard !launchCompleted else { return }
        launchCompleted = true
        markLaunch(.appReady)
        // A menu-bar launch is not considered healthy until AppKit's status
        // item has survived 30 responsive seconds. Its child span and separate
        // status_item_state tag remain live across this app_ready phase.
        if statusItemStabilityTask == nil, initialStatusItemCreationTask == nil {
            CrashReporter.finishLaunchTrace()
        }
        let statusItemState: String
        if safeModeActive {
            statusItemState = StatusItemDiagnosticState.compatibilityMode.rawValue
        } else if initialStatusItemCreationTask != nil {
            statusItemState = StatusItemDiagnosticState.scheduled.rawValue
        } else if statusBar == nil {
            statusItemState = StatusItemDiagnosticState.notRequested.rawValue
        } else {
            statusItemState = StatusItemDiagnosticState.stabilizing.rawValue
        }
        Telemetry.capture("app_ready", [
            "menu_bar_available": statusBar != nil,
            "compatibility_mode": safeModeActive,
            "status_item_state": statusItemState,
        ])
        if presentRecoveryNotice {
            DispatchQueue.main.async { [weak self] in self?.presentRecoveryNoticeIfNeeded() }
        }
    }

    private func recordPriorLaunchDiagnostics() {
        if let previousIncompleteLaunch {
            let properties: [String: Any] = [
                "last_phase": previousIncompleteLaunch.phase.rawValue,
                "elapsed_bucket": DiagnosticPrivacy.elapsedBucket(for: previousIncompleteLaunch),
                "previous_app_version": previousIncompleteLaunch.environment.appVersion,
                "previous_app_build": previousIncompleteLaunch.environment.appBuild,
                "previous_os_build": previousIncompleteLaunch.environment.osBuild,
            ]
            Telemetry.capture("previous_launch_incomplete", properties)
            CrashReporter.logWarning("previous_launch_incomplete", data: properties)
        }

        if let lastLaunch,
           lastLaunch.environment.appVersion != runtimeEnvironment.appVersion
            || lastLaunch.environment.appBuild != runtimeEnvironment.appBuild {
            Telemetry.capture("app_updated", [
                "from_version": lastLaunch.environment.appVersion,
                "from_build": lastLaunch.environment.appBuild,
                "to_version": runtimeEnvironment.appVersion,
                "to_build": runtimeEnvironment.appBuild,
            ])
        }
    }

    private func presentRecoveryNoticeIfNeeded() {
        guard !recoveryNoticePresented,
              let activeReason = recoveryReason ?? updaterRecoveryReason else { return }
        let noticeKey: String
        if recoveryReason != nil {
            noticeKey = "\(runtimeEnvironment.osBuild)|status_item"
        } else {
            noticeKey = "\(runtimeEnvironment.osBuild)|\(runtimeEnvironment.appBuild)|updater"
        }
        guard Store.lastCompatibilityNoticeBuild != noticeKey else { return }
        recoveryNoticePresented = true
        Store.lastCompatibilityNoticeBuild = noticeKey

        let alert = NSAlert()
        if recoveryReason != nil {
            alert.messageText = NSLocalizedString("Burrow started in compatibility mode", comment: "")
            if Store.autoCheckForUpdates {
                alert.informativeText = NSLocalizedString(
                    "Burrow detected that creating its menu bar item could freeze this macOS build. The menu bar item and automatic update checks are paused on this build, and Burrow will stay available in the Dock. Manual update checks remain available. Updating macOS will automatically retry the normal mode.",
                    comment: ""
                )
            } else {
                alert.informativeText = NSLocalizedString(
                    "Burrow detected that creating its menu bar item could freeze this macOS build. The menu bar item is disabled on this build, and Burrow will stay available in the Dock. Updating macOS will automatically retry the normal menu bar mode.",
                    comment: ""
                )
            }
        } else {
            alert.messageText = NSLocalizedString("Burrow paused automatic update checks", comment: "")
            alert.informativeText = NSLocalizedString(
                "Burrow detected that its automatic updater did not reach a stable state on the previous launch. Automatic checks are paused for this app and macOS build so the same startup problem cannot repeat. You can still check manually; updating Burrow or macOS will retry automatic checks.",
                comment: ""
            )
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Copy Diagnostics", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
        if alert.runModalQuiet() == .alertFirstButtonReturn {
            let report = LaunchDiagnosticReport.make(
                reason: activeReason,
                previous: previousIncompleteLaunch ?? lastLaunch,
                current: runtimeEnvironment,
                menuBarMode: Store.menuBarDisplayMode.rawValue
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            Telemetry.capture("diagnostic_report_copied", ["reason": activeReason.rawValue])
        }
    }

    // MARK: - Main menu

    /// Minimal AppKit main menu — shows when the app is active (.regular,
    /// i.e. a window open). Gives a real ⌘, (Settings pane), proper Quit,
    /// and an Edit menu so text fields get cut/copy/paste/select-all.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let about = NSMenuItem(title: NSLocalizedString("About Burrow", comment: ""),
                               action: #selector(showAboutFromMenu), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        let updates = NSMenuItem(title: NSLocalizedString("Check for Updates…", comment: ""),
                                 action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
        updates.target = self
        appMenu.addItem(updates)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: NSLocalizedString("Settings…", comment: ""),
                                  action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Hide Burrow", comment: ""), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: NSLocalizedString("Quit Burrow", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu (text editing in search fields etc.)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: NSLocalizedString("Edit", comment: ""))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: NSLocalizedString("Undo", comment: ""), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: NSLocalizedString("Redo", comment: ""), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: NSLocalizedString("Cut", comment: ""), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: NSLocalizedString("Copy", comment: ""), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: NSLocalizedString("Paste", comment: ""), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: NSLocalizedString("Select All", comment: ""), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Window menu
        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: NSLocalizedString("Window", comment: ""))
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: NSLocalizedString("Minimize", comment: ""), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: NSLocalizedString("Close", comment: ""), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = winMenu
    }

    @objc private func openSettingsFromMenu() {
        if #available(macOS 14, *) { openMainWindow(initial: .settings) }
    }

    @objc private func showAboutFromMenu() { showAboutPanel() }
    @MainActor @objc private func checkForUpdatesFromMenu() { UpdateCheck.checkNow() }

    // MARK: - About

    /// Standard About panel, with the engine version and the links that
    /// matter (repo, releases, telemetry disclosure) in the credits.
    func showAboutPanel() {
        // `--version` spawns a subprocess — fetch it off-main, then build
        // and present the panel on main (was a main-thread subprocess block).
        //
        // The descriptor names the product ("burrow-engine 0.1.0"), because this line sits
        // directly under the app's own version in the About panel and a bare "v0.1.0" next
        // to Burrow 0.11.x reads as a bug rather than as a separate component.
        DispatchQueue.global(qos: .userInitiated).async {
            let version = EngineCLI.versionReport()?.display ?? NSLocalizedString("not found", comment: "")
            DispatchQueue.main.async { self.presentAboutPanel(moleVersion: version) }
        }
    }

    private func presentAboutPanel(moleVersion: String) {
        let credits = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        func line(_ text: String, link: String? = nil) {
            let attrs: [NSAttributedString.Key: Any] = link.map {
                [.link: URL(string: $0)!,
                 .font: NSFont.systemFont(ofSize: 11), .paragraphStyle: para]
            } ?? [.font: NSFont.systemFont(ofSize: 11),
                  .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]
            credits.append(NSAttributedString(string: text + "\n", attributes: attrs))
        }
        line(String(format: NSLocalizedString("Engine: %@", comment: ""), moleVersion))
        line(NSLocalizedString("Source on GitHub", comment: ""), link: "https://github.com/caezium/Burrow")
        line(NSLocalizedString("Releases", comment: ""), link: "https://github.com/caezium/Burrow/releases")
        line(NSLocalizedString("What telemetry is collected", comment: ""),
             link: "https://github.com/caezium/Burrow/blob/main/TELEMETRY.md")
        line(NSLocalizedString("Licenses", comment: ""),
             link: "https://github.com/caezium/Burrow/blob/main/LICENSE")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
