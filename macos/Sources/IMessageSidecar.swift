//
//  IMessageSidecar.swift
//  Burrow
//
//  Supervises the bundled "Burrow over iMessage" sidecar (a spectrum-ts Bun
//  program). Two jobs: a long-lived AGENT (text your Mac, it answers) kept alive
//  with restart-on-crash, and a periodic CHECK (disk / CPU / weekly digest) run
//  on a timer. Config comes from `Store` and is handed to the sidecar purely via
//  environment variables — the sidecar reads them (BURROW_ALERT_TO, PHOTON_*,
//  BURROW_LLM_*). The alert layer only formats and sends; Burrow does the
//  measuring (the sidecar calls this app's own `--mcp` server, BURROW_BIN).
//
//  Lifecycle mirrors Maintenance/SnapshotProducer: start() from
//  AppDelegate.startServices() (gated on Store.iMessageEnabled), stop() from
//  applicationWillTerminate.
//

import Foundation
import Darwin

/// A snapshot of the user's iMessage settings, passed to the sidecar as env.
struct SidecarConfig: Equatable {
    var ownerPhone: String
    var projectId: String
    var projectSecret: String
    var agentEnabled: Bool
    var llmProvider: String
    var llmModel: String
    var llmBaseURL: String
    var llmKey: String

    static func fromStore() -> SidecarConfig {
        SidecarConfig(
            ownerPhone: Store.iMessageOwnerPhone,
            projectId: Store.iMessageProjectId,
            projectSecret: Store.iMessageProjectSecret,
            agentEnabled: Store.iMessageAgentEnabled,
            llmProvider: Store.iMessageLLMProvider,
            llmModel: Store.iMessageLLMModel,
            llmBaseURL: Store.iMessageLLMBaseURL,
            llmKey: Store.iMessageLLMKey
        )
    }

    var hasDelivery: Bool { !ownerPhone.isEmpty && !projectId.isEmpty && !projectSecret.isEmpty }
}

/// Pure builders for launching the sidecar — no process, no I/O, fully testable.
enum SidecarLaunch {
    /// Environment the sidecar reads. `burrowBin` is this app's own executable,
    /// which the agent's tools reach as the `--mcp` server. `base` seeds from the
    /// current environment (PATH etc.) in production; empty in tests.
    static func environment(_ c: SidecarConfig, burrowBin: String, base: [String: String] = [:]) -> [String: String] {
        var env = base
        for key in ["PHOTON_PROJECT_ID", "PHOTON_PROJECT_SECRET", "BURROW_LLM_PROVIDER", "BURROW_LLM_MODEL", "BURROW_LLM_BASEURL", "BURROW_LLM_KEY", "USE_JAN"] {
            env.removeValue(forKey: key)
        }
        env["BURROW_ALERT_TO"] = c.ownerPhone
        if !c.projectId.isEmpty { env["PHOTON_PROJECT_ID"] = c.projectId }
        if !c.projectSecret.isEmpty { env["PHOTON_PROJECT_SECRET"] = c.projectSecret }
        env["BURROW_BIN"] = burrowBin
        let home = FileManager.default.homeDirectoryForCurrentUser
        env["BURROW_ALERT_STATE_DIR"] = home.appendingPathComponent("Library/Application Support/Burrow/iMessage").path
        env["BURROW_PARENT_PID"] = String(Foundation.ProcessInfo.processInfo.processIdentifier)
        // Finder launches don't inherit the user's shell PATH.
        let knownPaths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".bun/bin").path]
        env["PATH"] = (knownPaths + (base["PATH"] ?? "").split(separator: ":").map(String.init)).filter { $0.hasPrefix("/") }.joined(separator: ":")
        // Photon egress is direct; keep any local proxy out of the sidecar.
        env["NO_PROXY"] = "*"; env["no_proxy"] = "*"
        env["LOG_LEVEL"] = "silent"
        if c.agentEnabled {
            env["BURROW_LLM_PROVIDER"] = c.llmProvider
            if !c.llmModel.isEmpty { env["BURROW_LLM_MODEL"] = c.llmModel }
            if !c.llmBaseURL.isEmpty { env["BURROW_LLM_BASEURL"] = c.llmBaseURL }
            if !c.llmKey.isEmpty { env["BURROW_LLM_KEY"] = c.llmKey }
        }
        return env
    }

    static func agentArgs(entry: String) -> [String] { ["run", entry] }
    static func checkArgs(entry: String, digest: Bool = false) -> [String] {
        digest ? ["run", entry, "--digest"] : ["run", entry, "--scheduled"]
    }
}

/// Resolved on-disk locations of the bundled sidecar.
struct SidecarPaths {
    var dir: URL
    var bun: URL
    var agentEntry: URL
    var checkEntry: URL

    /// `Contents/Resources/sidecar/` with a bundled `bin/bun`, mirroring how the
    /// `mo` engine is bundled under `Resources/engine/`.
    static func bundled(bundle: Bundle = .main) -> SidecarPaths? {
        guard let res = bundle.resourceURL else { return nil }
        let dir = res.appendingPathComponent("sidecar", isDirectory: true)
        let bun = dir.appendingPathComponent("bin/bun")
        guard FileManager.default.isExecutableFile(atPath: bun.path),
              ["agent.ts", "check.ts", "node_modules/spectrum-ts/package.json"].allSatisfy({
                  FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
              }) else { return nil }
        return SidecarPaths(
            dir: dir,
            bun: bun,
            agentEntry: dir.appendingPathComponent("agent.ts"),
            checkEntry: dir.appendingPathComponent("check.ts")
        )
    }
}

final class IMessageSidecar {
    private let queue = DispatchQueue(label: "dev.caezium.Burrow.imessage")
    private var agent: Process?
    private var check: Process?
    private var checkTimer: DispatchSourceTimer?
    private var stopped = true
    private var generation = UUID()

    private let configuration: () -> SidecarConfig
    private let pathsProvider: () -> SidecarPaths?
    private let checkInterval: TimeInterval
    private let initialDelay: TimeInterval
    private let checkTimeout: TimeInterval
    private let restartDelay: TimeInterval = 5

    init(configuration: @escaping () -> SidecarConfig = SidecarConfig.fromStore,
         paths: @escaping () -> SidecarPaths? = { SidecarPaths.bundled() },
         checkInterval: TimeInterval = 600, initialDelay: TimeInterval = 60,
         checkTimeout: TimeInterval = 180) {
        self.configuration = configuration; self.pathsProvider = paths
        self.checkInterval = checkInterval; self.initialDelay = initialDelay
        self.checkTimeout = checkTimeout
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.stopped else { return }
            let cfg = self.configuration()
            guard cfg.hasDelivery, let paths = self.pathsProvider() else {
                NSLog("[iMessage] not starting: missing delivery config or bundled sidecar")
                return
            }
            self.stopped = false
            self.generation = UUID()
            self.armCheckTimer(paths: paths, cfg: cfg)
            if cfg.agentEnabled { self.spawnAgent(paths: paths, cfg: cfg) }
        }
    }

    func stop() {
        // applicationWillTerminate must signal both children before it returns.
        queue.sync {
            self.stopped = true
            self.generation = UUID()
            self.checkTimer?.cancel(); self.checkTimer = nil
            for child in [self.agent, self.check].compactMap({ $0 }) {
                self.terminate(child)
            }
            self.agent = nil; self.check = nil
        }
    }

    // MARK: - internals (on `queue`)

    private func makeProcess(_ paths: SidecarPaths, _ cfg: SidecarConfig, args: [String]) -> Process {
        let p = Process()
        p.executableURL = paths.bun
        p.arguments = args
        p.currentDirectoryURL = paths.dir
        // `Foundation.` qualifies past Burrow's own `ProcessInfo` metrics struct.
        p.environment = SidecarLaunch.environment(cfg, burrowBin: Bundle.main.executableURL?.path ?? "", base: Foundation.ProcessInfo.processInfo.environment)
        return p
    }

    private func spawnAgent(paths: SidecarPaths, cfg: SidecarConfig) {
        guard !stopped, agent == nil else { return }
        let currentGeneration = generation
        let p = makeProcess(paths, cfg, args: SidecarLaunch.agentArgs(entry: paths.agentEntry.path))
        p.terminationHandler = { [weak self] exited in
            guard let self else { return }
            self.queue.async {
                guard self.agent === exited else { return }
                self.agent = nil
                self.scheduleRestart(paths: paths, cfg: cfg, generation: currentGeneration)
            }
        }
        do { try p.run(); agent = p } catch {
            NSLog("[iMessage] agent failed to launch: \(error)")
            scheduleRestart(paths: paths, cfg: cfg, generation: currentGeneration)
        }
    }

    private func scheduleRestart(paths: SidecarPaths, cfg: SidecarConfig, generation: UUID) {
        queue.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
            guard let self, !self.stopped, self.generation == generation else { return }
            self.spawnAgent(paths: paths, cfg: cfg)
        }
    }

    private func terminate(_ process: Process) {
        process.terminationHandler = nil
        guard process.isRunning else { return }
        process.terminate()
        queue.asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func armCheckTimer(paths: SidecarPaths, cfg: SidecarConfig) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + initialDelay, repeating: checkInterval)
        t.setEventHandler { [weak self] in self?.runCheckOnce(paths: paths, cfg: cfg) }
        checkTimer = t
        t.resume()
    }

    private func runCheckOnce(paths: SidecarPaths, cfg: SidecarConfig) {
        guard !stopped, check == nil else { return }
        let p = makeProcess(paths, cfg, args: SidecarLaunch.checkArgs(entry: paths.checkEntry.path))
        p.terminationHandler = { [weak self] exited in
            guard let self else { return }
            self.queue.async { if self.check === exited { self.check = nil } }
        }
        do {
            try p.run(); check = p
            queue.asyncAfter(deadline: .now() + checkTimeout) { [weak self] in
                guard let self, self.check === p, p.isRunning else { return }
                // Keep the slot occupied until the timed-out process really exits.
                p.terminate()
                self.queue.asyncAfter(deadline: .now() + 2) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
            }
        } catch { NSLog("[iMessage] check failed to launch: \(error)") }
    }
}
