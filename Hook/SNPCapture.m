#import "SNPCapture.h"
#import "SNPTransport.h"
#import <objc/runtime.h>

static const NSUInteger kSNPMaxRequestBody = 4 * 1024 * 1024;
static const NSUInteger kSNPMaxResponseBody = 8 * 1024 * 1024;
static const void *kSNPRecordKey = &kSNPRecordKey;

@implementation SNPRecord
@end

static NSTimeInterval SNPNow(void) { return [NSDate date].timeIntervalSince1970; }

SNPRecord *SNPRecordForTask(NSURLSessionTask *task) {
    if (!task) return nil;
    @synchronized (task) {
        SNPRecord *r = objc_getAssociatedObject(task, kSNPRecordKey);
        if (!r) {
            r = [SNPRecord new];
            r.exchangeId = [NSUUID UUID].UUIDString;
            r.responseBody = [NSMutableData new];
            objc_setAssociatedObject(task, kSNPRecordKey, r, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return r;
    }
}

static NSDictionary *SNPHeaders(NSDictionary *h) {
    if (!h) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:h.count];
    [h enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        out[[k description]] = [v description];
    }];
    return out;
}

static void SNPPutBody(NSMutableDictionary *msg, NSData *body, NSUInteger cap) {
    if (!body) return;
    msg[@"bodySize"] = @(body.length);
    BOOL truncated = body.length > cap;
    NSData *slice = truncated ? [body subdataWithRange:NSMakeRange(0, cap)] : body;
    msg[@"body"] = [slice base64EncodedStringWithOptions:0];
    msg[@"bodyTruncated"] = @(truncated);
}

NSDictionary *SNPHelloMessage(void) {
    NSBundle *b = [NSBundle mainBundle];
    return @{ @"type": @"hello",
              @"pid": @(getpid()),
              @"process": [NSProcessInfo processInfo].processName ?: @"",
              @"bundleId": b.bundleIdentifier ?: @"",
              @"hookVersion": @1 };
}

void SNPSendRequest(NSURLSessionTask *task) {
    SNPRecord *r = SNPRecordForTask(task);
    @synchronized (r) {
        if (r.requestSent) return;
        r.requestSent = YES;
        r.startedAt = SNPNow();
    }
    NSURLRequest *req = task.currentRequest ?: task.originalRequest;
    NSMutableDictionary *msg = [NSMutableDictionary new];
    msg[@"type"] = @"request";
    msg[@"id"] = r.exchangeId;
    msg[@"t"] = @(r.startedAt);
    msg[@"taskId"] = @(task.taskIdentifier);
    msg[@"method"] = req.HTTPMethod ?: @"GET";
    msg[@"url"] = req.URL.absoluteString ?: @"";
    msg[@"headers"] = SNPHeaders(req.allHTTPHeaderFields);
    NSData *body = req.HTTPBody ?: r.uploadBody;
    if (body) {
        SNPPutBody(msg, body, kSNPMaxRequestBody);
    } else if (req.HTTPBodyStream) {
        msg[@"bodyOmitted"] = @"stream";
    }
    [[SNPTransport shared] send:msg];
}

static void SNPFillResponse(NSMutableDictionary *msg, NSURLResponse *response) {
    if (!response) return;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *h = (NSHTTPURLResponse *)response;
        msg[@"status"] = @(h.statusCode);
        msg[@"headers"] = SNPHeaders(h.allHeaderFields);
    }
    if (response.MIMEType) msg[@"mimeType"] = response.MIMEType;
    if (response.URL) msg[@"url"] = response.URL.absoluteString;
}

void SNPSendResponse(NSURLSessionTask *task, NSURLResponse *response) {
    SNPRecord *r = SNPRecordForTask(task);
    @synchronized (r) {
        if (r.responseSent) return;
        r.responseSent = YES;
    }
    NSMutableDictionary *msg = [NSMutableDictionary new];
    msg[@"type"] = @"response";
    msg[@"id"] = r.exchangeId;
    msg[@"t"] = @(SNPNow());
    SNPFillResponse(msg, response);
    [[SNPTransport shared] send:msg];
}

void SNPAppendResponseData(NSURLSessionTask *task, NSData *data) {
    if (!data.length) return;
    SNPRecord *r = SNPRecordForTask(task);
    @synchronized (r) {
        if (r.responseBody.length < kSNPMaxResponseBody + 1) [r.responseBody appendData:data];
    }
}

static NSNumber *SNPTime(NSDate *d) { return d ? @(d.timeIntervalSince1970) : nil; }

void SNPStoreMetrics(NSURLSessionTask *task, NSURLSessionTaskMetrics *metrics) {
    NSURLSessionTaskTransactionMetrics *m = metrics.transactionMetrics.lastObject;
    if (!m) return;
    NSMutableDictionary *d = [NSMutableDictionary new];
    d[@"fetchStart"] = SNPTime(m.fetchStartDate);
    d[@"dnsStart"] = SNPTime(m.domainLookupStartDate);
    d[@"dnsEnd"] = SNPTime(m.domainLookupEndDate);
    d[@"connectStart"] = SNPTime(m.connectStartDate);
    d[@"connectEnd"] = SNPTime(m.connectEndDate);
    d[@"tlsStart"] = SNPTime(m.secureConnectionStartDate);
    d[@"tlsEnd"] = SNPTime(m.secureConnectionEndDate);
    d[@"requestStart"] = SNPTime(m.requestStartDate);
    d[@"requestEnd"] = SNPTime(m.requestEndDate);
    d[@"responseStart"] = SNPTime(m.responseStartDate);
    d[@"responseEnd"] = SNPTime(m.responseEndDate);
    d[@"protocol"] = m.networkProtocolName;
    d[@"reused"] = @(m.isReusedConnection);
    d[@"remoteAddress"] = m.remoteAddress;
    d[@"redirects"] = @(metrics.redirectCount);
    SNPRecord *r = SNPRecordForTask(task);
    @synchronized (r) { r.metrics = d; }
    NSMutableDictionary *msg = [NSMutableDictionary dictionaryWithDictionary:d];
    msg[@"type"] = @"metrics";
    msg[@"id"] = r.exchangeId;
    [[SNPTransport shared] send:msg];
}

void SNPSendComplete(NSURLSessionTask *task, NSURLResponse *response, NSData *bodyOverride, NSError *error) {
    SNPRecord *r = SNPRecordForTask(task);
    NSData *body; NSDictionary *metrics;
    @synchronized (r) {
        if (r.completeSent) return;
        r.completeSent = YES;
        body = bodyOverride ?: [r.responseBody copy];
        metrics = r.metrics;
    }
    if (!r.requestSent) SNPSendRequest(task); // task completed without resume being seen (unlikely)
    NSMutableDictionary *msg = [NSMutableDictionary new];
    msg[@"type"] = @"complete";
    msg[@"id"] = r.exchangeId;
    msg[@"t"] = @(SNPNow());
    SNPFillResponse(msg, response ?: task.response);
    if (body) SNPPutBody(msg, body, kSNPMaxResponseBody);
    if (error) {
        msg[@"error"] = @{ @"domain": error.domain ?: @"", @"code": @(error.code),
                           @"message": error.localizedDescription ?: @"" };
    }
    if (metrics) msg[@"metrics"] = metrics;
    [[SNPTransport shared] send:msg];
}
