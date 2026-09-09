# Spike: injection + CA + system proxy on the iOS Simulator (verified 2026-09-08, Xcode 26.6, iOS 26.4 sim)

Everything below was run and worked. Commands assume `UDID` is a booted simulator.

## 1. Inject a hook dylib into a simulator process (no proxy, no CA, sees plaintext)

```sh
SDK=$(xcrun -sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$SDK" \
  -fobjc-arc -dynamiclib -framework Foundation hook.m -o libsnoopyhook.dylib
xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$SDK" \
  -fobjc-arc -framework Foundation app.m -o simapp

# a) into a plain simulator binary
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=$PWD/libsnoopyhook.dylib xcrun simctl spawn $UDID $PWD/simapp
# b) into a real installed app (Safari here)
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=$PWD/libsnoopyhook.dylib xcrun simctl launch --console $UDID com.apple.mobilesafari
```

Output seen: `[snoopy-hook] resume POST https://httpbin.org/post body={"hello":"snoopy"}` and Safari's
own requests. `-[NSURLSessionTask resume]` is owned by `NSURLSessionTask` itself, so one swizzle covers
every task type. For apps run from Xcode, put `DYLD_INSERT_LIBRARIES=<path>` in the scheme's Run
environment variables instead.

## 2. Install a root CA with simctl (needed only for the MITM proxy engine)

```sh
xcrun simctl keychain $UDID add-root-cert ca_rsa.pem
```

- Works with an **RSA-2048** CA. An **EC P-256** CA is rejected (`NSOSStatusErrorDomain -50`), both PEM and DER.
- Takes effect **immediately, no simulator reboot** needed (tested: TLS failed, install, TLS 200).
- Row lands in `<device>/data/private/var/protected/trustd/private/TrustStore.sqlite3` (table `tsettings`).
  The older `data/Library/Keychains/TrustStore.sqlite3` is an empty file on iOS 26.
- Verify with `tls2.m` against `openssl s_server -accept 8443 -cert leaf_rsa.pem -key leaf_rsa.key -www`.
  (System LibreSSL 3.3 cannot serve an EC leaf key. Use RSA for the test server.)

## 3. macOS system proxy is honored by simulator apps, and needs no sudo

```sh
python3 connectproxy.py &            # logs CONNECT lines, tunnels bytes
networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 8888
networksetup -setsecurewebproxystate Wi-Fi on
xcrun simctl spawn $UDID $PWD/tlsapp2 https://httpbin.org/get   # -> 200, "CONNECT httpbin.org:443" in log
networksetup -setsecurewebproxystate Wi-Fi off
```

- Ran as a normal admin user, no password prompt, no privileged helper.
- Gotcha: `networksetup -setsecurewebproxy <svc> "" 0` **re-enables** the proxy. Restore with `-set…proxystate off` only.
- The proxy also received CONNECTs from unrelated Mac apps (analytics SDKs etc.). System proxy is machine-wide,
  so the proxy engine must attribute connections to processes and filter to simulator PIDs.
