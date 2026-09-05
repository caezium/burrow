import Foundation

@main
struct TransportChecks {
    static func main() throws {
        var layout = BurrowSamples.disk
        layout.title = "磁盘 🌕"
        let base = URL(string: "https://example.com/card?mode=small&p=stale#details")!
        let encoded = try BurrowTransport.encode(base: base, layout: layout)
        let components = URLComponents(url: encoded, resolvingAgainstBaseURL: false)!
        precondition(components.queryItems!.filter { $0.name == "p" }.count == 1)
        precondition(components.fragment == "details")
        let decoded = try BurrowTransport.decode(url: encoded)
        precondition(decoded == layout)
        precondition(BurrowSamples.disk.actions!.first!.burrowURL != nil)
        precondition(BurrowAction(id: "clean", label: "Open", deepLinkURL: "https://example.com").burrowURL == nil)
        precondition(BurrowAction(id: "clean", label: "Open", deepLinkURL: "burrow://action?id=inspect").burrowURL == nil)
        layout.version = 2
        do {
            _ = try BurrowTransport.decode(url: BurrowTransport.encode(base: base, layout: layout))
            fatalError("unknown schema version was accepted")
        } catch BurrowTransport.Error.unsupportedPayload {}
        print("Transport checks passed: Unicode round-trip, payload replacement, version and action boundaries")
    }
}
