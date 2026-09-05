//
//  MCP.swift
//  Burrow
//
//  Stdio MCP (Model Context Protocol) server. When Burrow is launched
//  with `--mcp`, the GUI path is skipped and this loop takes over,
//  reading JSON-RPC 2.0 messages from stdin and writing responses to
//  stdout (line-delimited).
//
//  This isn't a long-lived service — Claude Code spawns the binary on
//  demand and keeps it alive only while the conversation is live. Each
//  spawn opens its own SQLite handle into the same `burrow.db` the GUI
//  app writes to. SQLite WAL means the spawn can read concurrently
//  with the GUI's sampler write loop.
//
//  The server speaks the 2026-07-28 revision — the one that retired the
//  `initialize` handshake in favour of per-request `_meta` — while still
//  answering a pre-2026 client that expects the handshake. The envelope
//  layer lives in MCPProtocol.swift; the routing lives in MCPServer.swift;
//  this file keeps the process entry point and the tool catalogue.
//
//  Protocol surface implemented:
//    * server/discover → supported versions, capabilities, instructions
//    * initialize / notifications/initialized → legacy handshake, still served
//    * tools/list, tools/call → the catalogue below, with MRTR and tasks
//    * resources/list, resources/templates/list, resources/read
//    * prompts/list, prompts/get, completion/complete
//    * tasks/get, tasks/update, tasks/cancel (io.modelcontextprotocol/tasks)
//
//  All other methods return JSON-RPC error -32601 (method not found).
//  Tool results are wrapped as `{content: [{type: "text", text: "..."}]}`
//  per MCP convention — the text payload is the actual JSON we want
//  the agent to read, mirrored into `structuredContent` for the tools
//  that declare an output schema.
//
//  Wire it up in your Claude Code config (`~/.claude/settings.json`):
//
//      {
//        "mcpServers": {
//          "burrow": {
//            "command": "/Applications/Burrow.app/Contents/MacOS/Burrow",
//            "args": ["--mcp"]
//          }
//        }
//      }
//

import Foundation

enum MCP {
    static func runStdioLoop() {
        // Reader open: same file the GUI writes, but WITHOUT the recovery
        // ladder — this process must never quarantine the writer's live DB
        // or delete its WAL. (The connection is RW at the SQLite level
        // because WAL requires it; we still never insert.)
        let db: DB
        do {
            db = try DB.openDefaultReader()
        } catch {
            stderr("burrow --mcp: failed to open DB: \(error.localizedDescription)")
            exit(1)
        }
        let server = MCPServer(db: db)
        server.serve(input: FileHandle.standardInput,
                     output: FileHandle.standardOutput)
    }

    /// Diagnostic logging. Goes to stderr so it doesn't pollute the
    /// JSON-RPC stream on stdout. Claude Code typically captures stderr
    /// into its agent log file.
    fileprivate static func stderr(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

// MARK: - Tool catalog

enum MCPToolError: Error {
    case unknown(String)
    case badArguments(String)
}

/// Burrow's MCP tools. Each one is a thin wrapper around a DB query
/// that returns a JSON string — agents read the text and parse it.
struct ToolCatalog {
    let db: DB
    /// The one query/aggregation layer — tool handlers parse arguments and
    /// format the frozen wire JSON; all DB/decode/ranking semantics live here.
    private var metrics: MetricsStore { MetricsStore(db: db) }

    /// Tool descriptors for `tools/list`. The inputSchema mirrors the
    /// JSON-Schema subset MCP expects; we keep them minimal.
    func descriptors() -> [[String: Any]] {
        return [
            [
                "name": "burrow_snapshot",
                "description": "Most recent Mole status snapshot (CPU, memory, disk, network, thermal, top processes, system health). Returns the full JSON Mole produced.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_history",
                "description": "Time-series slice of Mole snapshots. `minutes` selects how far back to look (default 60). `samples` caps the number of returned points via stride sampling (default 60, max 720).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "minutes": ["type": "integer", "minimum": 1],
                        "samples": ["type": "integer", "minimum": 1, "maximum": 720],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_top_processes",
                "description": "Top processes (by peak CPU%) across the last `minutes` window (default 60). Aggregates Mole's per-tick top_processes lists.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "minutes": ["type": "integer", "minimum": 1],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_process_usage",
                "description": "Rank processes over the last `minutes` (default 60) by a chosen `metric`: cpu_time (default; cumulative CPU-seconds = the closest answer to 'what used my computer most'), peak_cpu (highest single-sample CPU%), avg_cpu (mean CPU% while present), or peak_mem (highest memory%). Returns the window it actually used (start_ts/end_ts/sample_count) so the answer isn't ambiguous. NOTE: derived from periodic samples, so cpu_time is an estimate, not the kernel's exact accounting.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "minutes": ["type": "integer", "minimum": 1],
                        "metric": ["type": "string", "enum": ["cpu_time", "peak_cpu", "avg_cpu", "peak_mem"]],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_disk_forecast",
                "description": "Forecast when a volume runs out of space, from free-space history. `days` (default 30, 7-365) is the history window to fit; `mount` selects a volume (default: the largest). Returns days_until_full (null when the trend is flat, free space is growing, or there's under a week of history — never a bare date), the bytes/day trend, and the basis it used. Robust to single-sample cliffs. Read-only.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "days": ["type": "integer", "minimum": 7, "maximum": 365],
                        "mount": ["type": "string", "description": "Volume mount point, e.g. \"/\". Defaults to the largest volume."],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_diff",
                "description": "What changed between the snapshot nearest `since` (unix seconds; or use `minutes` back from now, default 1440) and the latest: which processes entered/left the top list, and the free-space delta on the largest volume. v1 scope — app, login-item, and port inventories aren't tracked across time yet, so they're not diffed. Read-only.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "since": ["type": "integer", "description": "Unix-seconds lower bound. Overrides `minutes`."],
                        "minutes": ["type": "integer", "minimum": 1],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_report",
                "description": "A weekly system digest as Markdown over the last `days` (default 7, 1-90): disk-full forecast, top energy users (by estimated CPU-seconds), and cleanup summary. The same artifact the Home Report card shows. Read-only.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "days": ["type": "integer", "minimum": 1, "maximum": 90],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_doctor",
                "description": "Quick diagnostics: engine (mo) presence, Full Disk Access, memory pressure, disk headroom, and recent decode errors — each an ok/warn/fail check with a short detail. Read-only.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_ports",
                "description": "Listening TCP/UDP ports with the owning process (pid, name, uid). Native enumeration (no lsof). Read-only — to free a port, kill the process yourself.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_info",
                "description": "Burrow's own state: list of prefixes with row counts + staleness, current retention setting. Use when diagnosing whether data is flowing.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_cleanup_history",
                "description": "Mole's itemised record of past cleanup activity: each clean/optimize/purge/uninstall session with when it ran, how many items, bytes freed, and an actions breakdown (removed/trashed/skipped/failed). `limit` caps how many recent sessions (default 20, max 200). This is Mole's CLEANUP log — distinct from burrow_history, which is the system-metrics time series. Read-only.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "minimum": 1, "maximum": 200],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_deleted_files",
                "description": "The exact filesystem paths Mole has removed or trashed, newest first, from Mole's deletion log. Each entry has a timestamp, action (trash/remove), category, status (ok/failed), and the absolute path. `limit` caps how many recent paths (default 100, max 5000). Answers 'what exactly did the last cleanup delete?'. Read-only — this reports history, it does not delete anything.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "minimum": 1, "maximum": 5000],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_analyze",
                "description": "Disk-usage breakdown of a directory via `mo analyze --json` — size-ranked immediate children (the data behind Burrow's treemap), largest first. Read-only (no deletion). Use to answer 'what's taking up space?'. `depth` > 1 also descends into the largest subdirectories, so one call replaces a per-directory drill-down. SLOW ON BIG TARGETS: a home folder or ~/Library can take minutes to scan — pass the most specific path you can and use `min_size` to skip noise. Truncation is always reported (`entries_omitted`/`omitted_bytes`; `partial: true` means the descent hit its time budget).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute directory to analyze. Defaults to the home folder."],
                        "depth": ["type": "integer", "minimum": 1, "maximum": 3, "description": "Levels to descend into the largest subdirectories (default 1 = just this directory's children)."],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 1000, "description": "Max entries per level, largest first (default 100)."],
                        "min_size": ["type": "integer", "minimum": 0, "description": "Omit entries smaller than this many bytes (default 0). E.g. 104857600 = 100MB."],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_list_apps",
                "description": "Installed applications and the identifiers `burrow_uninstall` accepts (from `mo uninstall --list`): each row carries `name`, `bundle_id`, `source`, `uninstall_name` (the Homebrew cask token for brew-managed apps, else the display name), `path` and `size`. Read-only. Call this first and pass `bundle_id` to burrow_uninstall — `name` is not unique across installed apps, so it can resolve to a different application than the one you meant. A row whose `bundle_id` is `\"unknown\"` has no bundle identifier at all and cannot be targeted safely. A row with `source: \"Homebrew\"` is removed by `brew uninstall --cask --zap`, not by moving it to the Trash — check this before telling a user their app is recoverable.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_dupes",
                "description": "Duplicate-file groups under one or more directories via `burrow dupes group` (fclones group report). Read-only — reports groups, deletes nothing; the engine's dedupe/remove/link actions are not reachable from this tool. Each path must be an absolute path to an existing directory, else the call is refused before anything runs.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "paths": ["type": "array", "items": ["type": "string"], "description": "Absolute directories to scan for duplicate files."],
                    ],
                    "required": ["paths"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_net",
                "description": "Per-app network attribution via `burrow net`: which apps are moving bytes right now. Read-only.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_orphans",
                "description": "Leftover files under a directory that belong to no installed app, via `burrow orphans`. Read-only. `installed` (comma-separated bundle ids) overrides the auto-detected app inventory.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute directory to scan, e.g. \"~/Library/Application Support\" expanded."],
                        "installed": ["type": "string", "description": "Optional comma-separated bundle ids to treat as installed (overrides auto-detection)."],
                    ],
                    "required": ["path"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_photos",
                "description": "Near-duplicate photos (visually similar PNG/JPEG, dHash) under a directory via `burrow photos`. Read-only — reports groups, deletes nothing.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute directory to scan for similar images."],
                    ],
                    "required": ["path"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_rules_dryrun",
                "description": "Preview what a community rules directory would clean via `burrow rules dryrun <dir>` — per-rule paths with risk and existence, nothing deleted. Read-only. `dir` is required (no rules ship with the app); `app` filters to one bundle id.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        // JSON, not YAML. The loader filters on `extension == "json"` and parses with
                        // serde_json, so a `.yaml` file is not rejected — it is never seen. An agent
                        // that believed the old wording would write YAML, get `{"items":[]}` with
                        // ok:true, and read "no rules matched" from what is really "no rules loaded".
                        "dir": ["type": "string", "description": "Absolute path to a rules directory (one JSON file per app)."],
                        "app": ["type": "string", "description": "Optional bundle id to filter to a single app's rules."],
                    ],
                    "required": ["dir"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_sentinel",
                "description": ".app bundles currently sitting in the Trash (uninstall-leftover candidates) via `burrow sentinel`. Read-only. `trashdir` overrides the default ~/.Trash.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "trashdir": ["type": "string", "description": "Optional Trash directory to scan instead of ~/.Trash."],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_slim_check",
                "description": "Mach-O fat-binary analysis via `burrow slim-check <binary>`: arch slices + bytes a thin-to-host-arch would reclaim. Read-only — estimate only, never rewrites the binary.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "binary": ["type": "string", "description": "Absolute path to a Mach-O binary (e.g. an app's main executable)."],
                    ],
                    "required": ["binary"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_evict",
                "description": "Evict the LOCAL copies of cloud-synced files (iCloud Drive) via `burrow evict <paths…>` — the files stay in the cloud and re-download on next access, so this reclaims disk without deleting anything. SAFE BY DEFAULT: without confirm:true it is a dry run that only reports each path's existence. A real eviction needs confirm:true AND the user's opt-in ('Let agents run cleanups' in Burrow Settings); without the opt-in, confirm:true is refused and reported as blocked. Each path must be absolute and exist, else the call is refused before anything runs. macOS only.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "paths": ["type": "array", "items": ["type": "string"], "description": "Absolute paths (files or directories) whose local copies should be evicted."],
                        "confirm": ["type": "boolean", "description": "true = actually evict (requires the Settings opt-in). Omit/false = dry-run preview only."],
                    ],
                    "required": ["paths"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_clean",
                "description": "Clean caches, logs, temp files and leftovers via `mo clean`. SAFE BY DEFAULT: with no `confirm` (or confirm:false) it runs `--dry-run` and only PREVIEWS what would be freed — nothing is deleted. A real deletion needs confirm:true AND the user's opt-in ('Let agents run cleanups' in Burrow Settings); without the opt-in, confirm:true is refused and reported as blocked. Real runs are not elevated (user-level caches only). SLOW: the scan can take minutes on a full disk — a `timed_out: true` result means it was killed, not that there was nothing to clean.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "confirm": ["type": "boolean", "description": "true = actually delete (requires the Settings opt-in). Omit/false = dry-run preview only."],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_optimize",
                "description": "Refresh system caches/services and run safe maintenance via `mo optimize`. SAFE BY DEFAULT: without confirm:true it runs `--dry-run` (preview only). A real run needs confirm:true AND the user's Settings opt-in, else it's reported as blocked.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "confirm": ["type": "boolean", "description": "true = actually run (requires the Settings opt-in). Omit/false = dry-run preview only."],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_uninstall",
                "description": "UNINSTALL an application via `mo uninstall <app>…` — the .app bundle itself AND the per-app data under ~/Library (containers, Application Support, caches, preferences, logs, saved state, HTTP storage, WebKit data, cookies). The bundle and its files move to the Trash, where the user can put them back, unless `permanent` is true — then they are deleted outright and are not recoverable. EXCEPTION, and tell the user before you confirm: an app installed by Homebrew (`source: \"Homebrew\"` in burrow_list_apps) is removed by `brew uninstall --cask --zap <token>`, which does NOT use the Trash and, via the cask's zap stanza, also deletes configuration and data the dry-run file list cannot enumerate. Identify apps by `bundle_id` from burrow_list_apps: display names are not unique (a machine can hold several apps called `Steam` or `Updater`) and an ambiguous term is REFUSED rather than guessed. SAFE BY DEFAULT: without confirm:true it runs `--dry-run` (preview only; its `items[]` carry `kind: \"application\"|\"leftover\"`, and `requires_admin` tells you the bundle needs administrator rights — over MCP the run is never elevated, since an agent cannot answer the password prompt, so expect `partial`/`refused` for that app and send the user to the Burrow app, which does prompt). A real run needs confirm:true AND BOTH Settings opt-ins (cleanups + the dedicated uninstall/permanent switch), else it's reported as blocked; it also aborts unless the dry run resolves exactly the requested apps. OUTCOMES ARE PER APP: `apps[].status` is `removed`, `partial` or `refused`, and a bundle that could not be removed leaves its support files in place too — report `partial`/`refused` honestly, with the engine's `suggestion`, instead of summarising the run as done.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "apps": ["type": "array", "items": ["type": "string"], "description": "One `bundle_id` per app, exactly as burrow_list_apps reports it. A display name or Homebrew cask token also resolves, but only a bundle id is unambiguous."],
                        "confirm": ["type": "boolean", "description": "true = actually uninstall (requires the Settings opt-in). Omit/false = dry-run preview only."],
                        "permanent": ["type": "boolean", "description": "true = bypass the Trash and delete the app and its files immediately, with no way to put them back. Default false, which moves them to the Trash. Ignored for a Homebrew cask: brew never uses the Trash either way."],
                    ],
                    "required": ["apps"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_purge",
                "description": "Find old project build artifacts (node_modules, target/, build/, …) via `mo purge`. PREVIEW over MCP: this returns the `--dry-run` list of what would be purged. The real purge is an interactive selection flow — run it from the Burrow app. (confirm:true returns the preview plus that note.) SLOW: the scan can take several minutes on a disk with many projects.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "confirm": ["type": "boolean", "description": "Reserved. Real purge is interactive (use the app); any value still returns the preview."],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_installer",
                "description": "Find leftover installer files (.dmg, .pkg, .iso, .xip, .zip) via `mo installer`. PREVIEW over MCP: returns the `--dry-run` list of what would be removed. The real removal is an interactive selection flow — run it from the Burrow app. (confirm:true returns the preview plus that note.) SLOW: the scan can take several minutes on a large disk.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "confirm": ["type": "boolean", "description": "Reserved. Real installer cleanup is interactive (use the app); any value still returns the preview."],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_agent_audit",
                "description": "What AI agents have already done through this MCP server: one row per mutating tool call with the tool name, the exact arguments, whether it was a dry run, whether it succeeded, and how long it took. `minutes` selects the window (default 10080 = 7 days), `limit` caps rows (default 50, max 500). Read-only. Use it to answer 'what has an agent changed on this machine?' before assuming a cleanup didn't happen — and to check your own earlier calls in a long session.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "minutes": ["type": "integer", "minimum": 1, "description": "How far back to look. Default 10080 (7 days)."],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 500],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_anomalies",
                "description": "Processes whose CPU over the last 24h has regressed against their own 14-day baseline, worst first. This is a per-process comparison, not a leaderboard: a process that always uses 40% CPU is not an anomaly, one that jumped from 2% to 15% is. Returns an empty list when there isn't enough history to compare. Read-only.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false,
                ] as [String: Any],
            ],
        ]
    }

    /// Public entry: dispatch the tool, then (for mutating tools) leave an
    /// audit row so a human can see what an agent did (B.5).
    func call(name: String, arguments: [String: Any]) throws -> String {
        let start = Date()
        do {
            if Self.auditedTools.contains(name) {
                for key in ["confirm", "permanent"] where arguments[key] != nil {
                    guard JSONScalar.boolean(arguments[key]) != nil else {
                        throw MCPToolError.badArguments("`\(key)` must be a JSON boolean")
                    }
                }
            }
            let result = try dispatch(name: name, arguments: arguments)
            if Self.auditedTools.contains(name) {
                recordAudit(tool: name, arguments: arguments, ok: !MCPResult.reportsToolFailure(result),
                            summary: result, since: start)
            }
            return result
        } catch {
            if Self.auditedTools.contains(name) {
                recordAudit(tool: name, arguments: arguments, ok: false, summary: "\(error)", since: start)
            }
            throw error
        }
    }

    /// The mutating tools whose use we record. Read-only tools aren't audited
    /// — no action taken, and it would bloat the log (and the reader list).
    static let auditedTools: Set<String> = [
        "burrow_clean", "burrow_optimize", "burrow_uninstall", "burrow_purge", "burrow_installer",
        "burrow_evict",
    ]

    private func recordAudit(tool: String, arguments: [String: Any], ok: Bool, summary: String, since: Date) {
        let argsJSON = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let result = (try? JSONSerialization.jsonObject(with: Data(summary.utf8))) as? [String: Any]
        let entry = AgentAudit.Entry(
            tool: tool, client: "mcp",
            dryRun: JSONScalar.boolean(result?["dry_run"]) ?? (JSONScalar.boolean(arguments["confirm"]) != true),
            durationMs: Int(Date().timeIntervalSince(since) * 1000),
            ok: ok, summary: String(summary.prefix(200)), argsJSON: argsJSON)
        // db.insert is serialized (writeQueue) with a busy timeout, so this is
        // safe alongside the GUI sampler's writes.
        try? db.insert(prefix: AgentAudit.prefix, ts: Int(Date().timeIntervalSince1970),
                       json: AgentAudit.encode(entry))
    }

    private func dispatch(name: String, arguments: [String: Any]) throws -> String {
        switch name {
        case "burrow_snapshot":
            return self.callSnapshot()
        case "burrow_history":
            return try self.callHistory(arguments)
        case "burrow_top_processes":
            return try self.callTopProcesses(arguments)
        case "burrow_process_usage":
            return try self.callProcessUsage(arguments)
        case "burrow_disk_forecast":
            return try self.callDiskForecast(arguments)
        case "burrow_diff":
            return self.callDiff(arguments)
        case "burrow_report":
            return self.callReport(arguments)
        case "burrow_doctor":
            return self.callDoctor(arguments)
        case "burrow_ports":
            return self.callPorts(arguments)
        case "burrow_info":
            return self.callInfo()
        case "burrow_cleanup_history":
            return self.callCleanupHistory(arguments)
        case "burrow_deleted_files":
            return self.callDeletedFiles(arguments)
        case "burrow_analyze":
            return self.callAnalyze(arguments)
        case "burrow_list_apps":
            return self.callListApps()
        case "burrow_dupes":
            return try self.callDupes(arguments)
        case "burrow_net":
            return self.callConductor("net", [])
        case "burrow_orphans":
            return try self.callOrphans(arguments)
        case "burrow_photos":
            return try self.callPhotos(arguments)
        case "burrow_rules_dryrun":
            return try self.callRulesDryrun(arguments)
        case "burrow_sentinel":
            return self.callSentinel(arguments)
        case "burrow_slim_check":
            return try self.callSlimCheck(arguments)
        case "burrow_evict":
            return try self.callEvict(arguments)
        case "burrow_clean":
            return self.runAction(.clean, confirm: (arguments["confirm"] as? Bool) ?? false)
        case "burrow_optimize":
            return self.runAction(.optimize, confirm: (arguments["confirm"] as? Bool) ?? false)
        case "burrow_uninstall":
            return self.runAction(.uninstall(apps: try Self.uninstallApps(arguments),
                                             permanent: (arguments["permanent"] as? Bool) ?? false),
                                  confirm: (arguments["confirm"] as? Bool) ?? false)
        case "burrow_purge":
            return self.runAction(.purge, confirm: (arguments["confirm"] as? Bool) ?? false)
        case "burrow_installer":
            return self.runAction(.installer, confirm: (arguments["confirm"] as? Bool) ?? false)
        case "burrow_agent_audit":
            return try self.callAgentAudit(arguments)
        case "burrow_anomalies":
            return self.callAnomalies()
        default:
            throw MCPToolError.unknown(name)
        }
    }

    /// The agent-supplied `apps[]` for `burrow_uninstall`, or a refusal.
    ///
    /// Pure and separated from the spawn because it is the one dangerous decision on this surface:
    /// which strings an agent may put on the argv of a command that deletes applications, with
    /// `permanent: true` honoured (`MoActions.argv`), i.e. not into the Trash and not recoverable.
    ///
    /// It used to trim and drop empties, and nothing else. The GUI meanwhile refused three values
    /// (`SoftwareModel.isSendableBundleID`) — and the one that only the GUI refused was reachable
    /// here in a single call: `burrow_list_apps` reports `"bundle_id": "unknown"` for every app
    /// with no `CFBundleIdentifier` (five rows on the machine this was verified against), an agent
    /// hands that string back, and the engine's exact bundle-id pass resolves it to whichever such
    /// row comes first. Verified live: `uninstall --dry-run unknown` → Synergy,
    /// `removes_applications: 1`, `unmatched: []`, `ambiguous: []`, `refusal: null`. Every rail the
    /// pre-flight checked agreed, because they all compared the request against itself.
    ///
    /// One predicate now, `UninstallGuard.isSendableArgument`, shared with the GUI and re-checked
    /// inside the guard itself.
    static func uninstallApps(_ arguments: [String: Any]) throws -> [String] {
        let apps = (arguments["apps"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        guard !apps.isEmpty else {
            throw MCPToolError.badArguments("uninstall needs `apps`: one or more app names (see burrow_list_apps)")
        }
        if let unsendable = apps.first(where: { !UninstallGuard.isSendableArgument($0) }) {
            throw MCPToolError.badArguments(
                "\"\(unsendable)\" doesn't name one app — it resolves to whichever app the engine matches first. "
                + "Apps with no bundle identifier are listed by burrow_list_apps as `\"bundle_id\": \"unknown\"`; "
                + "remove those by their exact `name` instead.")
        }
        return apps
    }

    /// What a REAL run of a gated action may claim about the disk, and what to report when it
    /// didn't fully succeed. Pure, so the branch that matters is tested against a real capture
    /// instead of needing a partial uninstall to happen.
    ///
    /// The shape it exists for: `uninstall --apply` over several apps, where one bundle is refused
    /// and another is deleted, exits **1 with an `ok:true` envelope** — the engine's
    /// `i32::from(failed)`, verified against the real binary over two scratch bundles. So
    /// `reportsFailure` is false, and the old `exitCode == 0 && !failed` drove `ran` to FALSE for
    /// a run that had just deleted an application. `error` was no better: with no `error.message`
    /// to classify on a success envelope, `failureReason` fell through to its raw-stdout fallback
    /// and returned the whole JSON document as the error string.
    ///
    /// `ran` is documented on the wire as a claim about the disk, so the per-app accounting
    /// decides it: an application removed, or a support file removed. A run that was refused
    /// outright still reports `ran: false`, which is the honest answer for it.
    static func realRunClaim(_ res: Captured) -> (ran: Bool, error: String?) {
        let stdout = res.stdout, stderr = res.stderr, exitCode = res.exitCode
        let failed = BurrowEnvelope.reportsFailure(stdout: stdout)
        let outcome = UninstallGuard.readOutcome(stdout: stdout)
        let ran = outcome.map(\.changedTheDisk) ?? (exitCode == 0 && !failed)
        guard failed || exitCode != 0 else { return (ran, nil) }
        // The engine's own per-app account when there is one — the same text the GUI shows — and
        // only otherwise the classified reason.
        let error = outcome.flatMap(UninstallGuard.problemReport)
            ?? BurrowEnvelope.failureReason(stdout: stdout, stderr: stderr)
        return (ran, error)
    }

    // MARK: Tool implementations

    private func callSnapshot() -> String {
        guard let row = self.metrics.latestRaw() else {
            return "{\"error\":\"no snapshot yet\"}"
        }
        return "{\"ts\":\(row.ts),\"snapshot\":\(row.json)}"
    }

    private func callHistory(_ args: [String: Any]) throws -> String {
        let minutes = (args["minutes"] as? Int) ?? 60
        let samples = max(1, min((args["samples"] as? Int) ?? 60, 720))
        // Upper bound guards against Int overflow in `minutes * 60` below
        // (Swift traps on overflow — an agent-supplied huge value would
        // kill the MCP process). Same bound as callProcessUsage.
        guard minutes > 0, minutes <= 1_000_000 else {
            throw MCPToolError.badArguments("minutes must be between 1 and 1000000")
        }

        let now = Int(Date().timeIntervalSince1970)
        let since = now - minutes * 60
        let rows = self.metrics.rawRows(prefix: MetricsStore.snapshotPrefix,
                                        MetricsStore.Window(since: since, until: now),
                                        maxPoints: samples)
        var pieces: [String] = []
        pieces.reserveCapacity(rows.count)
        for r in rows {
            pieces.append("{\"ts\":\(r.ts),\"snapshot\":\(r.json)}")
        }
        return "{\"count\":\(rows.count),\"rows\":[\(pieces.joined(separator: ","))]}"
    }

    /// `burrow_agent_audit` — read back the rows `recordAudit` writes. The
    /// audit trail was write-only until now: the GUI could show it and the
    /// MCP process could append to it, but an agent had no way to see what
    /// it (or another agent) had already done. Read-only, and never audited
    /// itself — reading the log isn't an action worth logging.
    private func callAgentAudit(_ args: [String: Any]) throws -> String {
        let minutes = (args["minutes"] as? Int) ?? 10_080
        // Same overflow bound as the other windowed tools.
        guard minutes > 0, minutes <= 1_000_000 else {
            throw MCPToolError.badArguments("minutes must be between 1 and 1000000")
        }
        let limit = max(1, min((args["limit"] as? Int) ?? 50, 500))

        let now = Int(Date().timeIntervalSince1970)
        let rows = self.metrics.rawRows(prefix: AgentAudit.prefix,
                                        MetricsStore.Window(since: now - minutes * 60, until: now),
                                        maxPoints: nil)
        var entries: [[String: Any]] = []
        for row in rows.suffix(limit).reversed() {   // newest first
            guard let e = AgentAudit.decode(row.json) else { continue }
            var item: [String: Any] = [
                "ts": row.ts,
                "tool": e.tool,
                "client": e.client,
                "dry_run": e.dryRun,
                "duration_ms": e.durationMs,
                "ok": e.ok,
                "summary": e.summary,
            ]
            // Args were stored as a JSON string; hand them back as an object
            // so the agent doesn't have to parse a string inside JSON.
            if let d = e.argsJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                item["args"] = parsed
            } else {
                item["args_raw"] = e.argsJSON
            }
            entries.append(item)
        }
        return Self.jsonString(["count": entries.count,
                                "window_minutes": minutes,
                                "entries": entries])
    }

    /// `burrow_anomalies` — per-process CPU regressions against each
    /// process's own baseline. The detector already backed a GUI card; this
    /// is the same call with no new logic behind it.
    private func callAnomalies() -> String {
        let findings = AnomalyScan.scan(metrics: self.metrics,
                                        now: Int(Date().timeIntervalSince1970))
        let items: [[String: Any]] = findings.map {
            ["process": $0.process,
             "recent_median_cpu": $0.recentMedian,
             "baseline_median_cpu": $0.baselineMedian]
        }
        return Self.jsonString([
            "count": items.count,
            "findings": items,
            "basis": "last 24h vs the prior 14 days, per process",
        ])
    }

    private func callTopProcesses(_ args: [String: Any]) throws -> String {
        let minutes = (args["minutes"] as? Int) ?? 60
        let limit = max(1, min((args["limit"] as? Int) ?? 10, 100))
        // Same overflow bound as callHistory/callProcessUsage.
        guard minutes > 0, minutes <= 1_000_000 else {
            throw MCPToolError.badArguments("minutes must be between 1 and 1000000")
        }

        let now = Int(Date().timeIntervalSince1970)
        let since = now - minutes * 60
        // 720 sampled rows over the window is the same budget the
        // HistoryView uses — enough to catch any process that peaked.
        let top = self.metrics.processWindow(MetricsStore.Window(since: since, until: now))
            .ranked(by: .peakCPU, limit: limit)
        var pieces: [String] = []
        for p in top {
            let escaped = p.name.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
            pieces.append("{\"name\":\"\(escaped)\",\"peak_cpu\":\(p.peakCPU),\"peak_mem\":\(p.peakMem)}")
        }
        return "{\"window_minutes\":\(minutes),\"processes\":[\(pieces.joined(separator: ","))]}"
    }

    /// Semantic process ranking. Where `burrow_top_processes` always ranks
    /// by peak CPU — which crowns a one-second spike — this lets the agent
    /// pick the metric that matches the question, and echoes the window it
    /// used so "this week" can't be silently reinterpreted.
    private func callProcessUsage(_ args: [String: Any]) throws -> String {
        let minutes = (args["minutes"] as? Int) ?? 60
        // Upper bound guards against Int overflow in `minutes * 60` below
        // (~1.9 years is far past any useful window).
        guard minutes > 0, minutes <= 1_000_000 else {
            throw MCPToolError.badArguments("minutes must be between 1 and 1000000")
        }
        let limit = max(1, min((args["limit"] as? Int) ?? 10, 100))
        let metric = (args["metric"] as? String) ?? "cpu_time"
        guard let rank = MetricsStore.ProcessRank(rawValue: metric) else {
            let allowed = MetricsStore.ProcessRank.allCases.map(\.rawValue)
            throw MCPToolError.badArguments("metric must be one of: \(allowed.joined(separator: ", "))")
        }

        let now = Int(Date().timeIntervalSince1970)
        let since = now - minutes * 60
        let pw = self.metrics.processWindow(MetricsStore.Window(since: since, until: now))
        var pieces: [String] = []
        for p in pw.ranked(by: rank, limit: limit) {
            let escaped = p.name.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
            pieces.append("{\"name\":\"\(escaped)\",\"peak_cpu\":\(p.peakCPU),\"avg_cpu\":\(p.avgCPU),\"est_cpu_time_seconds\":\(p.estCPUSeconds),\"peak_mem\":\(p.peakMem),\"samples\":\(p.samples)}")
        }
        return "{\"metric\":\"\(metric)\",\"window_minutes\":\(minutes),\"start_ts\":\(pw.startTS),\"end_ts\":\(pw.endTS),\"sample_count\":\(pw.sampleCount),\"interval_seconds\":\(Int(pw.intervalSeconds.rounded())),\"processes\":[\(pieces.joined(separator: ","))]}"
    }

    /// `burrow_disk_forecast` — when does this volume fill? Reads the
    /// free-space history and runs the (honest, cliff-resistant) forecaster.
    private func callDiskForecast(_ args: [String: Any]) throws -> String {
        let days = max(7, min((args["days"] as? Int) ?? 30, 365))
        let mount = args["mount"] as? String
        let now = Int(Date().timeIntervalSince1970)
        let w = MetricsStore.Window(since: now - days * 86_400, until: now)
        let series = self.metrics.diskFreeSeries(mount: mount, w)
        let p = DiskForecast.forecast(series, now: now)
        let mountStr = (mount ?? "primary")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let daysStr = p.daysUntilFull.map { String(format: "%.1f", $0) } ?? "null"
        return "{\"mount\":\"\(mountStr)\",\"basis_days\":\(String(format: "%.1f", p.basisDays)),"
            + "\"slope_bytes_per_day\":\(Int64(p.slopeBytesPerDay.rounded())),"
            + "\"days_until_full\":\(daysStr),\"samples\":\(series.count)}"
    }

    /// `burrow_diff` — what changed since a point in time. v1 diffs top-process
    /// membership and free-space delta from the snapshots already on disk;
    /// app/login-item/port inventories aren't yet persisted over time.
    private func callDiff(_ args: [String: Any]) -> String {
        let now = Int(Date().timeIntervalSince1970)
        let since: Int
        if let s = args["since"] as? Int {
            since = s
        } else {
            let m = max(1, min((args["minutes"] as? Int) ?? 1440, 1_000_000))
            since = now - m * 60
        }
        let snaps = self.metrics.snapshots(MetricsStore.Window(since: since, until: now)).snapshots
        guard let first = snaps.first, let last = snaps.last, snaps.count >= 2 else {
            return "{\"error\":\"need at least two snapshots in the window\",\"since_ts\":\(since),\"until_ts\":\(now)}"
        }
        let change = InventoryDiff.diff(old: (first.status.topProcesses ?? []).map(\.name),
                                        new: (last.status.topProcesses ?? []).map(\.name))
        func freeOf(_ s: MoleStatus) -> Int64 {
            guard let d = s.disks.max(by: { $0.total < $1.total }) else { return 0 }
            return Int64(d.total > d.used ? d.total - d.used : 0)
        }
        func arr(_ xs: [String]) -> String {
            "[" + xs.map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: ",") + "]"
        }
        func ids(_ json: String) -> [String] {
            (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        }
        let invRows = self.metrics.rawRows(prefix: Maintenance.startupInvPrefix,
                                           MetricsStore.Window(since: since, until: now), maxPoints: nil)
        let login = invRows.count >= 2
            ? InventoryDiff.diff(old: ids(invRows.first!.json), new: ids(invRows.last!.json))
            : InventoryDiff.Change(added: [], removed: [])
        return "{\"since_ts\":\(first.ts),\"until_ts\":\(last.ts),"
            + "\"processes_entered\":\(arr(change.added)),\"processes_left\":\(arr(change.removed)),"
            + "\"login_items_added\":\(arr(login.added)),\"login_items_removed\":\(arr(login.removed)),"
            + "\"disk_free_delta_bytes\":\(freeOf(last.status) - freeOf(first.status)),"
            + "\"note\":\"app and port inventories are not yet tracked across time\"}"
    }

    /// `burrow_report` — the weekly digest as Markdown (the tool's text
    /// payload IS the markdown). v1 composes the disk forecast + top energy
    /// from snapshots; cleanup/battery/login-item sections fill in as their
    /// data sources land (so they're omitted/"unavailable" rather than faked).
    private func callReport(_ args: [String: Any]) -> String {
        let days = max(1, min((args["days"] as? Int) ?? 7, 90))
        return WeeklyReport.markdown(
            ReportComposer.gather(metrics: self.metrics, days: days,
                                  now: Int(Date().timeIntervalSince1970)))
    }

    /// `burrow_doctor` — diagnostics from signals already on hand: engine
    /// presence, Full Disk Access, and (from the latest snapshot) memory
    /// pressure + disk headroom, plus the decode-drift count.
    private func callDoctor(_ args: [String: Any]) -> String {
        let moInstalled: Bool
        if case .installed = EngineRunner.shared.availability() { moInstalled = true } else { moInstalled = false }
        let latest = self.metrics.latest()?.status
        var free: Int64 = 0, total: Int64 = 0
        if let d = latest?.disks.max(by: { $0.total < $1.total }) {
            total = Int64(d.total)
            free = Int64(d.total > d.used ? d.total - d.used : 0)
        }
        let fdaDiagnosis = Privacy.diagnoseFullDiskAccess()
        let input = Doctor.Input(
            fullDiskAccess: fdaDiagnosis.hasAccess,
            fullDiskAccessConclusive: fdaDiagnosis.conclusive,
            moInstalled: moInstalled,
            pressure: Self.mapPressure(latest?.memory.pressure),
            diskFreeBytes: free, diskTotalBytes: total,
            recentErrorCount: MetricsStore.driftCounters.decodeSkippedTotal,
            lastBackupDaysAgo: BackupStatus.lastBackupDaysAgo(),
            smartVerified: DiskHealth.smartVerified())
        func esc(_ s: String) -> String {
            "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        let levels = ["ok", "warn", "fail"]
        let items = Doctor.report(input).map { c in
            "{\"name\":\(esc(c.name)),\"level\":\"\(levels[c.level.rawValue])\",\"detail\":\(esc(c.detail))}"
        }
        return "{\"checks\":[\(items.joined(separator: ","))]}"
    }

    /// Map mo's free-text memory-pressure string to the Doctor enum.
    private static func mapPressure(_ s: String?) -> Doctor.MemoryPressure {
        guard let s = s?.lowercased() else { return .normal }
        if s.contains("critical") { return .critical }
        if s.contains("warn") { return .warning }
        return .normal
    }

    /// `burrow_ports` — listening sockets + owning process, via native
    /// enumeration. Read-only; killing is a GUI-only, confirm-gated action.
    private func callPorts(_ args: [String: Any]) -> String {
        func esc(_ s: String) -> String {
            "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        let ports = PortEnumerator.listening()
        let items = ports.map { p in
            "{\"pid\":\(p.pid),\"process\":\(esc(p.process)),\"port\":\(p.port),\"proto\":\"\(p.proto)\",\"uid\":\(p.uid)}"
        }
        return "{\"count\":\(ports.count),\"ports\":[\(items.joined(separator: ","))]}"
    }

    private func callInfo() -> String {
        let now = Int(Date().timeIntervalSince1970)
        var pieces: [String] = []
        for r in self.metrics.readers(now: now) {
            let ts = r.latestTS.map(String.init) ?? "null"
            let age = r.ageSeconds.map(String.init) ?? "null"
            pieces.append("{\"prefix\":\"\(r.prefix)\",\"latest_ts\":\(ts),\"age_seconds\":\(age)}")
        }
        // Drift visibility (mirrors GET /info): skipped-row count + the last
        // failure, so "is data flowing?" has a one-call answer for agents.
        let counters = MetricsStore.driftCounters
        let lastDrift = counters.lastDrift.map {
            Self.jsonString(["ts": $0.ts, "message": $0.message, "snippet": $0.snippet])
        } ?? "null"
        return "{\"now\":\(now),\"retention_days\":\(Store.retentionDays),\"sample_interval_seconds\":\(Store.sampleIntervalSeconds),\"decode_skipped_total\":\(counters.decodeSkippedTotal),\"last_drift\":\(lastDrift),\"readers\":[\(pieces.joined(separator: ","))]}"
    }

    /// Itemised cleanup history (issue #2). The BUNDLED ENGINE always answers `history --json`
    /// wrapped in the standard conductor envelope (`{"ok":true,…,"data":{"sessions":[…],…}}`) —
    /// passing that straight through used to hand an agent the WRONG SHAPE (an envelope where
    /// this tool has always promised the bare `{"sessions":[…]}` mo/digger contract). That is
    /// worse than an empty result: it looks populated, and anything reading `.sessions` off the
    /// top level silently finds nothing instead of getting an obviously-empty or obviously-wrong
    /// answer. Unwrap it like every other consumer (`BurrowEnvelope.parse`); degrade to a valid
    /// empty/error object when `mo` isn't installed, or when the run failed, so the tool never
    /// throws.
    private func callCleanupHistory(_ args: [String: Any]) -> String {
        let limit = max(1, min((args["limit"] as? Int) ?? 20, 200))
        return Self.cleanupHistoryResult(Self.runEngine(["history", "--json", "--limit", "\(limit)"], timeout: 15))
    }

    /// Shape `mo history --json` output into the tool's reply. Pure so every branch is
    /// deterministically testable without a real spawn. Three outcomes, in this order:
    ///  1. Non-zero exit (mo missing, or the run failed) → a valid error object, never a throw.
    ///  2. Envelope-shaped stdout (the bundled engine, always) → unwrap `data` and return THAT —
    ///     still `sessions[…]` at the top level (plus the `logs`/`deletions` fields the engine's
    ///     `data` also carries) — or a classified error object when the envelope itself is
    ///     `ok:false`.
    ///  3. Anything else (a real legacy `mo`, which emits no envelope at all) → passed through
    ///     verbatim, exactly as before this fix — that binary's own `--json` IS the bare shape.
    /// `BurrowEnvelope.parse` "succeeds" on ANY JSON object — a bare `{"sessions":[…]}` blob with
    /// no `ok` key just makes `.ok` default to false — so outcome 2 only fires when `burrow_cli`
    /// (present on every real envelope, success or failure, and never emitted by legacy mo's own
    /// `--json`) is actually there; otherwise this falls through to outcome 3 unchanged.
    static func cleanupHistoryResult(_ res: Captured) -> String {
        guard res.exitCode == 0 else {
            return "{\"error\":\"mo history unavailable\",\"hint\":\"call burrow_info to check whether Burrow is recording data at all\",\"sessions\":[]}"
        }
        let out = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return "{\"sessions\":[]}" }
        guard let envelope = try? BurrowEnvelope.parse(out), envelope.burrowCli != nil else {
            return out
        }
        guard envelope.ok, let data = envelope.data,
              let dataStr = String(data: data, encoding: .utf8) else {
            let message = envelope.error?.message ?? "mo history --json returned an error"
            return Self.jsonString(["error": message,
                                    "hint": "call burrow_info to check whether Burrow is recording data at all",
                                    "sessions": []])
        }
        return dataStr
    }

    /// Exact deleted file paths (issue #2). Reads Mole's append-only
    /// deletion log and returns the most recent `limit` rows, newest
    /// first. Read-only: this surfaces what Mole already deleted; it
    /// never removes anything. Graceful when the log is absent.
    private func callDeletedFiles(_ args: [String: Any]) -> String {
        let limit = max(1, min((args["limit"] as? Int) ?? 100, 5000))
        let logPath = Self.deletionsLogPath()
        let text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        return Self.deletedFilesResult(logText: text, logPath: logPath, limit: limit)
    }

    /// Build the deleted-files reply from raw log text. Pure (the only impure
    /// part — reading the log file — stays in the caller) so the wrapping is
    /// deterministically testable for both populated and empty logs.
    static func deletedFilesResult(logText: String, logPath: String, limit: Int) -> String {
        let files = parseDeletionLog(logText, limit: limit)
        let out: [String: Any] = ["count": files.count, "log": logPath, "files": files]
        if let data = try? JSONSerialization.data(withJSONObject: out,
                                                  options: [.withoutEscapingSlashes]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{\"count\":0,\"files\":[]}"
    }

    /// Parse Mole's tab-separated deletion log into newest-first entries.
    /// Each line is `ts \t action \t category \t status \t path`; the path
    /// is the remainder so an (unlikely) tab inside it survives. Malformed
    /// lines are skipped. Pure → unit-tested.
    static func parseDeletionLog(_ text: String, limit: Int) -> [[String: Any]] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var entries: [[String: Any]] = []
        for line in lines.suffix(max(1, limit)) {
            let parts = line.split(separator: "\t", maxSplits: 4,
                                   omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { continue }
            entries.append([
                "ts": parts[0], "action": parts[1], "category": parts[2],
                "status": parts[3], "path": parts[4],
            ])
        }
        return entries.reversed()
    }

    /// Resolve Mole's deletion-log path from `mo history --json` (the source of truth), falling
    /// back to the standard location when it can't be read from either shape `history` might
    /// answer in.
    private static func deletionsLogPath() -> String {
        let fallback = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/mole/deletions.log")
        let res = Self.runEngine(["history", "--json"], timeout: 10)
        guard res.exitCode == 0 else { return fallback }
        return Self.deletionsLogPath(fromCaptureStdout: res.stdout) ?? fallback
    }

    /// Pure extraction so both shapes are unit-tested without a real spawn. The bundled engine
    /// ALWAYS envelope-wraps, so `logs` sits under `data`, not at the top level — reading
    /// `obj["logs"]` directly (the pre-fix code) silently found nothing on every real build and
    /// always fell through to `fallback` above. That fallback happens to equal the engine's own
    /// standard path today, which is why nothing looked broken in practice; it stops being a
    /// coincidence once this reads the field the engine actually reports. A real legacy `mo`
    /// (no envelope at all) still puts `logs` at the top level, so that shape is tried too.
    static func deletionsLogPath(fromCaptureStdout stdout: String) -> String? {
        if let envelope = try? BurrowEnvelope.parse(stdout), envelope.burrowCli != nil {
            guard envelope.ok, let data = envelope.data,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let logs = payload["logs"] as? [String: Any],
                  let p = logs["deletions"] as? String, !p.isEmpty else { return nil }
            return p
        }
        guard let data = stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let logs = obj["logs"] as? [String: Any],
              let p = logs["deletions"] as? String, !p.isEmpty else { return nil }
        return p
    }

    // MARK: - Action tools (driving mo's real commands)
    //
    // The read tools above never touch the disk. These do — so every call
    // routes through the shared gated-actions core: `MoActions.decide` is
    // the one policy (the same truth table the GUI consults), `ActionWire`
    // owns the JSON contract, and a real run is only expressible as a
    // gate-minted RunTicket. We always drive `mo` itself — never
    // reimplement its cleanup logic.

    /// One shape for all five action tools: read the user's opt-ins fresh
    /// (cross-process cfprefsd read), decide, then execute the ticket or
    /// render the refusal.
    private func runAction(_ action: MoAction, confirm: Bool) -> String {
        let gate = ActionGate.agent(actionsOptIn: Store.mcpActionsEnabled,
                                    irreversibleOptIn: Store.mcpIrreversibleEnabled)
        switch MoActions.decide(action, confirm ? .real : .preview, gate) {
        case .run(let ticket):
            return self.execute(ticket)
        case .blocked(let reason):
            return ActionWire.blocked(command: action.commandName, reason: reason,
                                      apps: action.wireApps)
        case .needsConfirmation, .needsFullDiskAccess, .interactiveFlow:
            // Unreachable from the agent gate; refuse closed if it drifts.
            return ActionWire.blocked(command: action.commandName,
                                      reason: .agentCleanupsOptInOff,
                                      apps: action.wireApps)
        }
    }

    /// Run a gate-minted ticket: preflight (uninstall pins mo's matched set
    /// before any prompt is answered — fail closed), spawn, render.
    private func execute(_ ticket: RunTicket) -> String {
        if let preflight = ticket.preflight {
            let pre = preflight.command
            // Exhaustive, so a pre-flight kind added to the catalog can't quietly acquire a
            // "no branch matched, run it anyway" path here. The probe comes off the same value as
            // the policy, so there is no second optional that could be absent while this one is
            // present — that pair is what used to let a policy fall through to the apply below.
            let expected: [String]
            switch preflight.policy {
            case .verifyUninstallMatch(let apps): expected = apps
            }
            // `pre.spawnPath` and `ticket.command.spawnPath` are the same file by construction —
            // the gate resolved once and put the answer on both — so the plan this reads is the
            // plan the apply below executes, and neither is re-discovered here.
            let dry = Self.runEngine(pre.args, stdin: pre.stdin, timeout: pre.timeout ?? 120,
                                 executable: pre.spawnPath)
            // The decision point, and it fails closed on anything it cannot read. Against the
            // bundled engine it reads `apps[].query` — the arguments echoed back verbatim — so an
            // agent's requested set is checked against the engine's resolved set exactly, in one
            // namespace; against a legacy `mo` it still parses that binary's "Matched N app(s):"
            // display-name list. The two are routed by the envelope discriminator and share no
            // parsing, which is what stops the engine's "No matching applications found." wording
            // from being read as the legacy parser's empty-match answer.
            let dryFailed = dry.exitCode != 0 || BurrowEnvelope.reportsFailure(stdout: dry.stdout)
            let dryReason = dryFailed
                ? BurrowEnvelope.failureReason(stdout: dry.stdout, stderr: dry.stderr)
                : nil
            let reading = UninstallGuard.readDryRun(stdout: dry.stdout, stderr: dry.stderr)
            // No `expecting`: an agent hands over strings, not the inventory row it had in mind,
            // so there is no picked row to check the engine's resolution against. What the guard
            // CAN do here without one is hold every resolved app to `AppPlan.isNamedBy` — the term
            // must be that app's own name or bundle id, not a fragment the substring sweep
            // happened to hit — which is the rail that stops an agent removing an app it never
            // named. Passing `[]` says "this surface has no expectation", explicitly, rather than
            // inheriting a default that would silently skip the check.
            if let reason = UninstallGuard.abortReason(confirmed: expected, dryRun: reading,
                                                       expecting: []) {
                var matched: [String]?
                switch reading {
                case .engine(let plan): matched = plan.apps.map(\.query)
                case .legacy(let names): matched = names
                case .engineRefused, .unreadable: matched = nil
                }
                return ActionWire.uninstallAbort(apps: expected, reason: reason,
                                                 matched: matched, engineError: dryReason)
            }
        }
        let timeout = ticket.command.timeout ?? 600
        // Spawn the binary the gate resolved, not a fresh lookup: `ticket.command.args` is only
        // correct for that file (mo-style or engine-style), so re-discovering here could hand one
        // program the other's wire format.
        let res = Self.runEngine(ticket.command.args, stdin: ticket.command.stdin,
                             timeout: timeout, executable: ticket.command.spawnPath)
        var permanent: Bool?
        if case .uninstall(_, let p) = ticket.action, ticket.mode == .real { permanent = p }
        // `ran` is a CLAIM about the disk — see `realRunClaim`, which owns both it and the reason
        // string for a run that didn't fully succeed. A PREVIEW never ran by definition, and the
        // dry run's own transcript must not be mined for a per-app outcome it doesn't contain.
        let claim = ticket.mode == .real
            ? Self.realRunClaim(res)
            : (ran: false,
               error: (BurrowEnvelope.reportsFailure(stdout: res.stdout) || res.exitCode != 0)
                   ? BurrowEnvelope.failureReason(stdout: res.stdout, stderr: res.stderr)
                   : nil)
        return ActionWire.result(command: ticket.action.commandName,
                                 dryRun: ticket.mode == .preview,
                                 ran: claim.ran,
                                 exitCode: res.exitCode,
                                 // `output` stays the raw transcript — `summaryObject` parses it
                                 // and agents have always read it. The classified reason rides
                                 // alongside instead, so nobody has to dig a message out of a
                                 // JSON document embedded in a JSON string field.
                                 output: res.stdout.isEmpty ? res.stderr : res.stdout,
                                 apps: ticket.action.wireApps,
                                 permanent: permanent,
                                 note: ticket.note,
                                 timedOutAfter: res.timedOut ? timeout : nil,
                                 error: claim.error,
                                 kind: BurrowEnvelope.failureKind(stdout: res.stdout))
    }

    /// `mo analyze --json <path>` — read-only disk-usage breakdown. Mole
    /// reports one level (immediate children with aggregate sizes);
    /// `depth` > 1 re-runs it over the largest subdirectories so an agent
    /// gets a hotspot map in one call instead of a call-per-directory
    /// drill-down. Entries are pruned (`limit`, `min_size`) with omissions
    /// counted — never silently — and re-emitted compact (mole pretty-
    /// prints; agents were seeing 35–60 KB blobs). Degrades to an error
    /// object when `mo` is missing, too old, or times out.
    private func callAnalyze(_ args: [String: Any]) -> String {
        let path = (args["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let depth = min(max((args["depth"] as? Int) ?? 1, 1), 3)
        let limit = min(max((args["limit"] as? Int) ?? 100, 1), 1000)
        let minSize = Int64(max((args["min_size"] as? Int) ?? 0, 0))
        // 300 s like DiskScanner — analyze on a home dir can take a while.
        let res = Self.runEngine(["analyze", "--json", path], timeout: 300)
        if res.timedOut {
            return Self.jsonString([
                "error": "mo analyze timed out",
                "timed_out": true,
                "path": path,
                "hint": "scanning \(path) took over 300s — analyze a more specific subdirectory instead"])
        }
        guard res.exitCode == 0 else {
            // Scoped to a mo-family binary — see `DiskScanner.indicatesMissingJSONSupport` for
            // why the engine has no correct answer to give this question.
            if BurrowEnvelope.inOutput(res.stdout) == nil,
               DiskScanner.indicatesMissingJSONSupport(stderr: res.stderr) {
                return Self.jsonString([
                    "error": "the active engine is too old for `analyze --json` " +
                             "(needs >= \(EngineCLI.minimumAnalyzeJSONVersion)); " +
                             EngineCLI.currentEngineUpdateInstruction,
                    "path": path])
            }
            return Self.analyzeFailure(path: path, stdout: res.stdout, stderr: res.stderr)
        }
        // Zero exit, so the payload — but the engine's payload is the envelope's `data`, not the
        // envelope's own top level. Reading the top level found no `entries` key, so
        // `prunedAnalyzeLevel` wrote back `entries: []` and an agent was handed an envelope with
        // an empty entry list bolted onto it: a directory that reads as having no children.
        // `payloadBytes` unwraps the engine and passes a legacy `mo`'s bare JSON through
        // untouched, and returns nil for an `ok:false` body that somehow exited 0.
        guard let payload = res.payload else {
            return Self.analyzeFailure(path: path, stdout: res.stdout, stderr: res.stderr)
        }
        let out = String(decoding: payload, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else {
            return Self.jsonString(["error": "empty analyze output", "path": path])
        }
        // If mole's JSON shape ever drifts past the parser, pass it through
        // untouched — the old contract.
        guard var root = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] else {
            return out
        }
        root = Self.prunedAnalyzeLevel(root, limit: limit, minSize: minSize)
        if depth > 1 {
            // Budget the descent to stay under the ~120 s window MCP
            // clients wait before backgrounding a call.
            let deadline = Date().addingTimeInterval(90)
            if !self.descendAnalyze(into: &root, levelsLeft: depth - 1, limit: limit,
                                    minSize: minSize, deadline: deadline) {
                root["partial"] = true
                root["hint"] = "the depth descent hit its time budget — entries without `children` were not descended into"
            }
        }
        return Self.jsonString(root)
    }

    /// The `burrow_analyze` failure reply. `stderr` stays in the shape (an agent may read it,
    /// and it is honestly empty against the engine); `reason` and `kind` are the additive fields
    /// that actually say what went wrong, read from whichever channel the resolved binary uses.
    /// Pure so both branches are testable without a spawn.
    static func analyzeFailure(path: String, stdout: String, stderr: String) -> String {
        var obj: [String: Any] = ["error": "mo analyze failed",
                                  "path": path,
                                  "stderr": Self.stripANSI(stderr)]
        if let reason = BurrowEnvelope.failureReason(stdout: stdout, stderr: stderr) {
            obj["reason"] = reason
        }
        if let kind = BurrowEnvelope.failureKind(stdout: stdout) { obj["kind"] = kind }
        return Self.jsonString(obj)
    }

    /// One pruned analyze level: entries sorted largest-first, filtered by
    /// `minSize`, cut to `limit`. Drops are tallied on the level as
    /// `entries_omitted` / `omitted_bytes` so truncation is visible.
    static func prunedAnalyzeLevel(_ level: [String: Any], limit: Int, minSize: Int64) -> [String: Any] {
        var out = level
        let entries = (level["entries"] as? [[String: Any]]) ?? []
        let sorted = entries.sorted { Self.entrySize($0) > Self.entrySize($1) }
        var kept: [[String: Any]] = []
        var omitted = 0
        var omittedBytes: Int64 = 0
        for e in sorted {
            let size = Self.entrySize(e)
            if kept.count < limit, size >= minSize {
                kept.append(e)
            } else {
                omitted += 1
                omittedBytes += size
            }
        }
        out["entries"] = kept
        if omitted > 0 {
            out["entries_omitted"] = omitted
            out["omitted_bytes"] = omittedBytes
        }
        return out
    }

    static func entrySize(_ entry: [String: Any]) -> Int64 {
        (entry["size"] as? Int64) ?? Int64(entry["size"] as? Int ?? 0)
    }

    /// Re-run `mo analyze` over the largest directory entries of `level`,
    /// attaching each pruned result under the entry's `children` (with
    /// `children_omitted` / `children_omitted_bytes` when cut). At most 8
    /// directories per level — this is a hotspot map, not a mirror.
    /// Returns false when the deadline cut the descent short.
    private func descendAnalyze(into level: inout [String: Any], levelsLeft: Int,
                                limit: Int, minSize: Int64, deadline: Date) -> Bool {
        guard levelsLeft > 0, var entries = level["entries"] as? [[String: Any]] else { return true }
        var complete = true
        var descended = 0
        for i in entries.indices {
            guard descended < 8 else { break }
            guard (entries[i]["is_dir"] as? Bool) == true,
                  let childPath = entries[i]["path"] as? String, !childPath.isEmpty else { continue }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 5 else { complete = false; break }
            descended += 1
            let res = Self.runEngine(["analyze", "--json", childPath], timeout: min(remaining, 60))
            // Same unwrap as the top level: decoding the envelope itself gave every descended
            // child `entries: []`, so the hotspot map read as "these directories are empty".
            guard !res.timedOut, res.exitCode == 0,
                  let payload = res.payload,
                  var child = (try? JSONSerialization.jsonObject(
                      with: payload)) as? [String: Any] else {
                if res.timedOut { complete = false }
                continue
            }
            child = Self.prunedAnalyzeLevel(child, limit: limit, minSize: minSize)
            if !self.descendAnalyze(into: &child, levelsLeft: levelsLeft - 1, limit: limit,
                                    minSize: minSize, deadline: deadline) {
                complete = false
            }
            entries[i]["children"] = child["entries"]
            if let om = child["entries_omitted"] { entries[i]["children_omitted"] = om }
            if let ob = child["omitted_bytes"] { entries[i]["children_omitted_bytes"] = ob }
        }
        level["entries"] = entries
        return complete
    }

    /// `mo uninstall --list` — installed apps + the exact names uninstall
    /// accepts. Read-only.
    private func callListApps() -> String {
        return Self.listAppsToolResult(Self.runEngine(["uninstall", "--list"], timeout: 60))
    }

    /// Shape `mo uninstall --list` output into the tool's reply. Pure so the failure branch is
    /// deterministically testable without a real spawn (mirrors `cleanupHistoryResult` above —
    /// same "may be absent on a CI runner" reasoning).
    static func listAppsToolResult(_ res: Captured) -> String {
        let stdout = res.stdout, stderr = res.stderr, exitCode = res.exitCode
        // A zero exit is not on its own proof of a listing: an `ok:false` body is a failure
        // whatever the process claimed on the way out, and passing it through would hand an
        // agent an error document where it expects an app array. `uninstall --list` answers
        // with a BARE JSON array (verified against burrow-engine @ 945000a — one of the
        // engine's un-enveloped commands), so there is nothing to unwrap on the success path
        // and the passthrough at the bottom is unchanged; this only catches the failing shape.
        guard exitCode == 0, !BurrowEnvelope.reportsFailure(stdout: stdout) else {
            // When the engine fails a command it writes its error envelope to STDOUT, not stderr,
            // so `stderr` alone is always empty here and told an agent nothing. Surface both so
            // the actual reason is visible. Deliberately NO `"apps": []` alongside the error:
            // this tool's own description tells an agent to call it before `burrow_uninstall` for
            // an exact bundle id, and an agent that reads `.apps` without checking `.error` first
            // must not find an empty array sitting right next to it — that reads as "zero apps
            // installed" and is exactly the wrong-shape trap this fix closes (an agent can act on
            // a false "no apps" with more confidence than a human glancing at a blank list would).
            //
            // The hint no longer claims the engine has no app-listing command: it implements
            // `uninstall --list` and answered with 135 rows on the machine this was verified on,
            // so a failure here is a real failure, not the expected steady state it once was.
            //
            // `reason`/`kind` are the same additive pair the other tools now carry: the agent
            // no longer has to notice that "read stdout for the engine's own error envelope"
            // means "and parse a second JSON document out of this string field". Both raw
            // streams stay in the shape — the hint above still points at them, and `stderr`
            // being empty is itself the honest report for the engine.
            var obj: [String: Any] = [
                "error": "mo uninstall --list failed",
                "hint": "burrow_uninstall can't be given an exact bundle id without this listing — read `reason` for the engine's own classified error",
                "exit_code": Int(exitCode),
                "stdout": Self.stripANSI(stdout),
                "stderr": Self.stripANSI(stderr)]
            if let reason = BurrowEnvelope.failureReason(stdout: stdout, stderr: stderr) {
                obj["reason"] = reason
            }
            if let kind = BurrowEnvelope.failureKind(stdout: stdout) { obj["kind"] = kind }
            return Self.jsonString(obj)
        }
        let out = Self.stripANSI(stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "{\"apps\":[]}" : out
    }

    // MARK: - Conductor discovery tools (Phase 6.3 parity, read-only)
    //
    // These expose the engine's discovery commands through the bundled
    // binary (`burrow <cmd> --json`, BurrowEngine.capture) and pass
    // the envelope's `data` payload through VERBATIM — the contract tracks
    // the engine's, not ours, exactly like burrow_analyze tracks Mole's.
    // The seven discovery tools are read-only: no audit rows, no confirm
    // gates. `burrow_evict` (below) is the one actuating tool on this seam
    // and carries the same preview/confirm/opt-in gate as the action tools;
    // the other mutating siblings (dupes dedupe/remove/link, slim) stay out.

    /// One shape for every conductor-seam tool: availability check, capture,
    /// pass `data` through. Degrades to a JSON error object — never a throw —
    /// so an agent on a build without the bundled conductor sees why instead
    /// of a -32603 (same posture as the exit-127 `mo` degrade above).
    private func callConductor(_ command: String, _ args: [String],
                               timeout: TimeInterval = 300) -> String {
        guard BurrowEngine.isAvailable else {
            return Self.jsonString([
                "error": "the burrow conductor is not bundled in this build; \(command) is unavailable",
                "command": command])
        }
        do {
            let envelope = try BurrowEngine.capture(command, args, timeout: timeout)
            guard let data = envelope.data,
                  let out = String(data: data, encoding: .utf8),
                  !out.isEmpty else {
                return Self.jsonString(["error": "burrow \(command) returned no data",
                                        "command": command])
            }
            return out
        } catch let BurrowEngineError.engine(kind, message) {
            return Self.jsonString(["error": message, "kind": kind, "command": command])
        } catch {
            return Self.jsonString(["error": error.localizedDescription, "command": command])
        }
    }

    /// `burrow dupes group <paths…>` — duplicate-file groups (fclones group report).
    ///
    /// The subcommand is HARDCODED to the read-only `group`, never taken from the agent: the
    /// engine's `dupes` reads its first positional as `group|dedupe|remove|link`, so an agent
    /// string in that slot could select the mutating `dedupe`/`remove`/`link` actions, and an
    /// `--apply` anywhere in argv would run them. Every path is therefore validated by
    /// `Self.scanDirectory` BEFORE anything is spawned — absolute, existing, a directory — which
    /// is also what keeps a `--flag`-shaped or `dedupe`-shaped string out of the engine's argv.
    /// No `--` separator: the engine at the pinned commit rejects a bare `--` as an unknown
    /// option (`reject_unknown_flag`), so the validation IS the separator here.
    private func callDupes(_ args: [String: Any]) throws -> String {
        let paths = (args["paths"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        guard !paths.isEmpty else {
            throw MCPToolError.badArguments("dupes needs `paths`: one or more directories to scan")
        }
        let directories = try paths.map { try Self.scanDirectory($0, tool: "dupes") }
        return self.callConductor("dupes", ["group"] + directories)
    }

    /// One agent-supplied scan target, admitted to argv only as an absolute path to an existing
    /// directory. Anything else — a relative path, a flag, a subcommand name, a file, a missing
    /// directory — is refused with the tool's usual `badArguments` and nothing is spawned.
    static func scanDirectory(_ path: String, tool: String) throws -> String {
        guard path.hasPrefix("/") else {
            throw MCPToolError.badArguments(
                "\(tool) `paths` must be absolute directories; got `\(path)`")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MCPToolError.badArguments(
                "\(tool) `paths` must name existing directories; `\(path)` is not one")
        }
        return path
    }

    /// `burrow orphans <dir> [--installed id1,id2,…]` — leftover files
    /// belonging to no installed app.
    private func callOrphans(_ args: [String: Any]) throws -> String {
        guard let path = (args["path"] as? String)?.trimmingCharacters(in: .whitespaces),
              !path.isEmpty else {
            throw MCPToolError.badArguments("orphans needs `path`: a directory to scan")
        }
        var argv = [path]
        if let installed = (args["installed"] as? String)?.trimmingCharacters(in: .whitespaces),
           !installed.isEmpty {
            argv += ["--installed", installed]
        }
        return self.callConductor("orphans", argv)
    }

    /// `burrow photos <dir>` — visually-similar image groups (dHash).
    private func callPhotos(_ args: [String: Any]) throws -> String {
        guard let path = (args["path"] as? String)?.trimmingCharacters(in: .whitespaces),
              !path.isEmpty else {
            throw MCPToolError.badArguments("photos needs `path`: a directory to scan")
        }
        return self.callConductor("photos", [path])
    }

    /// `burrow rules dryrun <dir> [--app id]` — preview a rules directory.
    /// The CLI defaults its dir to `rules/` relative to CWD, which is
    /// meaningless from a GUI-spawned process (and the app bundle ships no
    /// rules), so the tool requires an explicit `dir` — honest > broken.
    private func callRulesDryrun(_ args: [String: Any]) throws -> String {
        guard let dir = (args["dir"] as? String)?.trimmingCharacters(in: .whitespaces),
              !dir.isEmpty else {
            throw MCPToolError.badArguments("rules_dryrun needs `dir`: a rules directory (none ships with the app)")
        }
        var argv = ["dryrun", dir]
        if let app = (args["app"] as? String)?.trimmingCharacters(in: .whitespaces),
           !app.isEmpty {
            argv += ["--app", app]
        }
        return self.callConductor("rules", argv)
    }

    /// `burrow sentinel [trashdir]` — .app bundles sitting in the Trash.
    private func callSentinel(_ args: [String: Any]) -> String {
        let trashdir = (args["trashdir"] as? String)?.trimmingCharacters(in: .whitespaces)
        let argv = trashdir.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        return self.callConductor("sentinel", argv)
    }

    /// `burrow slim-check <binary>` — Mach-O fat-slice reclaim estimate.
    private func callSlimCheck(_ args: [String: Any]) throws -> String {
        guard let binary = (args["binary"] as? String)?.trimmingCharacters(in: .whitespaces),
              !binary.isEmpty else {
            throw MCPToolError.badArguments("slim_check needs `binary`: a path to a Mach-O binary")
        }
        return self.callConductor("slim-check", [binary])
    }

    /// `burrow evict <paths…> [--apply]` — dehydrate cloud-synced files. The engine previews by
    /// default and evicts only on `--apply`, which this appends ONLY for a confirmed call the
    /// user has opted into — the same two conditions `burrow_clean`'s real run needs, refused
    /// with the same `blocked` wire shape. Paths are admitted to argv only as absolute paths
    /// that exist (a file or a directory), so an agent string can neither be read as a flag nor
    /// name something the engine would then go looking for.
    private func callEvict(_ args: [String: Any]) throws -> String {
        let paths = (args["paths"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        guard !paths.isEmpty else {
            throw MCPToolError.badArguments("evict needs `paths`: one or more files or directories")
        }
        let targets = try paths.map { try Self.existingAbsolutePath($0, tool: "evict") }
        let confirm = (args["confirm"] as? Bool) ?? false
        guard !confirm || Store.mcpActionsEnabled else {
            return ActionWire.blocked(command: "evict", reason: .agentCleanupsOptInOff)
        }
        return self.callConductor("evict", targets + (confirm ? ["--apply"] : []))
    }

    /// One agent-supplied path, admitted to argv only when absolute and present on disk.
    static func existingAbsolutePath(_ path: String, tool: String) throws -> String {
        guard path.hasPrefix("/") else {
            throw MCPToolError.badArguments("\(tool) `paths` must be absolute; got `\(path)`")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw MCPToolError.badArguments("\(tool) `paths` must exist; `\(path)` does not")
        }
        return path
    }

    // MARK: Action helpers

    /// Run `mo` with the given args, never throwing — a missing binary
    /// becomes exit code 127 so callers can degrade gracefully.
    ///
    /// `executable` pins the spawn to an already-resolved path. The read tools leave it nil and
    /// let discovery answer, because their argv means the same thing to either binary; a gated
    /// ACTION must pass the path its ticket was minted against, since that is the file its argv
    /// was translated (or deliberately not translated) for.
    ///
    /// With no `executable`, the BUNDLED engine is spawned when this build ships one — the same
    /// file and the same environment (`BurrowEngine.environment()`: the bundled fclones and
    /// the #279 PATH augmentation) every conductor-seam tool uses — and only a build without
    /// one falls back to `.mo` discovery. A resolved executable that IS the bundled engine gets
    /// that environment too; anything else runs with the app's own, as before.
    private static func runEngine(_ args: [String], stdin: String? = nil, timeout: TimeInterval,
                                  executable: String? = nil) -> Captured {
        let bundled = BurrowEngine.executableURL()?.path
        let target: MoCommand.Target
        switch (executable, bundled) {
        case (let exe?, _): target = .executable(exe)
        case (nil, let path?): target = .executable(path)
        case (nil, nil): target = .mo
        }
        let environment: [String: String]?
        if case .executable(let path) = target, path == bundled {
            environment = BurrowEngine.environment()
        } else {
            environment = nil
        }
        guard let cap = try? EngineRunner.shared.capture(
            MoCommand(target: target, args: args, stdin: stdin, environment: environment,
                      timeout: timeout)) else {
            return Captured(stdout: "", stderr: "mo not found", exitCode: 127)
        }
        return cap
    }

    /// Strip ANSI/VT100 escape sequences so mo's TUI coloring doesn't leak
    /// into the JSON text payload. Delegates to the one `Ansi.strip`.
    static func stripANSI(_ s: String) -> String { Ansi.strip(s) }

    private static func jsonString(_ obj: [String: Any]) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return "{\"error\":\"encode failed\"}"
    }
}
