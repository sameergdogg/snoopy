# Contributing to Snoopy

Thanks for helping. Snoopy is MIT-licensed and aims to be the tool iOS engineers reach
for instead of a heavyweight proxy.

## Getting started

```sh
brew install xcodegen
xcodegen generate
xcodebuild -scheme Snoopy build
swift test --package-path Packages/SnoopyCore
```

## Ground rules

- **The hook stays Objective-C/C only.** Injecting a Swift dylib into an app built with a
  different Swift toolchain is fragile. Keep `Hook/` free of Swift.
- **Never use a custom `URLProtocol`** in the hook — it changes auth-challenge and pinning
  behavior, which is exactly what we must not disturb.
- **The hook must never throw across the boundary or block the app.** Wrap work in
  `@try/@catch`, cap body sizes, and stay off the app's threads beyond copying bytes.
- Company-specific body decoders belong in **plugins outside this repo**, not in core.

## Project generation

`project.yml` is the source of truth; the `.xcodeproj` is generated and git-ignored. Run
`xcodegen generate` after changing files or settings.
