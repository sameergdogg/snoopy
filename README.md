# Snoopy

Open-source, native macOS network inspector built for the **iOS Simulator**. See every
request and response, including HTTPS bodies, with as close to zero setup as the platform allows.

Snoopy's default engine injects a small hook into the app you're debugging and reads
`URLSession` traffic **before TLS**, so it works even when the app pins certificates and
needs no proxy and no CA. See [PLAN.md](PLAN.md) for the full roadmap.

> Status: **M1 — simulator + injection engine.** The MITM proxy engine (for WKWebView and
> non-URLSession stacks) and device support are on the roadmap.

## How it works

1. You pick a booted simulator and an installed app, then press **Launch with Snoopy**.
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
- Live filter/search, record/pause, clear, copy-as-cURL, save/open sessions, and HAR export
- Repeated headers (`Set-Cookie` especially) are kept separate and in wire order, not collapsed

Not captured by the injection engine: `WKWebView`'s networking process and stacks that
bypass `URLSession` (e.g. a custom NIO or C client). Those are the job of the proxy engine (M1.5).

## Recording

Snoopy starts recording as soon as it opens, so traffic from an app you launch is captured
from its first request. The toolbar's left-hand control is both the indicator and the switch:

| State | Means |
|---|---|
| **Waiting for app** | Recording, but nothing has attached yet |
| **Recording** | At least one injected process is connected |
| **Paused** | New requests are ignored |

Press it (or **⌘R**) to pause and resume. Pausing stops *new* exchanges from being recorded;
anything already in flight still updates to completion, so nothing is left stranded as
pending. The status bar along the bottom names every attached process and its pid, so you
can always tell whether the hook actually got in.

While recording, the table shows the newest 2,000 matching rows — that bound exists only to
keep AppKit's row animation cheap under a firehose. Pause, filter, or brush a time range and
the full history becomes scrollable; the status bar says so and offers to show everything.

## Searching

The filter matches method, host, path, query and status. Toggle the magnifier beside it (or
**Capture → Search Headers and Bodies**) to extend it to headers and textual bodies. That
builds an index over what is captured, so it is off by default.

## Handing a capture to an agent

**Export for Agent…** (⇧⌘E) writes a folder shaped for investigation rather than archival,
because a single dump is the wrong shape for it — bodies are the bulk, most are irrelevant to
any one question, and one big file makes you take all of it to find any of it:

```
snoopy-export-20260919-141710/
  README.md          how to read the rest
  summary.md         24 KB — counts, hosts, failures, slowest, largest, repeats, every row
  exchanges.jsonl    96 KB — one JSON object per exchange, no bodies; grep- and jq-friendly
  bodies/            1.9 MB — one file per body, named so the right one opens directly
```

Those are the real numbers from a 120-request capture. The summary names the body file for
every row, so the reading order is summary → the two or three bodies it points at — a few KB
instead of the whole capture. Bodies are capped (64 KB each by default, and a clipped file
says so), JSON is pretty-printed, and gzipped bodies are decompressed.

**Credentials are redacted by default.** `Authorization`, `Cookie`, `Set-Cookie`, API-key
headers and query parameters like `token` or `sig` are replaced with their length. Bodies are
*not* redacted — the export's own README says so rather than implying a guarantee it cannot
make. Turn it off in **File → Redact Credentials in Exports** if you are keeping the export
local and need the real values.

## Sessions

**⌘S** writes the whole capture — bodies, headers, timing, errors and all — to a `.snoopy`
file, and **⌘O** reads one back. Use HAR export instead when another tool has to read it;
HAR has nowhere to put an exchange's state, its error, or its truncation flags, so a session
file is the lossless one.

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
| Rows shown in the table **while recording** | 2,000 | The table shows the newest matches; pause or filter to see all of them |

All three are reported in the status bar, so nothing disappears silently. Full history (within
the row limit) still feeds the timeline, the filter and the exports — the 2,000-row cap is a
live-display limit only, and it lifts entirely the moment you pause.

If the app you're debugging sends very large bodies, you can lower what the hook captures with
`SNOOPY_MAX_REQUEST_BODY` / `SNOOPY_MAX_RESPONSE_BODY` (bytes) in its environment.

## Large bodies

Response bodies are decoded off the main thread and rendered lazily, so the size of a payload
costs only what is on screen. A JSON body becomes a collapsible tree with search; containers
past 200 children page in on demand, so an array of 20,000 elements opens instantly. Past
400,000 values it falls back to pretty-printed text, still chunked and still lazy, and says
so. **Save Body** writes the exact decoded bytes to disk when a payload is better read
elsewhere.

## Updates

Snoopy updates itself, via [Sparkle](https://sparkle-project.org). It checks the releases
page in the background, downloads the new version, verifies it and installs it; the next
launch is simply the new version.

- **Snoopy → Check for Updates…** asks immediately and always answers.
- **Check for Updates Automatically** and **Download and Install Automatically** are on by
  default and can be turned off in the same menu.

Updates carry an EdDSA signature and are refused unless it matches the public key baked into
the app, in addition to Developer ID signing and notarization. The private half lives only in
the release machine's login keychain.

The feed is `appcast.xml`, attached to each GitHub release; `SUFeedURL` points at
`releases/latest/download/appcast.xml`, which GitHub keeps pointed at the newest
non-prerelease. `Scripts/release.sh` builds, signs and verifies it as part of a release —
see [docs/RELEASING.md](docs/RELEASING.md).

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
