# Snoopy

Open-source, native macOS network inspector built for the **iOS Simulator**. See every
request and response, including HTTPS bodies, with as close to zero setup as the platform allows.

Snoopy's default engine injects a small hook into the app you're debugging and reads
`URLSession` traffic **before TLS**, so it works even when the app pins certificates and
needs no proxy and no CA. See [PLAN.md](PLAN.md) for the full roadmap.

> Status: **M1 — simulator + injection engine.** The MITM proxy engine (for WKWebView and
> non-URLSession stacks) and device support are on the roadmap.

## How it works

1. You pick a booted simulator and an installed app, then press **Run with Snoopy**.
2. Snoopy relaunches the app with `libSnoopyHook.dylib` injected via
   `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`.
3. The hook swizzles `URLSession` and streams every request/response over a Unix socket
   to the Snoopy app, which shows them live.

Because the hook sees plaintext inside the app process, **certificate pinning and TLS are
irrelevant** — no root certificate is installed.

### Capturing Xcode-launched apps

When you run your app from Xcode, Xcode owns the launch, so add two environment variables
to your scheme (Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables).
Use the **Copy Xcode env vars** button in Snoopy to get the exact values:

```
DYLD_INSERT_LIBRARIES = /path/to/Snoopy.app/Contents/Resources/libSnoopyHook.dylib
SNOOPY_SOCKET         = /tmp/snoopy-<pid>.sock
```

## What's captured

- Method, URL, wall-clock timestamp, request/response headers and bodies (JSON pretty-print, raw, hex, image preview)
- Status, timing, and — for delegate-based sessions — DNS/connect/TLS/wait waterfall, protocol, remote IP
- Covers completion-handler, delegate, `async`/`await`, and `URLSession.shared` paths (Alamofire, Get, etc.)
- Live filter/search, pause, clear, copy-as-cURL, and HAR export

Not captured by the injection engine: `WKWebView`'s networking process and stacks that
bypass `URLSession` (e.g. a custom NIO or C client). Those are the job of the proxy engine (M1.5).

## Timeline

A live activity strip sits above the request list: one stacked bar per time slice, coloured by
outcome (green ok, orange 4xx, red 5xx/failed, grey in-flight). **Drag across it to scope the
list to a time range**; click once to clear. It respects the text filter, so you can see when
calls matching a search actually happened.

## Working with long captures

A chatty app produces a lot of traffic, so Snoopy bounds what it holds:

| Limit | Default | What happens past it |
|---|---|---|
| Rows retained | 10,000 | Oldest rows are dropped |
| Body bytes retained | 256 MB | Oldest **bodies** are released; their rows and sizes stay |
| Rows shown in the table | 1,000 | The table shows the newest matches; narrow with the filter or the timeline brush |

All three are reported in the timeline header, so nothing disappears silently. Full history
(within the row limit) still feeds the timeline, the filter and HAR export — the 1,000-row cap
is a display limit only, and brushing an earlier time range shows the rows from that window.

If the app you're debugging sends very large bodies, you can lower what the hook captures with
`SNOOPY_MAX_REQUEST_BODY` / `SNOOPY_MAX_RESPONSE_BODY` (bytes) in its environment.

## Build

Requirements: Xcode 15+ (tested on Xcode 26), macOS 14+, [XcodeGen](https://github.com/yonwoo9/XcodeGen).

```sh
brew install xcodegen
xcodegen generate          # writes Snoopy.xcodeproj
open Snoopy.xcodeproj       # then Run
# or from the command line:
xcodebuild -scheme Snoopy -configuration Debug build
```

The hook dylib is built and embedded automatically by a build phase (`Scripts/build-hook.sh`).

## Repository layout

| Path | What |
|---|---|
| `Hook/` | `libSnoopyHook.dylib` — ObjC `URLSession` swizzles + socket transport (iOS Simulator target) |
| `Packages/SnoopyCore/` | `SnoopyCore` (models, body formatting, HAR) and `SnoopyIPC` (frame parser, event decoder) |
| `Snoopy/` | The macOS app (SwiftUI + AppKit): socket server, simulator service, capture store, UI |
| `spikes/` | Verified proof-of-concept experiments referenced by the plan |
| `Scripts/loadtest.py` | Replays synthetic capture traffic at a chosen rate/body size, for checking the UI under load |

## License

MIT. See [LICENSE](LICENSE).
