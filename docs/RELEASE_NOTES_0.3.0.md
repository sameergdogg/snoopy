# Snoopy 0.3.0

Two additions: a capture export shaped for handing to an agent, and real auto-updates.

## Auto-updates

Snoopy now updates itself. It checks its releases page in the background, downloads the new
version, verifies it, and installs it — the next time you open Snoopy it is simply the new
version. No downloading a DMG, no dragging anything to Applications.

- **Snoopy → Check for Updates…** asks immediately and always answers.
- **Check for Updates Automatically** and **Download and Install Automatically** are both on
  by default and can be turned off in the same menu.
- Updates are signed with an EdDSA key and refused if the signature does not match, on top of
  the existing Developer ID signature and notarization.

Built on [Sparkle](https://sparkle-project.org). Note that 0.2.0 has no updater in it, so the
hop from 0.2.0 to 0.3.0 is the last one you have to make by hand.

## Export for Agent

**File → Export for Agent…** (⇧⌘E) writes a capture as a folder meant to be investigated
rather than archived. A single dump is the wrong shape for that: bodies are the bulk of a
capture, most are irrelevant to any given question, and one big file makes you take all of it
to find any of it.

```
snoopy-export-20260919-141710/
  README.md          how to read the rest
  summary.md          24 KB — counts, hosts, failures, slowest, largest, repeats, every row
  exchanges.jsonl     96 KB — one JSON object per exchange, no bodies
  bodies/            1.9 MB — one file per body
```

Those are the real sizes from a 120-request capture. `summary.md` leads with what an
investigation usually starts from — failures, slowest calls, largest responses, repeated
endpoints — then lists every exchange with the path of its body, so the reading order is the
summary and then the two or three bodies it points at. `exchanges.jsonl` is one object per
line, for `grep` and `jq`. Bodies are capped per file, JSON is pretty-printed, and gzipped
bodies are decompressed.

**Credentials are redacted by default.** `Authorization`, `Cookie`, `Set-Cookie`, API-key
headers and query parameters like `token` or `sig` are replaced with their length. Bodies are
*not* redacted, and the export's own README says so. Turn redaction off in
**File → Redact Credentials in Exports** if the export is staying local.

## Known limitations

- Injection engine only. `WKWebView` and non-`URLSession` stacks are not yet captured
  (the MITM proxy engine is the next milestone).
- Apps launched from Xcode need two scheme environment variables (Snoopy provides a
  Copy button); apps launched from Snoopy need no setup.

## Requirements

- macOS 14 or later, Xcode 15 or later with iOS simulators installed.
