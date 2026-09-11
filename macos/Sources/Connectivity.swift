//
//  Connectivity.swift
//  Burrow
//
//  "Get Online" engine (plan §2.2, inspired by the captive-portal pain of
//  travel Wi-Fi): the device-side things that quietly block a hotspot login —
//  a VPN, a proxy, custom DNS, iCloud Private Relay — plus a captive-portal
//  probe and a reachability check. Detection is best-effort and HONEST: when we
//  can't be sure (Private Relay has no public API), we say so and hand off to
//  Settings rather than guess.
//
//  The classifiers here are pure and unit-tested; the probes (scutil / ipconfig
//  via the capture seam, CFNetwork proxy dict, a URLSession reachability GET)
//  are the impure edge and can't run in CI.
//

import Foundation
import CFNetwork

enum Connectivity {
    enum Status: String { case ok, warn, blocked, info, unknown }

    struct Check: Identifiable, Equatable {
        let id: String
        let title: String
        let status: Status
        let detail: String
        /// One-line "where to fix it" hint shown under the row (Settings path).
        let settingsHint: String?
    }

    /// Apple's captive-portal probe endpoint. A clean network returns 200 with a
    /// tiny body containing "Success"; a portal intercepts with anything else.
    static let probeURL = URL(string: "http://captive.apple.com/hotspot-detect.html")! // greenlight:ignore http-not-https

    // MARK: - Pure classifiers (unit-tested)

    /// Verdict from the captive probe: are we online, and is a portal intercepting?
    /// No response at all (nil) reads as offline, not a portal.
    static func captiveVerdict(body: String?, statusCode: Int?) -> (online: Bool, portal: Bool) {
        guard let body, let statusCode else { return (online: false, portal: false) }
        if statusCode == 200, body.contains("Success") { return (online: true, portal: false) }
        return (online: false, portal: true)
    }

    /// Resolvers from `scutil --dns` output — the `nameserver[N] : ADDR` lines,
    /// de-duplicated, dropping loopback (a local resolver like mDNSResponder).
    static func resolvers(fromScutilDNS text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("nameserver["), let colon = t.firstIndex(of: ":") else { continue }
            let addr = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !addr.isEmpty, addr != "127.0.0.1", addr != "::1", !seen.contains(addr) else { continue }
            seen.insert(addr); out.append(addr)
        }
        return out
    }

    private static let knownPublicDNS: Set<String> = [
        "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112", // greenlight:ignore hardcoded-ipv4
        "208.67.222.222", "208.67.220.220", "94.140.14.14", "76.76.2.0", // greenlight:ignore hardcoded-ipv4
    ]

    /// Whether the active resolvers include a well-known public DNS — the
    /// common "I set 1.1.1.1" case that can break a captive portal's redirect.
    static func usesPublicDNS(_ resolvers: [String]) -> Bool {
        resolvers.contains { knownPublicDNS.contains($0) }
    }

    /// A connected VPN from `scutil --nc list` (lines mark connected configs
    /// with "(Connected)").
    static func vpnConnected(fromScutilNC text: String) -> Bool {
        text.split(separator: "\n").contains { $0.contains("(Connected)") }
    }

    /// Whether any system proxy (HTTP/HTTPS/SOCKS/PAC) is enabled in the
    /// CFNetwork proxy dictionary.
    static func proxyActive(_ settings: [String: Any]) -> Bool {
        let keys = [
            kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPSEnable,
            kCFNetworkProxiesSOCKSEnable, kCFNetworkProxiesProxyAutoConfigEnable,
        ].map { $0 as String }
        return keys.contains { (settings[$0] as? Int) == 1 }
    }

    /// MDM enrollment from `profiles status -type enrollment` ("MDM enrollment:
    /// Yes/No"); nil when the line is absent.
    static func mdmEnrolled(fromProfilesStatus text: String) -> Bool? {
        for line in text.split(separator: "\n") where line.contains("MDM enrollment:") {
            return line.lowercased().contains("yes")
        }
        return nil
    }

    /// Default-route gateway + interface from `route -n get default`. Either may
    /// be absent (a point-to-point VPN tunnel has an interface but no gateway).
    static func defaultRoute(fromRouteGet text: String) -> (gateway: String?, interface: String?) {
        var gw: String?, iface: String?
        for raw in text.split(separator: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") { gw = String(t.dropFirst("gateway:".count)).trimmingCharacters(in: .whitespaces) }
            else if t.hasPrefix("interface:") { iface = String(t.dropFirst("interface:".count)).trimmingCharacters(in: .whitespaces) }
        }
        return (gw, iface)
    }

    // MARK: - Impure probes (best-effort, off the main thread)

    /// Run the full device-side check + captive probe and return the ranked
    /// checklist for the Get-Online pane.
    static func probeAll() async -> (checks: [Check], interface: String?) {
        async let captive = probeCaptive()
        let dns = resolvers(fromScutilDNS: shell("/usr/sbin/scutil", ["--dns"]))
        let vpn = vpnConnected(fromScutilNC: shell("/usr/sbin/scutil", ["--nc", "list"]))
        let proxy = proxyActive((CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]) ?? [:])
        let route = defaultRoute(fromRouteGet: shell("/sbin/route", ["-n", "get", "default"]))
        let iface = route.interface ?? "en0"
        let ip = shell("/usr/sbin/ipconfig", ["getifaddr", iface]).trimmingCharacters(in: .whitespacesAndNewlines)
        let mdm = mdmEnrolled(fromProfilesStatus: shell("/usr/bin/profiles", ["status", "-type", "enrollment"]))
        let probe = await captive
        let (online, portal) = captiveVerdict(body: probe.body, statusCode: probe.status)

        var checks: [Check] = []

        // Internet / captive first — the headline.
        if portal {
            checks.append(Check(id: "portal", title: NSLocalizedString("Captive portal", comment: ""),
                                status: .blocked,
                                detail: NSLocalizedString("A login page is intercepting traffic. Open it to sign in.", comment: ""),
                                settingsHint: nil))
        } else if online {
            checks.append(Check(id: "internet", title: NSLocalizedString("Internet access", comment: ""),
                                status: .ok, detail: NSLocalizedString("You're online.", comment: ""), settingsHint: nil))
        } else {
            checks.append(Check(id: "internet", title: NSLocalizedString("Internet access", comment: ""),
                                status: .blocked,
                                detail: NSLocalizedString("No response from the network. Join Wi-Fi, or the device settings below may be blocking the login page.", comment: ""),
                                settingsHint: nil))
        }

        // Device-side blockers, in the order they usually bite a hotspot login.
        checks.append(Check(id: "relay", title: NSLocalizedString("iCloud Private Relay", comment: ""),
                            status: .info,
                            detail: NSLocalizedString("If a login page won't load, turning Private Relay off often fixes it. We can't read its state, so check it manually.", comment: ""),
                            settingsHint: NSLocalizedString("Apple Account ▸ iCloud ▸ Private Relay", comment: "")))

        checks.append(Check(id: "vpn", title: NSLocalizedString("VPN", comment: ""),
                            status: vpn ? .warn : .ok,
                            detail: vpn ? NSLocalizedString("A VPN is connected — disconnect it to reach the login page.", comment: "")
                                        : NSLocalizedString("No VPN connection detected.", comment: ""),
                            settingsHint: vpn ? NSLocalizedString("Settings ▸ VPN, or the menu-bar VPN item", comment: "") : nil))

        checks.append(Check(id: "proxy", title: NSLocalizedString("Proxy", comment: ""),
                            status: proxy ? .warn : .ok,
                            detail: proxy ? NSLocalizedString("A system proxy is configured — it can block the portal.", comment: "")
                                          : NSLocalizedString("No system proxy configured.", comment: ""),
                            settingsHint: proxy ? NSLocalizedString("Wi-Fi ▸ Details ▸ Proxies", comment: "") : nil))

        let publicDNS = usesPublicDNS(dns)
        checks.append(Check(id: "dns", title: NSLocalizedString("Custom DNS", comment: ""),
                            status: publicDNS ? .warn : .ok,
                            detail: publicDNS
                                ? String(format: NSLocalizedString("Using %@ — a public resolver can stop a portal from redirecting you.", comment: ""), dns.first ?? "")
                                : NSLocalizedString("DNS looks default for this network.", comment: ""),
                            settingsHint: publicDNS ? NSLocalizedString("Wi-Fi ▸ Details ▸ DNS", comment: "") : nil))

        if mdm == true {
            checks.append(Check(id: "mdm", title: NSLocalizedString("Managed device (MDM)", comment: ""),
                                status: .warn,
                                detail: NSLocalizedString("This Mac is managed. A configuration profile may pin DNS/proxy or block changes — some fixes below can be locked.", comment: ""),
                                settingsHint: NSLocalizedString("Settings ▸ General ▸ Device Management", comment: "")))
        }
        if let gw = route.gateway, !gw.isEmpty {
            checks.append(Check(id: "gateway", title: NSLocalizedString("Router", comment: ""),
                                status: .ok, detail: gw, settingsHint: nil))
        }
        if !ip.isEmpty {
            checks.append(Check(id: "ip", title: NSLocalizedString("IP address", comment: ""),
                                status: .ok, detail: "\(ip)  ·  \(iface)", settingsHint: nil))
        }

        return (checks, route.interface)
    }

    /// GET the captive probe with a short timeout; returns the body + status.
    static func probeCaptive() async -> (body: String?, status: Int?) {
        var req = URLRequest(url: probeURL)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode
            return (String(decoding: data, as: UTF8.self), code)
        } catch {
            return (nil, nil)
        }
    }

    /// Capture a short command's stdout via the shared engine seam.
    private static func shell(_ path: String, _ args: [String]) -> String {
        (try? EngineRunner.shared.capture(MoCommand(target: .executable(path), args: args, timeout: 8)))?.stdout ?? ""
    }

    // MARK: - One-click fixes
    //
    // Hotspot Guide is App-Sandboxed, so every fix it offers is just a deep-link
    // the user has to perform. Burrow isn't sandboxed — these actually run, with
    // one admin prompt through the shared PrivilegeBroker. (Private Relay / VPN
    // have no programmatic toggle even unsandboxed, so those stay deep-links.)

    enum Fix: Equatable { case flushDNS, renewDHCP }

    /// Run a fix with a single admin prompt. Blocks on the auth dialog — call
    /// off the main thread. Returns a user-facing result.
    static func run(_ fix: Fix, interface: String?) -> (ok: Bool, message: String) {
        let iface = interface ?? "en0"
        switch fix {
        case .flushDNS:
            return classify(elevate(.flushDNS),
                            ok: NSLocalizedString("DNS cache flushed.", comment: ""),
                            fail: NSLocalizedString("Couldn't flush the DNS cache.", comment: ""))
        case .renewDHCP:
            return classify(elevate(.renewDHCP, interface: iface),
                            ok: String(format: NSLocalizedString("Renewed the DHCP lease on %@.", comment: ""), iface),
                            fail: NSLocalizedString("Couldn't renew the DHCP lease.", comment: ""))
        }
    }

    /// Prefer the privileged helper, fall back to the osascript broker.
    ///
    /// Through the helper these are TYPED operations: the daemon holds the
    /// argv and the interface name is validated against the machine's real
    /// interfaces before it reaches a process. That removes the root shell
    /// this path used to need — flushing DNS was previously
    /// `/bin/sh -c "dscacheutil -flushcache; killall -HUP mDNSResponder"`
    /// running as root, with a command string for the shell to parse.
    ///
    /// The fallback keeps that older shape, unchanged, for anyone who hasn't
    /// installed the helper.
    private static func elevate(_ operation: HelperOperation,
                                interface: String? = nil) -> ElevatedOutcome {
        let client = PrivilegedHelperClient.shared
        if client.registrationStatus == .enabled, client.versionSkew() == .matched {
            return client.run(operation: operation, interface: interface) { _ in }
        }

        let broker = SystemPrivilegeBroker()
        switch operation {
        case .flushDNS:
            return broker.openElevated(executable: "/bin/sh",
                                       args: ["-c", "dscacheutil -flushcache; killall -HUP mDNSResponder"])
        case .renewDHCP:
            return broker.openElevated(executable: "/usr/sbin/ipconfig",
                                       args: ["set", interface ?? "en0", "DHCP"])
        default:
            return .launchFailed
        }
    }

    private static func classify(_ outcome: ElevatedOutcome, ok: String, fail: String) -> (ok: Bool, message: String) {
        switch outcome {
        case .exited(0):     return (true, ok)
        case .authCancelled: return (false, NSLocalizedString("Cancelled.", comment: ""))
        case .refused(let reason): return (false, reason.userExplanation)
        default:             return (false, fail)
        }
    }
}
