# zalo-swift-re — Olaz

**A reverse-engineered, native macOS client for [Zalo](https://zalo.me), written in Swift.**

Olaz puts a native SwiftUI interface (Liquid Glass, sidebar + labels, native media viewer) on top of Zalo's
own client code. It does **not** re-implement Zalo's protocol. Instead it runs the **official Zalo PC renderer**
(`app.asar`) headless inside a `WKWebView` and supplies in Swift everything that Electron's preload and main
process used to provide. The UI is native SwiftUI driven by the official client's state.

Zalo PC does not need to be installed. On first launch Olaz downloads the official Zalo PC installer from VNG
(or copies an installed Zalo.app of the same version), checks VNG's code signature and keeps only `app.asar`
and `ZaloHelper.app` (calls, screenshots) in `~/Library/Application Support/Olaz/ZaloRuntime/` (~270 MB).
See [`ZaloRuntime/ZaloRuntimeInstaller.swift`](Sources/Olaz/ZaloRuntime/ZaloRuntimeInstaller.swift).

> [!IMPORTANT]
> **Unofficial project, not affiliated with or endorsed by VNG Corporation.** "Zalo" is a trademark of VNG.
> This is an interoperability and reverse-engineering research project. Using an unofficial client may
> conflict with Zalo's terms of service, so use it at your own risk with your own account.

## Features

- **Real QR login** (trusted-device QR → scan with Zalo on your phone → confirm), session restore on relaunch
- **Chat**: history and load older, send text / reply / mentions, reactions, typing, read state, realtime updates
- **Composer "+"**: photos / video, files, screenshot (Zalo's own `ZaloCap`), my contact card, reminders
- **Message actions**: forward, copy, recall, delete with undo, pin bar, star
- **Voice / video calls** through Zalo's own `ZaloCall` helper
- **E2EE conversations**, including E2EE video playback
- **Phone → PC message sync** with a native progress UI
- Contacts and friend requests, My Cloud, polls, stickers, labels, hidden chats (PIN), stranger folder,
  shared-media browser, quick switcher, native notifications

## Requirements

- macOS 26 or later, Xcode 27 (Swift 6 toolchain)
- A Zalo account and the Zalo app on your phone (for QR login)
- About 340 MB of download on first launch (Zalo PC's code, fetched from VNG)

Zalo allows **one desktop (PC) session per account**. If the official Zalo PC is also running, quit it while
using Olaz.

## Build & run

```bash
git clone https://github.com/qnguyen3/zalo-swift-re.git
cd zalo-swift-re

swift test                     # crypto parity (vs Node), asar reader, JSC/libsignal and host-script tests
./scripts/make-app.sh debug    # → build/Olaz.app (ad-hoc signed, JIT entitlement)
open build/Olaz.app            # real QR login — scan with Zalo on your phone
```

A new PC session has no message history except My Cloud, because Zalo keeps history on the phone. Use
**Đồng bộ tin nhắn từ điện thoại** (confirm on the phone) to import it.

### Release (maintainers)

```bash
xcrun notarytool store-credentials "olaz-notary" --apple-id <apple-id> --team-id <team-id>   # once
./scripts/release.sh           # → dist/Olaz-1.0.dmg + dist/Olaz-1.0.zip (Developer ID, hardened runtime, notarized, stapled)
OLAZ_VERSION=1.1 ./scripts/release.sh
```

The script signs `build/Olaz.app` with the "Developer ID Application" identity in your keychain, notarizes and
staples the app, then wraps it in a drag-to-Applications DMG that is signed, notarized and stapled as well.
Credentials stay in your keychain. Users still fetch the pinned Zalo runtime from VNG on first launch.

### Pinned Zalo version

The Zalo version is pinned in `ZaloRuntime.pinned` (version, DMG URL, SHA-256). To move Olaz to a newer Zalo,
test against it and bump the pin. Installed runtimes are upgraded in the background and switched at the next launch.
If the pinned DMG disappears from VNG's CDN, a fresh install falls back to whatever `zalo.me/download/zalo-pc` offers
(still signature-checked). `OLAZ_ZALO_DMG=pinned OLAZ_NETWORK_TESTS=1 swift test --filter ZaloRuntimeTests` runs the
install end to end.

### Developer harness

Prints every bridge/IPC call, console line and network request:

```bash
.build/debug/Olaz --engine-probe [login|main] [seconds]
OLAZ_TRACE_WORKERS=1 OLAZ_DEBUG_RESPONSES=1 OLAZ_QR_OUT=/tmp/qr.png …
```

* Engine diagnostics: `~/Library/Application Support/Olaz/logs/engine.log` (shapes only, no message content or tokens).
* Dev evaluation channel (debug builds only, off by default): `defaults write app.olaz.mac OlazDevEval -bool YES`.

## Architecture

```
SwiftUI (Liquid Glass)                     Views/, Shell/, App/
        │  @Observable ZaloEngine           ZaloRuntime/ZaloEngine.swift (+ feature extensions)
        ▼
OfficialClientHost  ── WKWebView, headless
  ├─ zalo-app:// scheme → pc-dist served straight out of Zalo's app.asar      (AsarArchive, ZaloRuntimeInstaller)
  ├─ HostScripts/network-shim.js → XHR/fetch/WebSocket proxied to URLSession   (NetworkProxy)
  ├─ HostScripts/bridge.js       → $z* preload globals, Electron IPC emulation (ZaloBridge)
  ├─ HostScripts/local-modules.js→ Node path/os/crypto objects, electron-store
  ├─ HostScripts/state-adapter.js→ official state → Swift (QR via DI container, Redux store)
  └─ HostScripts/*-adapter.js    → per-feature adapters over the official services (chat, composer, calls, …)
        │
ZaloMainProcess  ── Swift stand-in for Electron main.js: IPC channel handlers,
                    cookies (zpw_sek), zsafe-storage, keychain cipher, page hand-off
```

* **Bridge table**: `Resources/bridge-table.json` maps all 450 table-driven preload members
  to their IPC channel + type, generated from the official `preload-render.js`.
  Semantics per channel: [`reanalysis/bridge-spec.md`](reanalysis/bridge-spec.md).
* **Node parity**: `$znode.crypto` is reproduced on CommonCrypto/CryptoKit and verified
  byte-for-byte against Node (`Tests/OlazTests/RuntimeTests.swift`). The official
  client uses it to encrypt `zcid` and request params.
* **Storage**: native SQLite, as Zalo PC 26.10 runs after its IndexedDB → SQLite migration. The official data access
  layer talks to its `utility-process-sqlite` over a MessagePort channel; `HostScripts/sqlite-host.js` plays that
  process inside each page (channel broker + request protocol) and `ZaloRuntime/SQLiteHost.swift` executes the SQL on
  the system SQLite (`<userData>/sqlite/_production/<db>.db`). Installs that already hold IndexedDB data stay on the
  official "migration disabled" branch (`isMigrateFullDone→false`) until **Settings ▸ Engine ▸ Chuyển sang SQLite**;
  `OLAZ_STORAGE=idb|sqlite` overrides for a run. The legacy message search index still runs in its web worker
  (`fail_sqlite3=true`).
* **JSBridge/**: standalone JavaScriptCore runtime + WebCrypto shim + libsignal E2EE
  module, for JS-only pieces that run outside the renderer.

## Status

| Area | State |
|---|---|
| Official renderer in WKWebView, from the Zalo PC code Olaz fetches from VNG (no Zalo PC install needed) | ✅ |
| Electron main-process emulation (450-member IPC table) | ✅ login + main client paths |
| Network via Swift: cookies, UA `ZaloPC-darwin-23v694`, CSP-safe sync bridge | ✅ |
| Real QR login (trusted-device QR) → scan → confirm → session | ✅ verified end to end |
| Session restore on relaunch (no QR) | ✅ |
| Realtime WebSocket (`wsN-msg.chat.zalo.me`) | ✅ handshake + official sync commands |
| Conversation list from official services, native SwiftUI | ✅ names, groups, members, unread |
| Chat: open, history + load older, send text / reply, reactions, typing, read state, realtime | ✅ official chatbox controller + message loaders (`HostScripts/chat-adapter.js`) |
| Native chat UI (bubbles, media, quotes, reactions, composer with IME-safe Return) | ✅ `Views/ChatView.swift`, `MessageBubble.swift`, `ChatComposer.swift` |
| Composer "+": photos / video, files, screenshot, my contact card, reminder | ✅ official toolbar paths (`HostScripts/composer-adapter.js`, `ZaloEngine+Composer.swift`) |
| Message actions: forward, copy, recall, delete + undo, pin bar, star | ✅ `HostScripts/message-actions-adapter.js` |
| Voice / video calls | ✅ official `ZaloCall` helper (`CallBridge.swift`, `HostScripts/call-adapter.js`) |
| Phone → PC message sync, native Liquid Glass progress UI | ✅ official sync-v2 state machine (`HostScripts/transfer-adapter.js`, `Views/TransferView.swift`) |
| Hidden shared-worker window (Electron `sharedWorkerManager` port) | ✅ `ZaloRuntime/SharedWorkerRouter.swift` |
| CDN media when system DNS fails `*.zadn.vn` | ✅ DNS-over-HTTPS fallback with pinned-SNI TLS (`ZaloRuntime/MediaLoader.swift`), Zalo hosts only |
| Create group | 🧪 implemented over the official `createGroupV2` path, not yet verified against a live account |
| Native SQLite backend (Zalo 26.10 migrates new sessions to SQLite) | ✅ fresh installs; existing IndexedDB installs switch from Settings (no data migration: re-sync from the phone) |

## Reverse-engineering notes

* [REVERSE-ENGINEERING-NOTES.md](REVERSE-ENGINEERING-NOTES.md): how the original Zalo PC app (Electron 22) is
  packaged and structured, and why the renderer can be hosted outside Electron.
* [reanalysis/bridge-spec.md](reanalysis/bridge-spec.md): the preload bridge (`window.$z*`), IPC channels and
  their semantics, written as a spec for a Swift/WKWebView host.
* [reanalysis/bridge-table.json](reanalysis/bridge-table.json): machine-readable channel table.
* Comments at the top of each `HostScripts/*-adapter.js` document the official code paths each feature drives.

## What is (and isn't) in this repo

* **The Zalo runtime is not included.** Each user's Olaz downloads it from VNG and checks VNG's signature.
* **Zalo's brand assets, UI string table and other files from the official bundle are not included.** They're
  gitignored (see [.gitignore](.gitignore)). To regenerate them for research, extract them from your own copy of
  Zalo PC.
* **One third-party file is vendored**: [`Sources/Olaz/JSModules/vendor/libsignal-protocol.js`](Sources/Olaz/JSModules/vendor/libsignal-protocol.js),
  VNG's fork of [signalapp/libsignal-protocol-javascript](https://github.com/signalapp/libsignal-protocol-javascript),
  taken from Zalo PC 26.10.20 (`pc-dist/libs/libsignal-protocol.static.js`). Upstream is licensed **GPL-3.0**, so
  this build is redistributed under GPL-3.0. Only the standalone `JSBridge` E2EE module and its tests use it. The live
  client runs the copy inside the `app.asar` it downloads.

## License

Olaz is free software, licensed under the [GNU General Public License v3.0](LICENSE).
Copyright © 2026 Quan Nguyen.
