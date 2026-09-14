import Foundation

/// Save/load for a capture session.
///
/// HAR export already existed, but HAR is a lossy interchange format: it has nowhere to put
/// an exchange's state, the error that failed it, the truncation flags, or the fact that a
/// body was reaped rather than empty. Quitting therefore always lost the capture. This is a
/// faithful round-trip of what Snoopy actually holds.
public enum Session {
    public static let fileExtension = "snoopy"
    private static let magic = "snoopy.session"
    private static let version = 1
    /// Identifies the deflated container, and keeps a plain-JSON file loadable too.
    private static let magicBytes: [UInt8] = Array("SNZ1".utf8)

    struct File: Codable {
        var format: String
        var version: Int
        var savedAt: Date
        var exchanges: [Exchange]
    }

    public static func encode(_ exchanges: [Exchange]) throws -> Data {
        let file = File(format: magic, version: version, savedAt: Date(), exchanges: exchanges)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        // Bodies are the bulk of a session and base64 inflates them by a third; the whole
        // file compresses well, so it is written deflated behind a short magic prefix
        // rather than as raw JSON.
        return Data(magicBytes) + (try Gzip.deflateRaw(enc.encode(file)))
    }

    public static func decode(_ data: Data) throws -> [Exchange] {
        let raw: Data
        if data.starts(with: magicBytes) {
            raw = try Gzip.inflateRaw(data.dropFirst(magicBytes.count))
        } else {
            raw = data   // an uncompressed file, e.g. one a user pretty-printed by hand
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let file = try dec.decode(File.self, from: raw)
        guard file.format == magic else {
            throw NSError(domain: "Snoopy.Session", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not a Snoopy session file."])
        }
        guard file.version <= version else {
            throw NSError(domain: "Snoopy.Session", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "This session was written by a newer version of Snoopy (format \(file.version))."])
        }
        return file.exchanges
    }
}

// MARK: - Codable conformances
//
// Derived fields (`url`, `host`, `path`, `searchKey`, `startedAtText`, `deepSearchKey`) are
// not encoded: they are functions of the stored fields, and writing them would let a
// hand-edited file disagree with itself. They are rebuilt on decode.

extension Exchange: Codable {
    enum CodingKeys: String, CodingKey {
        case id, taskId, pid, process, method, urlString
        case requestHeaders, requestBody, requestBodySize, requestBodyTruncated, requestBodyOmitted
        case status, mimeType, responseHeaders, responseBody, responseBodySize, responseBodyTruncated
        case startedAt, respondedAt, completedAt, metrics, errorMessage, errorCode, state, bodiesReaped
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  method: try c.decodeIfPresent(String.self, forKey: .method) ?? "GET",
                  urlString: try c.decodeIfPresent(String.self, forKey: .urlString) ?? "",
                  startedAt: try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date())
        taskId = try c.decodeIfPresent(Int.self, forKey: .taskId)
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        process = try c.decodeIfPresent(String.self, forKey: .process)
        requestHeaders = try c.decodeIfPresent(Headers.self, forKey: .requestHeaders) ?? Headers()
        requestBody = try c.decodeIfPresent(Data.self, forKey: .requestBody)
        requestBodySize = try c.decodeIfPresent(Int.self, forKey: .requestBodySize)
        requestBodyTruncated = try c.decodeIfPresent(Bool.self, forKey: .requestBodyTruncated) ?? false
        requestBodyOmitted = try c.decodeIfPresent(String.self, forKey: .requestBodyOmitted)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        responseHeaders = try c.decodeIfPresent(Headers.self, forKey: .responseHeaders) ?? Headers()
        responseBody = try c.decodeIfPresent(Data.self, forKey: .responseBody)
        responseBodySize = try c.decodeIfPresent(Int.self, forKey: .responseBodySize)
        responseBodyTruncated = try c.decodeIfPresent(Bool.self, forKey: .responseBodyTruncated) ?? false
        respondedAt = try c.decodeIfPresent(Date.self, forKey: .respondedAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        metrics = try c.decodeIfPresent(Timing.self, forKey: .metrics)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        errorCode = try c.decodeIfPresent(Int.self, forKey: .errorCode)
        state = try c.decodeIfPresent(State.self, forKey: .state) ?? .complete
        // `setStatus` also refreshes the search key, so it runs after the request line.
        setStatus(try c.decodeIfPresent(Int.self, forKey: .status))
        if try c.decodeIfPresent(Bool.self, forKey: .bodiesReaped) == true, requestBody == nil, responseBody == nil {
            releaseBodies()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(taskId, forKey: .taskId)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encodeIfPresent(process, forKey: .process)
        try c.encode(method, forKey: .method)
        try c.encode(urlString, forKey: .urlString)
        try c.encode(requestHeaders, forKey: .requestHeaders)
        try c.encodeIfPresent(requestBody, forKey: .requestBody)
        try c.encodeIfPresent(requestBodySize, forKey: .requestBodySize)
        try c.encode(requestBodyTruncated, forKey: .requestBodyTruncated)
        try c.encodeIfPresent(requestBodyOmitted, forKey: .requestBodyOmitted)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(mimeType, forKey: .mimeType)
        try c.encode(responseHeaders, forKey: .responseHeaders)
        try c.encodeIfPresent(responseBody, forKey: .responseBody)
        try c.encodeIfPresent(responseBodySize, forKey: .responseBodySize)
        try c.encode(responseBodyTruncated, forKey: .responseBodyTruncated)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(respondedAt, forKey: .respondedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(metrics, forKey: .metrics)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encodeIfPresent(errorCode, forKey: .errorCode)
        try c.encode(state, forKey: .state)
        try c.encode(bodiesReaped, forKey: .bodiesReaped)
    }
}
