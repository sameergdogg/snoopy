import Foundation

/// Removes credentials from a capture before it leaves the machine.
///
/// An export exists to be read somewhere else — by an agent, in a ticket, in a chat — and a
/// network capture is dense with exactly the things that must not travel: bearer tokens,
/// session cookies, API keys, signed URLs. Redaction is therefore the default for exports,
/// not an option someone has to remember to switch on.
///
/// The value is replaced with its length and a hint of its shape, which is usually enough to
/// reason about ("the second call sends a 64-char token, the third sends none") without
/// carrying the secret itself.
public enum Redaction {
    /// Header names whose values are credentials. Matched case-insensitively and exactly —
    /// a substring match would catch `X-Request-Id` on "request" and redact routine fields.
    public static let sensitiveHeaders: Set<String> = [
        "authorization", "proxy-authorization", "www-authenticate", "proxy-authenticate",
        "cookie", "set-cookie",
        "x-api-key", "api-key", "apikey", "x-auth-token", "auth-token",
        "x-access-token", "access-token", "x-session-token", "x-csrf-token", "csrf-token",
        "x-xsrf-token", "x-amz-security-token", "x-goog-api-key", "x-secret",
        "x-signature", "signature",
    ]

    /// Query-parameter names that carry credentials in a URL.
    public static let sensitiveQueryKeys: Set<String> = [
        "token", "access_token", "id_token", "refresh_token", "auth", "apikey", "api_key",
        "key", "secret", "client_secret", "password", "passwd", "pwd", "sig", "signature",
        "session", "sessionid", "session_id", "x-amz-signature",
    ]

    public static func isSensitive(header name: String) -> Bool {
        sensitiveHeaders.contains(name.lowercased())
    }

    /// `Bearer abc…` keeps the scheme, because which scheme is in use is diagnostic and the
    /// scheme itself is not a secret.
    public static func redactedValue(_ value: String) -> String {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2, ["bearer", "basic", "digest", "token"].contains(parts[0].lowercased()) {
            return "\(parts[0]) <redacted \(parts[1].count) chars>"
        }
        return "<redacted \(value.count) chars>"
    }

    public static func redact(_ headers: Headers) -> Headers {
        Headers(headers.fields.map { f in
            isSensitive(header: f.name) ? .init(name: f.name, value: redactedValue(f.value)) : f
        })
    }

    /// URL-safe placeholder. The header form (`<redacted 14 chars>`) survives a round trip
    /// through `URLComponents` as `%3Credacted%2014%20chars%3E`, which turns every redacted
    /// URL in a summary into unreadable noise.
    public static func redactedQueryValue(_ value: String) -> String {
        "redacted-\(value.count)-chars"
    }

    /// Rewrites credential-bearing query parameters. Returns the original string when it is
    /// not a parseable URL, since a half-redacted URL is worse than an unparsed one.
    public static func redact(urlString: String) -> String {
        guard var comps = URLComponents(string: urlString), let items = comps.queryItems else {
            return urlString
        }
        var touched = false
        comps.queryItems = items.map { item in
            guard sensitiveQueryKeys.contains(item.name.lowercased()), let v = item.value, !v.isEmpty else {
                return item
            }
            touched = true
            return URLQueryItem(name: item.name, value: redactedQueryValue(v))
        }
        guard touched else { return urlString }
        return comps.string ?? urlString
    }

    /// Applies both to an exchange. Bodies are deliberately untouched — see the export's
    /// README, which says so plainly rather than implying a guarantee it cannot make.
    public static func redact(_ exchange: Exchange) -> Exchange {
        var e = exchange
        e.setRequestLine(method: e.method, urlString: redact(urlString: e.urlString))
        e.requestHeaders = redact(e.requestHeaders)
        e.responseHeaders = redact(e.responseHeaders)
        return e
    }
}
