# Burrow telemetry and website analytics

Burrow's apps collect **anonymous, opt-out** product analytics and crash reports so we
can see how many installs stay active, which versions to support, which features
get used, and when something breaks. This file is the exact, honest list of
what that means. The privacy summary lives in [SECURITY.md](SECURITY.md); this
is the detail. The public website uses a separate cookieless configuration,
documented below; the app's Settings switch does not control website requests.

## What and who

| Concern | Client | Host (default) |
|---|---|---|
| Product analytics | Burrow's background HTTPS transport → [PostHog](https://posthog.com) | `us.i.posthog.com` |
| Crash / error reporting | [Sentry Cocoa](https://sentry.io) | `*.ingest.us.sentry.io` (from the release DSN) |

Client code: [`macos/Sources/Telemetry.swift`](macos/Sources/Telemetry.swift)
(PostHog) and [`macos/Sources/CrashReporter.swift`](macos/Sources/CrashReporter.swift)
(Sentry).

The shipping
[`PrivacyInfo.xcprivacy`](macos/Resources/PrivacyInfo.xcprivacy) declares
Product Interaction and Other Usage Data for analytics, plus Crash,
Performance, and Other Diagnostic Data for app functionality. Every category
is unlinked and non-tracking. The manifest changes no collection behavior; it
describes the opt-out behavior enforced below.

Sparkle update checks are operational network traffic. Sparkle requests the
signed `appcast.xml` asset from GitHub and, after user approval, the signed
release ZIP; Burrow adds no identifier or device profile to those requests.
Burrow separately records fixed-name update milestones such as
`update_found`, `update_download_failed`, and `update_install_started` through
the opt-out telemetry pipeline. Depending on the milestone, properties contain
only the update version, check source, result, fixed failure category/recovery,
and bounded outer/underlying error domain/code. Error descriptions, request
URLs, response bodies, and network names are never sent. Sparkle
system profiling is explicitly disabled with `SUEnableSystemProfiling=false`;
GitHub necessarily sees the request IP at the network layer. Signing and
notarization themselves add no telemetry and require no additional
privacy-manifest category.

PostHog's host defaults to `https://us.i.posthog.com` and can be replaced by a
release build setting. Sentry has no separate host setting: its ingest endpoint
is encoded in the **DSN injected at release time**. For official builds that's
the maintainer's Sentry project; a fork built with its own DSN reports to its
own project instead.

## Ground rules (enforced in code, not just promised)

- **Opt-out, on by default.** One switch — **Settings → Anonymous usage** —
  gates both pipelines (`Store.telemetryEnabled`). When it is off, Burrow
  creates no PostHog request and Sentry is `close()`d.
- **Inert without keys.** The PostHog key and Sentry DSN are injected only at
  release time (Info.plist `PHPostHogApiKey` / `SentryDSN`, from build
  settings). A build from this repo ships them empty and touches neither
  network. See `scripts/release.env.example`.
- **Identity is random.** Burrow's random PostHog distinct id plus Sentry's own
  install id (two ids total) are not derived from a serial, MAC address,
  hardware identifier, or account. The PostHog id is created on the background
  telemetry queue only after analytics is enabled. Existing 0.11.0 installs
  retain the random anonymous UUID previously created by posthog-ios through a
  validated one-time local migration, so updates do not reset retention.
  Opting out leaves those ids and any Sentry cache on disk; deleting the app's
  Application Support and Caches folders removes them.
- **No PII, ever.** `DiagnosticPrivacy.sanitize()` drops sensitive keys (paths,
  file names, contents, URLs, tokens, email, username, identifiers, arguments,
  headers, payloads, …), accepts only primitive values, and replaces complete
  path-like strings. Sentry stack-memory introspection is explicitly disabled.
  Before transport, exception values and mechanism metadata are removed,
  contexts are recursively sanitized, raw registers are cleared, and debug/frame
  labels, UUIDs, and addresses must pass strict bounded formats. Package,
  source-file, source-context, variable, and binary-image path fields are
  removed.
- **PostHog sizes/counts/durations are bucketed**, never raw — see
  `bytesBucket`, `countBucket`, `secondsBucket`. Sentry's sampled performance
  traces necessarily contain precise span timing, but every span has a fixed
  name and automatic network, file, Core Data, and UI tracing is disabled.
- **No screen capture.** Burrow sends fixed semantic screen names such as
  `home`, `settings`, and `tool.clean`. The macOS PostHog client has no session
  replay, element autocapture, remote config, error tracking, or logs; Sentry
  screenshots and view-hierarchy capture are never enabled.

## Super properties (attached to every event)

`platform: "macos"`, `app_version`, `build_number`, `os_version` (e.g.
`macOS 27.0.0`), exact `os_build` (e.g. `26A5388g`), `os_prerelease`, `arch`
(`arm64` / `x86_64`), and `locale`.

Burrow's first-party client attaches no hidden SDK context. It additionally
sends fixed PostHog protocol fields: `$ip: "0"`, `$lib: "burrow-macos"`,
`$lib_version`, and `$process_person_profile: false`. Feature flags are cached,
telemetry-gated, and restricted to non-safety-critical UI/rollout choices — see
[Feature flags](#feature-flags).

**IP address:** as with any HTTPS request, the TCP connection still exposes
your IP to the receiving service at the network layer, but neither pipeline
stores it as event data. PostHog events carry `$ip = "0"`, so PostHog records
no IP and derives no GeoIP; the project additionally has **"Discard client IP
data"** enabled (defence in depth). Sentry runs with `sendDefaultPii = false`,
so no IP is attached to events either.

## Feature flags

Burrow evaluates a **fixed allowlist** of PostHog feature flags for gradual
rollout and product/UI experiments. Flags are deliberately restricted to
harmless, non-safety-critical choices; they are **never** used for
cleaning/deletion behavior, permissions, security controls, signing/notarization,
Sparkle verification, launch recovery, or telemetry consent.

- **Allowlisted and typed.** The only keys Burrow accepts are listed in
  `RemoteFeatureFlags.Key` (client code:
  [`macos/Sources/RemoteFeatureFlags.swift`](macos/Sources/RemoteFeatureFlags.swift)).
  Anything PostHog returns that is not in the allowlist — or that decodes to the
  wrong type — is ignored. Accepted value shapes are `bool`, `string`, and `int`
  only.
- **Cached and startup-independent.** The last accepted values are cached at
  `~/Library/Application Support/Burrow/feature-flags.json` (bounded to 8 KB and
  a 24-hour trust window). Evaluation reads only that in-memory cache and never
  blocks on the network; every missing, stale, malformed, or future-dated value
  falls back to a baked-in conservative default. An opted-out launch does not
  read the cache or contact PostHog.
- **Fetched on the background queue.** Flags are fetched from PostHog's
  `POST {host}/decide/?v=3` on the private background telemetry queue — never on
  a main-run-loop timer. The JSON request body contains exactly two fields:
  `token` (the release-injected project key) and `distinct_id` (the random
  anonymous id described above). No additional PostHog payload properties are
  sent. Retries are serialized with the same bounded backoff as event delivery
  and are re-driven by later product events; permanent rejections re-check no
  sooner than the cache trust window.
- **Exposure events.** When a flag actually gates behavior, Burrow records one
  PostHog `$feature_flag_called` event per flag per launch with
  `$feature_flag` (the allowlisted key) and `$feature_flag_response` (the typed
  value). No user content or arbitrary properties are attached.

### Flag keys

| Key | Type | Conservative default | Purpose |
|---|---|---|---|
| `tune_up_badge` | `bool` | `false` | A cosmetic badge on the Tune-Up section (UI-only; the rollout validation target) |

## Events

### Wired now

| Events | Properties |
|---|---|
| `app_opened`, `app_ready`, `app_terminated` | cold-start; menu-bar availability; compatibility-mode boolean and fixed status-item state |
| `app_updated` | previous/current app version and build |
| `engine_missing`, `install_window_ready`, `onboarding_completed` | none |
| `telemetry_opt_in_changed` | enabled boolean |
| PostHog `$screen` | fixed name: `home`, `settings`, or `tool.<known tool>` |
| PostHog `$feature_flag_called` | `$feature_flag` (allowlisted key) and `$feature_flag_response` (typed value); once per flag per launch |
| `feature_operation_started`, `feature_operation_completed` | `clean`/`optimize`, dry-run/elevated booleans, fixed result, bucketed duration |
| `previous_launch_incomplete` | previous phase, app version/build, OS build, bucketed elapsed time |
| `compatibility_fallback_activated`, `compatibility_fallback_reaffirmed` | fixed reason, OS build, menu-bar mode |
| `status_item_creation_scheduled`, `status_item_stability_started`, `status_item_stabilized` | fixed `launch` or `settings` source |
| `diagnostic_report_copied` | fixed recovery reason |
| `updater_started`, `updater_stabilized` | `automatic`, `manual`, or `settings` source |
| `automatic_updater_suppressed` | fixed recovery reason, app build, and OS build |
| `update_check_started` | `manual` source |
| `update_found`, `update_not_found` | target version on `update_found`; fixed manual/automatic source on `update_not_found` |
| `update_download_started`, `update_download_completed`, `update_download_failed` | target version; failures add fixed category/recovery and bounded outer/underlying error domain/code |
| `update_install_started`, `update_choice_made` | target version, fixed choice, numeric Sparkle stage |
| `update_cycle_completed`, `update_cycle_failed` | source, fixed result/update-found boolean; failures add fixed category/recovery and bounded outer/underlying error domain/code |

Sentry captures crashes, unhandled errors, and app hangs automatically. Release
health sessions are enabled and the fixed-name launch trace is sampled at 10%.
For apps running from `/Applications`, 10% of those sampled traces are profiled,
for about 1% of launches overall; profiling is disabled from Downloads, home
directories, mounted volumes, and other relocated paths because profile
envelopes contain binary-image paths. Pre-main profiling is always disabled.
Burrow adds at most 50 fixed-name manual breadcrumbs and fixed-name
warning/error logs. Stack-memory introspection, automatic network breadcrumbs, failed-request capture,
file I/O tracing, Core Data tracing, UI tracing, screenshots, and view-hierarchy
capture remain disabled.

Expected updater conditions do not become Sentry issues. Sparkle's
running-translocated/running-from-disk-image errors stay in PostHog with the
fixed `move_to_applications` recovery, ordinary network download failures stay
in PostHog with `sparkle_scheduled_retry`, and user cancellations are recorded
as completed cycles. Configuration, signature/validation, installation, and
otherwise unknown failures still create a scrubbed Sentry diagnostic. The
public GitHub bridge includes only the Sentry short ID/restricted link and
bounded project, release, OS-build, launch-phase, status-item, level, count, and
time fields. It never copies raw Sentry titles, frames, paths, usernames,
arguments, or payloads. Maintainers review detailed diagnostics in restricted
Sentry and copy only a minimal privacy-reviewed diagnosis into the public issue.
App-Hang groups are aggregated into a weekly digest instead of being silently
skipped or opening one issue per sampled frame.

Automatic Sparkle startup begins only after the status item has remained
responsive for 30 seconds, then receives a separate 30-second durable
`updater_scheduled` → `updater_ready` stability window. If that window is
interrupted, later automatic starts are suppressed for the same app and OS
build while manual checks stay available. This keeps a Sparkle failure from
being misattributed to the menu-bar component or repeated every launch.

App hangs are grouped by coarse launch phase and the top Burrow frame. The first
hang in each distinct group is retained; only identical repeats are limited to
one per minute. Low-memory hangs are tagged `critical`, `low`, or `normal`
rather than discarded, so an affected macOS beta cohort cannot disappear from
reporting.

Burrow also keeps a local atomic launch journal at
`~/Library/Application Support/Burrow/launch-state.json`. It contains a random
per-run ID, app/OS versions, architecture, coarse launch phase, timestamps, and
the OS build for a remembered status-item recovery plus an app-build/OS-build
key for a remembered updater recovery. It contains no paths, filenames, window
contents, hardware ID, or account data. The journal is written even when
telemetry is off because it powers local crash recovery; nothing from it is
transmitted unless anonymous usage is enabled, and the run ID is never
transmitted or included in copied diagnostics.

The PostHog distinct id lives beside it at
`~/Library/Application Support/Burrow/telemetry-id`. Burrow creates that file
only after analytics is enabled; the file contains one random UUID. On the
first enabled launch after replacing posthog-ios, Burrow validates and copies
that SDK's existing anonymous UUID into this file rather than assigning the
installation a new identity. A bounded `telemetry-outbox/` keeps at most 64
already-sanitized event payloads so a startup/update diagnostic can survive a
lost network or forced reboot. It retries only one historical payload at a
time, backs transient failures off from 30 seconds to at most one hour, and
drops permanent 3xx/4xx rejections (except retryable 408/425/429 responses).
All of that disk work runs on the background telemetry queue.

### Deliberately deferred

`fda_state`, uninstall/purge detail, and MCP subprocess events are not wired.
Burrow will not build a custom pixel recorder for macOS.

## Turning it off

Settings → **Anonymous usage** → off. PostHog sends one final
`telemetry_opt_in_changed` through Burrow's transport, then all later events are
rejected; Sentry closes. The two random ids and any Sentry cache stay on disk
so a later re-enable reuses the same anonymous identity. The sanitized PostHog
outbox also stays on disk but is not read or transmitted until telemetry is
enabled again. A launch that begins opted out makes no PostHog request. There
is no server-side deletion call.

## Website analytics

The production site at [`burrow.henryzh.dev`](https://burrow.henryzh.dev)
loads [`docs/analytics.js`](docs/analytics.js), then PostHog's Web JavaScript
bundle from `us-assets.i.posthog.com`; events go directly to
`us.i.posthog.com`. The committed source contains only a placeholder project
key and runs only on that exact production hostname, so local previews and
forks are inert. The deploy workflow and `scripts/deploy-site.sh` stage a copy,
inject the same PostHog project key used by the apps, and fail before publishing
when that key is unavailable or malformed. Running `npx wrangler deploy`
directly is unsupported because it bypasses that guard.

The site uses PostHog's **stateful cookieless mode**. It sets no PostHog cookie,
local-storage value, or session-storage value, never calls `identify`, and
creates no person profile. PostHog derives a rotating daily hash from the
request IP, the SDK's raw user-agent field, and the site domain, then removes
both raw inputs before writing the event. It uses temporary server-side state
for a 30-minute session boundary; the project's separate **Discard client IP
data** setting remains enabled as a second guard. The daily hash is unrelated
to either app's random install ID and cannot follow a browser across days.

The captured website events and fields are:

| Events | Properties |
|---|---|
| `$pageview`, `$pageleave` | Page title, host/path, query- and fragment-free current/referrer URLs, visit duration, and PostHog's scroll-depth percentages/pixel maximums |
| `$web_vitals` | CLS, INP, and LCP values plus bounded name, value, delta, rating, navigation type, and a query- and fragment-free page URL. Raw browser performance-entry arrays, element data, metric IDs, and nested timestamps are removed |
| `website_download_clicked` | Fixed `destination: "github_release"`; fixed placement: `navigation`, `hero`, `pricing`, `windows`, `changelog`, or `roadmap` |
| `website_homebrew_copy_clicked` | Fixed `command: "install"`; fixed placement: `hero` or `install_card` |

PostHog also attaches ordinary web context: browser and OS family/version,
device type, language/time zone, viewport and screen dimensions, page host/path
and title, sanitized referrer, and PostHog library version. URL query strings
and fragments are removed before sending. The SDK transmits its raw user-agent
field only because cookieless preprocessing requires it; PostHog removes that
field after deriving the rotating hash described above. Campaign-parameter
persistence is off, and Do Not Track is honored.

Generic element autocapture, session replay, heatmaps, rage/dead-click capture,
JavaScript exception capture, console capture, network timing, person profiles,
surveys, and remote feature flags are all disabled. Only the annotated download
and Homebrew-copy controls emit interaction events; copied command text is
represented by the fixed word `install`, not read from the clipboard or DOM.
The site uses PostHog directly rather than hiding it behind a reverse proxy, so
browsers and content blockers can block it and aggregate counts can be lower
than real traffic. Signing and notarization add no website telemetry, and the
website is outside the macOS app's `PrivacyInfo.xcprivacy` declaration.

## Windows app

The Windows app (`windows/`, WinUI 3 / .NET 8) reports through the same
hosts as the table above (`us.i.posthog.com`; Sentry ingest from the release
DSN), but its projects differ:

- **Crash reporting → its own separate Sentry project** (`burrow-windows`),
  isolated from the macOS `burrow` project.
- **Analytics → the *same* PostHog project as macOS.** PostHog's free plan
  caps an org at one project, so rather than gate this on a paid upgrade the
  Windows app reuses the macOS project and tags every event with
  **`platform: "windows"`** (plus `$lib: "burrow-win"`) so the two platforms
  filter apart cleanly in dashboards. macOS events now carry `platform: "macos"`.

Either way nothing here changes the macOS pipeline. Client code:
[`windows/Services/AppTelemetry.cs`](windows/Services/AppTelemetry.cs) (both
telemetry paths) and
[`windows/Services/TelemetryConfig.cs`](windows/Services/TelemetryConfig.cs).

Same ground rules, enforced the same way:

- **Opt-out, on by default.** One switch — **Settings → Share crash reports &
  analytics** — gates both (`BurrowSettings.TelemetryEnabled`). Off → PostHog
  is hard-muted and Sentry is `Close()`d, immediately.
- **Inert without keys.** DSN/key are **baked into the assembly at build time**
  (MSBuild `AssemblyMetadata`, see `BurrowWin.csproj`) from the
  **`BURROWWIN_SENTRY_DSN`**, **`BURROWWIN_POSTHOG_API_KEY`**, and optional
  **`BURROWWIN_POSTHOG_HOST`** env vars a release build sets — exactly as the
  macOS build bakes them into Info.plist. A runtime env var is honored only as
  a dev fallback (shipped builds carry the baked values; end users have none of
  these set). The CI path is `.github/workflows/windows-release.yml`, which
  injects them from repo secrets. The Sentry DSN is the separate
  `burrow-windows` project's; the PostHog key is the **same** one the macOS
  build uses (shared project). Local/dev builds set none, so telemetry never
  starts.
- **Identity is random.** An anonymous GUID persisted at
  `%LOCALAPPDATA%\BurrowWin\telemetry-id` — never derived from hardware,
  serial, or account.
- **No PII.** `Sanitize()` drops the same blocked keys, anything
  non-primitive, and any string that looks like a `\Users\` path. Events carry
  `$ip = "0"`. Sentry runs `SendDefaultPii = false`, no traces
  (`TracesSampleRate = 0`), no auto session tracking, and the machine name is
  stripped in `BeforeSend`.

PostHog on Windows is delivered by a small hand-rolled HTTPS `POST` to
`/capture/` (no SDK), so the payload — and these guarantees — stay fully under
our control. Events wired now: `app_opened` (`cold_start`),
`telemetry_opt_in_changed` (`enabled`), plus whatever the global exception
handlers report to Sentry (`xaml_unhandled` / `domain_unhandled` /
`task_unobserved`). Super properties: `platform: "windows"`, `app_version`,
`os_version` (e.g. `Windows 10.0.26100.0`), `arch`.
