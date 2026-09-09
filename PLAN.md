# Snoopy — plan

Open-source, native macOS network inspector built for the iOS Simulator first. Real-time request/response
payloads, including HTTPS, with as close to zero setup as the platform allows.

Milestone 1 (M1) scope: simulator only. Physical devices, breakpoints, mocking come later.

## 1. What is wrong with the current tools

| Tool | Simulator setup | Pinned / encrypted apps | Scoping | Cost / license |
|---|---|---|---|---|
| Charles | System proxy + CA drag-and-drop, restart sim | Breaks on pinning | All Mac traffic | Paid, Java UI |
| Proxyman | One-click: system proxy + `simctl` CA install + sim reset | Breaks on pinning | All Mac traffic, filter by app name | Paid |
| mitmproxy | Manual proxy + CA, or `--mode local:<proc>` via a signed system extension | Breaks on pinning | Per-process (transparent) | OSS, Python TUI/web |
| Rockxy | Same MITM model, Swift/SwiftNIO | Pinned-host passthrough | All Mac traffic | AGPL + paid Pro binary |
| Pulse | In-app SDK, no proxy | Sees plaintext | One app | OSS, needs code in the app |

Every proxy-based tool shares the same three pains for simulator work: it hijacks the whole Mac's traffic,
it needs a CA in the simulator, and it goes dark the moment an app pins certificates. The in-process tools
(Pulse) avoid all three but require shipping an SDK inside the app.

## 2. Key insight: the simulator lets us do both, with no SDK

Simulator apps are ordinary macOS processes. Today's spikes (see `spikes/injection/README.md`) verified:

1. **Injection.** `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` loads our dylib into any simulator app via
   `simctl launch`, and a one-line swizzle of `-[NSURLSessionTask resume]` logged the plaintext POST body
   of an HTTPS request. Works on Safari too. For apps run from Xcode, the same env var goes in the scheme.
2. **CA install.** `xcrun simctl keychain <udid> add-root-cert ca.pem` trusts a root immediately, no reboot.
   RSA-2048 only. EC CAs are rejected on iOS 26.
3. **System proxy.** `networksetup` sets the macOS HTTPS proxy without sudo for admin users, and iOS 26
   simulator apps honor it (CONNECT seen). It is machine-wide, so unrelated Mac apps show up too.

So Snoopy gets two capture engines behind one UI:

| | Engine A: In-process hook (default) | Engine B: MITM proxy (fallback / "everything") |
|---|---|---|
| Setup | Pick app, press Run. Or one scheme env var in Xcode | Toggle. Snoopy installs CA + sets system proxy |
| TLS / pinning | Irrelevant, sees plaintext before TLS | Needs CA. Pinned hosts must be passed through |
| Scope | Exactly one app | Whole Mac, filtered by PID attribution |
| Covers | URLSession / CFNetwork (Alamofire, Get, etc.), URLSessionWebSocketTask | Also WKWebView, gRPC-swift/NIO, third-party SDKs with their own stacks, curl |
| HTTP/2, HTTP/3 | Free, URLSession already did it | H1 + H2 through CONNECT, QUIC falls back to TCP |
| Misses | Non-URLSession stacks, WebKit networking process | Pinned hosts, apps that ignore system proxy |

M1 ships Engine A. Engine B follows in M1.5 because the proxy core is bigger and the value for the
Duolingo-style case (pinned, encrypted, URLSession-based) comes from Engine A.

## 3. "Encryption" support

Three different things people mean by it, and how each is handled:

1. **TLS.** Engine A bypasses it. Engine B terminates it with a generated RSA-2048 root
   (`swift-certificates` + `_CryptoExtras`), per-host leaf certs cached on disk, SAN + serverAuth EKU,
   398-day validity so iOS accepts them.
2. **Certificate pinning.** Engine A: not a factor. Engine B: per-host passthrough list, auto-populated
   when a client aborts the handshake right after the certificate.
3. **Application-level encryption or encoding of bodies** (encrypted JSON, protobuf, msgpack, custom
   framing). Handled by a decoder pipeline: built-in gzip/br/zstd, JSON, form, multipart, raw protobuf
   wire decoding, msgpack. Company-specific decryption is a **JavaScriptCore plugin** loaded from a
   project folder, so the Duolingo decoder can live in the Duolingo repo and never in Snoopy. Plugin
   contract: `decode(request|response, bodyBytes, headers) -> {contentType, bytes}` plus a secrets file
   ignored by git. Ships in M2, but the body-view abstraction is designed for it from M1.

## 4. Architecture

```
┌──────────────────────────── Snoopy.app (SwiftUI + AppKit, Swift 6) ────────────────────────────┐
│  Sources sidebar   │  Live request list (filter, search, pause)  │  Detail: req / resp / timing │
│  SimulatorService (simctl list/boot/listapps/launch)      SessionStore (SQLite via GRDB)        │
│  CaptureHub: merges events from engines, dedupes, assigns ids, throttled publish to UI          │
└───────────────┬────────────────────────────────────────┬────────────────────────────────────────┘
                │ Unix domain socket, length-prefixed     │ in-process
                │ frames (protobuf)                       │
   ┌────────────┴──────────────┐              ┌───────────┴─────────────────────────────┐
   │ libSnoopyHook.dylib       │              │ ProxyEngine (SwiftNIO, NIOSSL, NIOHTTP2)│
   │ ObjC only, no Swift rt    │              │ CONNECT + MITM, CA/leaf gen, passthrough│
   │ swizzles URLSession task  │              │ PID attribution via libproc             │
   │ resume + delegate/handler │              │ system proxy set/restore (networksetup) │
   └───────────────────────────┘              └─────────────────────────────────────────┘
```

Decisions and why:

- **Swift 6 + SwiftUI/AppKit, no Electron.** Native feel is the product. Rockxy proves SwiftNIO is enough
  for the proxy. We will not copy Rockxy code (AGPL); Snoopy is MIT.
- **Hook dylib is Objective-C/C only.** Injecting a Swift dylib into an app built with a different Swift
  toolchain is fragile. ObjC runtime swizzling is stable, and the spike shows `resume` is owned by
  `NSURLSessionTask`, so one swizzle covers data, upload, download and websocket tasks.
- **Response capture without re-issuing requests.** Swizzle the task's completion handler wrapper and the
  session delegate methods (`didReceive data`, `didCompleteWithError`, `didFinishCollectingMetrics`),
  the way Pulse does. Never use a custom `URLProtocol`: it changes auth-challenge and pinning behavior,
  which is exactly what we must not disturb.
- **IPC over a Unix socket in the simulator's shared filesystem.** Simulator processes share the host
  network and can connect to a socket path under `~/Library/Application Support/Snoopy/`. Frames are
  protobuf so the schema is shared with future Android/device agents. Bodies over 1 MB are chunked and
  spooled to disk on the app side.
- **Realtime UI** is a batched publisher (60 Hz max) over an in-memory ring buffer, backed by SQLite
  for persistence, search and sessions larger than memory.
- **No system extension in M1 or M1.5.** That keeps builds free of Apple entitlements and notarization
  for contributors. The transparent proxy path (what mitmproxy's `local` mode does) is M3.

## 5. Milestones

**M0, repo bootstrap (~1 week)**
- SPM workspace: `SnoopyCore` (models, HAR, decoders), `SnoopyIPC` (protobuf schema, socket
  framing), `SnoopyHook` (ObjC dylib, iphonesimulator target only), `SnoopyProxy` (empty stub),
  `Snoopy` (macOS app). GitHub Actions: build + unit tests on macOS runner. MIT license, CONTRIBUTING.
- Bundle the hook dylib inside the app so the launch path is fully self-contained.

**M1, simulator + injection engine (~3 weeks). Exit criterion: Duolingo dev build inspected end to end.**
- Sidebar lists booted simulators and their installed apps (`simctl listapps`). "Run with Snoopy"
  launches the app with the hook injected. A "Copy Xcode scheme env var" button covers Xcode launches.
- Hook captures request line, headers, body, response status, headers, body, timing from
  `URLSessionTaskMetrics`, errors, and redirects. Streams to the app.
- Request list: live tail, pause, clear, filters (host, method, status, content type), full-text search.
  Detail: headers, body (pretty JSON with collapse, raw, hex), timing waterfall, copy as cURL.
- Session save/open (SQLite file), HAR export.
- Validation on Duolingo: add the env var to a personal scheme, confirm login and lesson flows show up,
  confirm pinned hosts are visible, measure overhead (target: unnoticeable, hook does no work on the
  app thread beyond copying bytes and enqueueing).

**M1.5, MITM proxy engine (~3 weeks)**
- SwiftNIO CONNECT proxy, TLS termination with generated leafs, HTTP/1.1 and HTTP/2, WebSocket.
- CA lifecycle: generate on first use, store key in Keychain, `simctl keychain add-root-cert` per
  simulator, status shown per simulator in the sidebar.
- System proxy toggle with guaranteed restore: previous state saved to disk before changing, restored on
  quit, SIGTERM, and on next launch if a dirty marker is found.
- PID attribution for each inbound proxy connection via `libproc` (local port to PID), used to tag
  requests with the app and to hide non-simulator traffic by default.
- Pinned-host passthrough list with auto-detect.

**M2, power features (~4 weeks)**
- Decoder plugins (JavaScriptCore) and built-in protobuf/msgpack views. Duolingo decoder lives in the
  Duolingo repo.
- Edit and replay, breakpoints, map local / map remote, response mocking.
- gRPC over HTTP/2 framing, GraphQL operation naming, diff two requests.

**M3, beyond the simulator**
- Physical iOS devices over Wi-Fi (proxy + profile) and over USB.
- Transparent per-process capture via `NETransparentProxyProvider` system extension (requires
  Developer ID signing and notarization; keep it an optional component).
- Android emulator.

## 6. Risks and mitigations

- **Xcode-launched apps need a scheme env var.** Unavoidable without a system extension. Mitigation:
  one-click copy of the exact variable, plus an `xcodebuild`-free "Run with Snoopy" for the common case.
- **Apple removes `SIMCTL_CHILD_` passthrough.** Very unlikely; Detox, Expo and Maestro depend on it.
  Engine B remains as the fallback.
- **Non-URLSession stacks in the target app.** Engine A is blind to them. Snoopy detects zero traffic from
  a running hooked app and suggests switching on Engine B.
- **Hook destabilizes the app.** Hook does nothing until the socket is connected, never throws across
  the boundary, and is disabled by a single env var. Body copies are capped and truncated with a flag.
- **Large bodies and high request rates** (image CDNs, analytics bursts). Chunked frames, disk spooling,
  UI batching. Target: 2,000 req/min with no dropped frames on an M-series Mac.
- **Distribution.** Direct download needs Developer ID + notarization. Until then: Homebrew cask from a
  GitHub release plus `xcodebuild` from source. No entitlements needed for M1 or M1.5.

## 7. Open questions for the Duolingo validation

- Which networking stack does the iOS app use for its core API, and does anything bypass URLSession
  (gRPC, a custom NIO client, a C library)? That decides whether Engine A alone covers the app.
- Is body encryption applied on top of TLS, and if so, where does the key live? That defines the first
  decoder plugin.
- Is pinning enabled in debug builds? If yes, Engine A is the only path that works without app changes.
