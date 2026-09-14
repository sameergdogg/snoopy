import Foundation

/// What the store consumes. Deliberately separate from `SnoopyIPC.HookEvent`: the wire
/// format is the transport's business, and the store also needs events no hook ever sends —
/// `.detached`, which the socket synthesises when a process goes away. Keeping them apart
/// also means the store can be driven from a test or a loaded session file without
/// constructing wire frames.
public enum CaptureEvent: Sendable {
    case attached(pid: Int32, process: String, bundleId: String)
    case detached(pid: Int32)
    case log(String)
    case request(Request)
    case response(Response)
    case metrics(id: String, timing: Timing)
    case complete(Complete)

    public struct Request: Sendable {
        public var id: String
        public var taskId: Int?
        public var t: Double
        public var method: String
        public var url: String
        public var headers: Headers
        public var body: Data?
        public var bodySize: Int?
        public var bodyTruncated: Bool
        public var bodyOmitted: String?
        public init(id: String, taskId: Int? = nil, t: Double, method: String, url: String,
                    headers: Headers = Headers(), body: Data? = nil, bodySize: Int? = nil,
                    bodyTruncated: Bool = false, bodyOmitted: String? = nil) {
            self.id = id; self.taskId = taskId; self.t = t; self.method = method; self.url = url
            self.headers = headers; self.body = body; self.bodySize = bodySize
            self.bodyTruncated = bodyTruncated; self.bodyOmitted = bodyOmitted
        }
    }

    public struct Response: Sendable {
        public var id: String
        public var t: Double
        public var status: Int?
        public var mimeType: String?
        public var headers: Headers
        public init(id: String, t: Double, status: Int? = nil, mimeType: String? = nil,
                    headers: Headers = Headers()) {
            self.id = id; self.t = t; self.status = status; self.mimeType = mimeType; self.headers = headers
        }
    }

    public struct Complete: Sendable {
        public var id: String
        public var t: Double
        public var status: Int?
        public var mimeType: String?
        public var headers: Headers
        public var body: Data?
        public var bodySize: Int?
        public var bodyTruncated: Bool
        public var errorMessage: String?
        public var errorCode: Int?
        public var timing: Timing?
        public init(id: String, t: Double, status: Int? = nil, mimeType: String? = nil,
                    headers: Headers = Headers(), body: Data? = nil, bodySize: Int? = nil,
                    bodyTruncated: Bool = false, errorMessage: String? = nil,
                    errorCode: Int? = nil, timing: Timing? = nil) {
            self.id = id; self.t = t; self.status = status; self.mimeType = mimeType
            self.headers = headers; self.body = body; self.bodySize = bodySize
            self.bodyTruncated = bodyTruncated; self.errorMessage = errorMessage
            self.errorCode = errorCode; self.timing = timing
        }
    }
}
