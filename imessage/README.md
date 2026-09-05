# Burrow Cards — iMessage extension

Native iMessage cards for Burrow alerts, described by JSON, rendered on-device by a signed SwiftUI renderer.

The [alert sidecar](../tools/burrow-alerts) (or any agent) emits a **BurrowLayout** JSON document per message; this fixed, Apple-signed extension draws it as native SwiftUI. The JSON describes *what* to show (a disk gauge, a free-space row, a "clean" button) — it never executes code. Sent over Photon `customizedMiniApp()`, base64url-encoded in the message URL as `?p=<payload>`.

> **Why not just send SwiftUI from the server?** Apple doesn't let apps run downloaded UI code. So we ship a fixed renderer and send declarative JSON that selects from a known vocabulary — the [Scriptable](https://scriptable.app)/[HermesShare](https://github.com/time-attack/HermesShare) model. App Store legal, no web views, no eval.

## Status

Buildable end-to-end — `xcodegen generate` + the host scheme compiles clean for the iOS Simulator (`** BUILD SUCCEEDED **`). Set your Team ID to sideload to a device.

| Piece | State |
|---|---|
| `tools/burrow-alerts/src/burrowlayout.ts` | ✅ schema + `?p=` transport, unit-tested (round-trip) |
| `Shared/Sources/BurrowCards/BurrowLayout.swift` | ✅ matching Codable schema + base64url encode/decode |
| `Shared/Sources/BurrowCards/BurrowLayoutRenderer.swift` | ✅ JSON tree → native SwiftUI (fixed vocabulary) |
| `Shared/Sources/BurrowCards/Samples.swift` | ✅ disk / CPU / cleanup sample cards |
| `BurrowCardsExtension/` (MSMessagesAppViewController) | ✅ decode `?p=` → render; compose gallery inserts samples; deep-links |
| `BurrowCardsHost/` (host app + debug harness) | ✅ picker + live-JSON paste, renders with no send |
| `project.yml` (xcodegen) | ✅ host app embeds the extension |

The Swift schema matches the TS round-trip test byte-for-byte — change one side, change both.

## Test it three ways

1. **Harness (fastest, no sending):** run the **BurrowCardsHost** scheme on a Simulator or your iPhone. Flip the sample picker, or paste live JSON and hit Render. This exercises the renderer directly.
2. **Extension in Messages:** run the **BurrowCards** scheme (or open Messages after installing the host). Tap `+` → Burrow Cards → the compose gallery inserts a sample card; tap the bubble to expand, tap an action to fire the `burrow://` deep link.
3. **Real send from the sidecar:** set the `card` block (below) and `cd tools/burrow-alerts && bun run check:card`. The sidecar emits a `BurrowLayout` in the `?p=` URL; your extension renders it.

## Reality check

- **iOS-only.** iMessage app extensions don't run in macOS Messages. You receive cards on your iPhone.
- **Requires the extension installed on the *receiving* device.** Without it, the message falls back to a standard bubble (thumbnail + caption). The sidecar already sends a text fallback for everyone else — cards are a per-device upgrade, not a hard dependency.
- iOS 26+ / Xcode 26+.

## Build & sideload (your own iPhone)

```bash
brew install xcodegen
cd imessage
xcodegen generate          # once project.yml lands
open BurrowCards.xcodeproj
```

Set your Apple **Team ID** in `project.yml` (`DEVELOPMENT_TEAM`) or Xcode → Signing & Capabilities (both the host app and the extension). A free Apple account works for sideloading to your own device. Build/run the host app to your iPhone; the extension installs with it. Then in Messages → `+` → Burrow Cards.

## Wiring the sidecar

Point `tools/burrow-alerts` at this extension:

```jsonc
// config.local.json
"card": {
  "appName": "Burrow",
  "extensionBundleId": "dev.caezium.Burrow.cards.extension",
  "teamId": "<your Apple Team ID>",
  "url": "https://burrow.henryzh.dev/card"   // base; sidecar appends ?p=<layout>
}
```

The sidecar builds a `BurrowLayout` (`src/burrowlayout.ts`), base64url-encodes it into the `url` as `?p=`, and sends via `customizedMiniApp`. `bun run check:card` fires a sample.

## Schema

`BurrowLayout` = `{ version, title, subtitle?, accentColorHex?, root, actions? }`. `root` is a recursive `BurrowNode`:

`vstack` · `hstack` · `section` · `text` · `statusBadge` · `progressBar` · `gauge` · `keyValueRow`

Actions are `{ id, label, systemImage?, deepLinkURL }`. Only the known `burrow://action?id=clean` and `id=inspect` routes are accepted. These open a local Burrow app when available; they cannot launch an app on another device. On an iPhone without a handler, the extension explains that the owner should open Burrow on the Mac.

## Acknowledgments

Node vocabulary and the "declarative JSON → signed native renderer" approach are derived from [**HermesShare**](https://github.com/time-attack/HermesShare) (MIT). Burrow Cards trims the schema to system-health alerts and re-brands the transport/deep-link scheme.
