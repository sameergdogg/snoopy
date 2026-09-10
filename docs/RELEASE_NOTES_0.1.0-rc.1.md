# Snoopy 0.1.0-rc.1

First release candidate of Snoopy — a native macOS network inspector for the iOS Simulator.

## Highlights
- **Zero-setup capture** of iOS Simulator `URLSession` traffic by injecting a hook that
  reads requests and responses before TLS. No proxy, no certificate, works through
  certificate pinning.
- **Live inspector**: request list with filter/search, pause, and clear; per-request
  headers, timing waterfall, and copy-as-cURL.
- **Interactive JSON viewer** for request and response bodies: collapsible objects and
  arrays, search across keys and values with highlight and auto-expand, and a filter to
  hide non-matching subtrees.
- Body views for JSON, text, hex, and image; gzip/deflate decoding.
- **HAR export** of a session.
- Covers completion-handler, delegate, `async`/`await`, and `URLSession.shared` paths.

## Known limitations
- Injection engine only. `WKWebView` and non-`URLSession` stacks are not yet captured
  (the MITM proxy engine is the next milestone).
- Apps launched from Xcode need two scheme environment variables (Snoopy provides a
  Copy button); apps launched from Snoopy need no setup.

## Requirements
- macOS 14 or later, Xcode 15 or later with iOS simulators installed.
