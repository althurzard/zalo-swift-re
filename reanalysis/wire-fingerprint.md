# Wire fingerprint of the official Zalo PC client (26.10.20)

Ground truth for everything Olaz puts on the network. Captured 2026-11-08 passively
from the official client running on this machine: it was relaunched once with
`--remote-debugging-port=9333`, its `navigator` identity read over CDP, and its own
API traffic observed via `Network.requestWillBeSent*` (nothing was sent or clicked
in the app). The client is Electron 22.3.9 / Chromium 108.0.5359.215, User-Agent
`ZaloPC-darwin-23v694` (set by main with `setUserAgent`, whole UA replaced).

The constants live in `Sources/Olaz/ZaloRuntime/ClientFingerprint.swift`; the proxy
applies them in `NetworkProxy.applyClientHeaders` / `MediaLoader.applyClientHeaders`.
When `ZaloRuntime.pinned` moves to a new Zalo release, re-capture and update both.

## Identity

| value | official |
|---|---|
| `navigator.userAgent` | `ZaloPC-darwin-23v694` |
| `navigator.userAgentData.brands` | `Not?A_Brand` v8, `Chromium` v108 |
| `navigator.userAgentData.platform` | `macOS` |
| `navigator.languages` | `en-US` (single entry on this machine) |
| `navigator.platform` | `MacIntel` |

## API XHR/fetch (axios, from the `file://` renderer page) — actual wire headers

```
:method: GET/POST            (HTTP/2)
accept: application/json, text/plain, */*
accept-encoding: gzip, deflate, br
accept-language: en-US
content-type: application/x-www-form-urlencoded   (axios sends it, GETs included)
cookie: zpw_sek=…; zpw_sek=…                      (two matching cookies on chat.zalo.me
                                                    hosts: the .zalo.me and .chat.zalo.me
                                                    domain cookies — see
                                                    ZaloMainProcess.sessionCookieDomains)
sec-ch-ua: "Not?A_Brand";v="8", "Chromium";v="108"
sec-ch-ua-mobile: ?0
sec-ch-ua-platform: "macOS"
sec-fetch-dest: empty
sec-fetch-mode: cors
sec-fetch-site: cross-site
user-agent: ZaloPC-darwin-23v694
```

Notably **absent** on the wire: `origin` and `referer` — a `file://` page's XHRs in
Chromium carry neither. (The WebSocket upgrade is different: browsers always send
`Origin` there; Electron serialises the file origin as `Origin: file://`, which the
proxy already sets.)

Query convention: every API URL carries `zpw_ver=694&zpw_type=23`; `client_version=694`
comes from `getClientVersion(){return 694}` in `main-dist/main.js` — Olaz reads that
number out of the installed runtime (`OfficialZaloInstall.clientVersion(fromMainJS:)`)
instead of hardcoding it, so a newer runtime keeps reporting its own version.

## Media loads

`<img>` (no-cors) adds `accept: image/webp,image/apng,image/*,*/*;q=0.8`,
`sec-fetch-dest: image`, `sec-fetch-mode: no-cors` instead of the XHR values;
the rest of the header set is the same. `MediaLoader` mirrors the two flavours
(`RequestFlavour.image` / `.cors`).

## What Olaz does about the rest

- Multipart bodies are rebuilt with Chromium's own boundary format
  (`----WebKitFormBoundary` + 16 chars of `[0-9A-Za-z]`) — the old
  `----OlazFormBoundary…` label was a positive server-visible identifier.
- `computer_name` (sent by getServerInfo / reqqr / password login / logout) comes
  from `gethostname()` like Node's `os.hostname()`; `ProcessInfo.hostName`
  lower-cases the name on this machine and disagrees.
- `os.networkInterfaces()` is real (getifaddrs, Node's entry shape, order preserved —
  the QoS reporter takes the first non-internal IPv4 as the local IP).
- URLSession's own `Accept-Language` (`en-US,en;q=0.9`) and `Accept-Encoding`
  (`gzip, deflate`) are overridden with Chromium's values; URLSession decodes both
  gzip and brotli even when the header is set explicitly (verified locally).

## TLS / HTTP-2 fingerprint — matched (FingerprintHelper)

The one gap URLSession could never close is now closed by `FingerprintHelper/`: a Go
child process (`olaz-fingerprint-helper`, built by `scripts/build-fingerprint-helper.sh`,
bundled into the app) that performs the requests with Chromium 108's exact handshake.

- `NetworkProxy` (renderer HTTP + the realtime websocket) and `MediaLoader` (images,
  files, header-authenticated downloads) route through it; URLSession and the DoH path
  remain as automatic fallbacks, used only when the helper cannot start or dies —
  an upstream failure (timeout, HTTP error) is a real result and is never retried on
  the other stack, so a retry never switches fingerprint.
- Verified through https://tls.peet.ws (2026-11-08): JA3
  `771,4865-…-47-53,0-23-65281-10-11-35-16-5-13-18-51-45-43-27-17513-21,29-23-24,0`
  (Chrome's famously stable desktop JA3), JA4 `t13d1516h2_8daaf6152771_e5627efa2ab1`
  (Chrome 97–110), and Chrome's Akamai HTTP/2 fingerprint
  `1:65536;2:0;3:1000;4:6291456;6:262144|15663105|0|m,a,s,p`.
- Built on `bogdanfinn/tls-client` (BSD-3) with its `Chrome_108` profile (utls
  ClientHello + patched http2 with Chrome's SETTINGS/priorities, connection pooling);
  websockets dial through the same ClientHello spec (`bogdanfinn/utls` + gorilla fork).
  Header order is pinned via fhttp's `HeaderOrderKey` — headers not registered there
  are silently dropped, custom headers included.
- When `ZaloRuntime.pinned` moves to a newer Zalo, check whether its Electron moved
  (the app bundle's `Electron Framework` version) and re-capture; the profile name
  lives in `FingerprintHelper/main.go` (`profileName`) and `profiles.Chrome_108`.

Operational notes: the helper speaks the protocol documented in
`FingerprintHelper/protocol.go` over a unix socket in `~/Library/Application Support/Olaz`;
`FP_DEBUG=<file>` logs its received requests. Do not `cp` a new binary over
`build/olaz-fingerprint-helper` — rebuild in place (`scripts/build-fingerprint-helper.sh`),
an overwritten binary gets killed at exec (macOS provenance).

## Remaining, accepted differences
- **Telemetry Olaz does not send**: main-process Sentry (sentrypc.api.zalo.me),
  Google Analytics (`log-ga`), the binary updater's check, call-log uploads, and —
  remote-gated — the action/zlog uploads (`upload_log_client`). The renderer's QoS
  reporter does run (qos.talk.zing.vn/api/qos/uploadpc), unchanged from official.
- **DoH fallback path** (`PinnedHTTPSClient`) and the URLSession fallbacks generally:
  Apple's fingerprint — used only when the helper is unavailable or (DoH) when system
  DNS fails for a Zalo CDN host.
- The helper's websocket upgrade offers `permessage-deflate` like Chromium, but with
  gorilla's `client_max_window_bits=15` spelling rather than Chromium's valueless form.
