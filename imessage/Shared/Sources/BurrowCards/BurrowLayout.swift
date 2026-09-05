//
//  BurrowLayout.swift
//  Burrow Cards — declarative iMessage card schema.
//
//  Mirrors tools/burrow-alerts/src/burrowlayout.ts field-for-field. The sidecar
//  (or any agent) emits BurrowLayout JSON; this signed extension renders it as
//  native SwiftUI from a FIXED vocabulary — no downloaded code, no eval. The
//  JSON arrives base64url-encoded in the message URL as `?p=<payload>`.
//
//  Node vocabulary derived from HermesShare (MIT, time-attack/HermesShare),
//  trimmed and re-branded for Burrow's system-health cards.
//

import Foundation

public struct BurrowLayout: Codable, Equatable {
    public var version: Int
    public var title: String
    public var subtitle: String?
    public var accentColorHex: String?
    public var root: BurrowNode
    public var actions: [BurrowAction]?
}

public struct BurrowAction: Codable, Equatable {
    public var id: String
    public var label: String
    public var systemImage: String?
    public var deepLinkURL: String

    /// Card JSON may select a supported Burrow pane, never an arbitrary app URL.
    public var burrowURL: URL? {
        guard let components = URLComponents(string: deepLinkURL),
              components.scheme == "burrow", components.host == "action",
              components.queryItems?.count == 1,
              components.queryItems?.first?.name == "id",
              components.queryItems?.first?.value == id,
              ["clean", "inspect"].contains(id) else { return nil }
        return components.url
    }
}

/// The recursive node tree. `type` is the discriminator, matching the TS union.
public indirect enum BurrowNode: Equatable {
    case vstack(spacing: Double?, children: [BurrowNode])
    case hstack(spacing: Double?, children: [BurrowNode])
    case section(title: String?, children: [BurrowNode])
    case text(text: String, role: String?)
    case statusBadge(label: String, colorHex: String?)
    case progressBar(value: Double, colorHex: String?)
    case gauge(label: String, value: Double, colorHex: String?)
    case keyValueRow(key: String, value: String)
}

extension BurrowNode: Codable {
    private enum K: String, CodingKey {
        case type, spacing, children, title, text, role, label, colorHex, value, key
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "vstack":
            self = .vstack(spacing: try c.decodeIfPresent(Double.self, forKey: .spacing),
                           children: try c.decode([BurrowNode].self, forKey: .children))
        case "hstack":
            self = .hstack(spacing: try c.decodeIfPresent(Double.self, forKey: .spacing),
                           children: try c.decode([BurrowNode].self, forKey: .children))
        case "section":
            self = .section(title: try c.decodeIfPresent(String.self, forKey: .title),
                            children: try c.decode([BurrowNode].self, forKey: .children))
        case "text":
            self = .text(text: try c.decode(String.self, forKey: .text),
                         role: try c.decodeIfPresent(String.self, forKey: .role))
        case "statusBadge":
            self = .statusBadge(label: try c.decode(String.self, forKey: .label),
                                colorHex: try c.decodeIfPresent(String.self, forKey: .colorHex))
        case "progressBar":
            self = .progressBar(value: try c.decode(Double.self, forKey: .value),
                                colorHex: try c.decodeIfPresent(String.self, forKey: .colorHex))
        case "gauge":
            self = .gauge(label: try c.decode(String.self, forKey: .label),
                          value: try c.decode(Double.self, forKey: .value),
                          colorHex: try c.decodeIfPresent(String.self, forKey: .colorHex))
        case "keyValueRow":
            self = .keyValueRow(key: try c.decode(String.self, forKey: .key),
                                value: try c.decode(String.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "Unknown BurrowNode type '\(type)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case let .vstack(spacing, children):
            try c.encode("vstack", forKey: .type)
            try c.encodeIfPresent(spacing, forKey: .spacing)
            try c.encode(children, forKey: .children)
        case let .hstack(spacing, children):
            try c.encode("hstack", forKey: .type)
            try c.encodeIfPresent(spacing, forKey: .spacing)
            try c.encode(children, forKey: .children)
        case let .section(title, children):
            try c.encode("section", forKey: .type)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encode(children, forKey: .children)
        case let .text(text, role):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(role, forKey: .role)
        case let .statusBadge(label, colorHex):
            try c.encode("statusBadge", forKey: .type)
            try c.encode(label, forKey: .label)
            try c.encodeIfPresent(colorHex, forKey: .colorHex)
        case let .progressBar(value, colorHex):
            try c.encode("progressBar", forKey: .type)
            try c.encode(value, forKey: .value)
            try c.encodeIfPresent(colorHex, forKey: .colorHex)
        case let .gauge(label, value, colorHex):
            try c.encode("gauge", forKey: .type)
            try c.encode(label, forKey: .label)
            try c.encode(value, forKey: .value)
            try c.encodeIfPresent(colorHex, forKey: .colorHex)
        case let .keyValueRow(key, value):
            try c.encode("keyValueRow", forKey: .type)
            try c.encode(key, forKey: .key)
            try c.encode(value, forKey: .value)
        }
    }
}

// MARK: - Transport (base64url `?p=` payload, matching burrowlayout.ts)

public enum BurrowTransport {
    public enum Error: Swift.Error { case missingPayload, badBase64, encodeFailed, unsupportedPayload }

    public static func decode(url: URL) throws -> BurrowLayout {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let p = comps.queryItems?.first(where: { $0.name == "p" })?.value else {
            throw Error.missingPayload
        }
        guard p.utf8.count <= 90_000 else { throw Error.unsupportedPayload }
        guard let data = Data(base64URLEncoded: p) else { throw Error.badBase64 }
        let layout = try JSONDecoder().decode(BurrowLayout.self, from: data)
        guard layout.version == 1 else { throw Error.unsupportedPayload }
        return layout
    }

    /// Encode a layout into `base?p=<base64url>` — the inverse of the sidecar's
    /// encodeLayoutURL. Used by the extension's compose gallery to insert cards.
    public static func encode(base: URL, layout: BurrowLayout) throws -> URL {
        let data = try JSONEncoder().encode(layout)
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.removeAll { $0.name == "p" }
        items.append(URLQueryItem(name: "p", value: data.base64URLEncodedString()))
        comps?.queryItems = items
        guard let url = comps?.url else { throw Error.encodeFailed }
        return url
    }
}

extension Data {
    /// Decode a URL-safe base64 string (RFC 4648 §5): `-_` alphabet, padding optional.
    init?(base64URLEncoded s: String) {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let d = Data(base64Encoded: b64) else { return nil }
        self = d
    }

    /// Encode to URL-safe base64 without padding — matches Node's `base64url`.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
