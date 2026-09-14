# Snoopy 0.2.0

An audit-and-fix release. The inspector now holds up on the payloads and workflows that
previously defeated it, and pausing no longer corrupts the capture.

## Fixed

- **Large response bodies froze the window.** A body was pretty-printed into a single
  `Text` inside a scroll view with an unbounded height proposal, so every line was laid
  out synchronously on the main thread. Bodies now render in lazy chunks, so the cost is
  the size of the window rather than the size of the payload. A 14.5 MB, 309,240-line
  JSON response opens in under a second.
- **The JSON tree refused ordinary payloads.** Its 60,000-node budget was below what a
  normal list endpoint returns, and exceeding it fell through to the text path that then
  hung. The budget is now 400,000 and large containers page 200 children at a time, so an
  array of 20,000 elements opens instantly with a row to load more.
- **Pausing invented traffic.** Only requests were gated on the pause flag, so every
  response that arrived while paused created a row from nothing — no URL, no host, and a
  start time of whenever the response landed. Those rows survived the pause and were
  written to HAR exports as if they were real. Only a request opens a row now; exchanges
  already in flight still complete.
- **Rows never updated in place.** Any exchange whose response arrived a moment after its
  request kept rendering as a pending "…" forever, even though the body had been captured.
- **The app froze on launch** for as long as CoreSimulator took to answer, and could hang
  outright on a simulator with many apps installed.
- **Repeated headers were collapsed.** A response setting three cookies showed one, and the
  HAR export agreed with it. Headers are now ordered and duplicate-preserving.
- **The release DMG could disagree with the app inside it** — `release.sh 0.2.0` would
  have produced a correctly named DMG containing an app still calling itself 0.1.0. The
  version now flows from the release command into the bundle, and the build fails if they
  ever diverge.
- Stale `/tmp/snoopy-*.sock` files are cleaned up; cURL quoting handles quotes in URLs,
  cookies and bodies; non-ASCII bodies are clipped on a byte budget rather than a
  character count.

## New

- **A real recording flow.** One toolbar control that is both the indicator and the switch
  (Waiting for app / Recording / Paused, ⌘R). Previously there was no way to start at all —
  only a Pause toggle — and nothing reported whether the hook had attached.
- **A status bar** naming every attached process and pid, what is held in memory, and what
  the live row window is hiding.
- **Sessions**: ⌘S writes the whole capture — bodies, headers, timing, errors — to a
  `.snoopy` file and ⌘O reads it back. HAR remains for interchange; it cannot represent an
  exchange's state or error.
- **Deep search** over headers and text bodies, off by default.
- **Save Body / Copy Body**, and Copy path / Copy value in the JSON tree.
- The row cap now applies only while recording, so a finished capture is fully scrollable.

## Known limitations

- Injection engine only. `WKWebView` and non-`URLSession` stacks are not yet captured
  (the MITM proxy engine is the next milestone).
- Apps launched from Xcode need two scheme environment variables (Snoopy provides a
  Copy button); apps launched from Snoopy need no setup.

## Requirements

- macOS 14 or later, Xcode 15 or later with iOS simulators installed.
