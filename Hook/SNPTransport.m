#import "SNPTransport.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>

static const NSUInteger kSNPMaxPending = 2000;

@implementation SNPTransport {
    dispatch_queue_t _queue;
    NSString *_path;
    int _fd;
    NSMutableArray<NSData *> *_pending;
    NSTimeInterval _retryDelay;
    BOOL _started;
}

+ (instancetype)shared {
    static SNPTransport *t; static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [SNPTransport new]; });
    return t;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("dev.snoopy.hook.transport", DISPATCH_QUEUE_SERIAL);
        _fd = -1;
        _pending = [NSMutableArray new];
        _retryDelay = 0.5;
    }
    return self;
}

- (void)startWithSocketPath:(NSString *)path {
    dispatch_async(_queue, ^{
        if (self->_started) return;
        self->_started = YES;
        self->_path = [path copy];
        [self connectLocked];
    });
}

- (void)connectLocked {
    if (_fd >= 0) return;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { [self scheduleRetry]; return; }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct sockaddr_un addr; memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    const char *p = _path.fileSystemRepresentation;
    if (strlen(p) >= sizeof(addr.sun_path)) { close(fd); return; }
    strlcpy(addr.sun_path, p, sizeof(addr.sun_path));
    if (connect(fd, (struct sockaddr *)&addr, (socklen_t)SUN_LEN(&addr)) != 0) {
        close(fd);
        [self scheduleRetry];
        return;
    }
    _fd = fd;
    _retryDelay = 0.5;
    NSDictionary *hello = self.helloMessage;
    if (hello) [self writeFrameLocked:[self frameFor:hello]];
    NSArray *flush = [_pending copy];
    [_pending removeAllObjects];
    for (NSData *f in flush) { if (![self writeFrameLocked:f]) break; }
}

- (void)scheduleRetry {
    NSTimeInterval d = _retryDelay;
    _retryDelay = MIN(_retryDelay * 2, 5.0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), _queue, ^{ [self connectLocked]; });
}

- (NSData *)frameFor:(NSDictionary *)message {
    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:&err];
    if (!json) return nil;
    uint32_t len = htonl((uint32_t)json.length);
    NSMutableData *frame = [NSMutableData dataWithCapacity:json.length + 4];
    [frame appendBytes:&len length:4];
    [frame appendData:json];
    return frame;
}

/// Returns NO if the connection died (frame is re-queued).
- (BOOL)writeFrameLocked:(NSData *)frame {
    if (!frame) return YES;
    if (_fd < 0) { [self enqueueLocked:frame]; return NO; }
    const uint8_t *bytes = frame.bytes; size_t remaining = frame.length;
    while (remaining > 0) {
        ssize_t n = write(_fd, bytes, remaining);
        if (n < 0) {
            if (errno == EINTR) continue;
            close(_fd); _fd = -1;
            [self enqueueLocked:frame];
            [self scheduleRetry];
            return NO;
        }
        bytes += n; remaining -= (size_t)n;
    }
    return YES;
}

- (void)enqueueLocked:(NSData *)frame {
    if (_pending.count >= kSNPMaxPending) [_pending removeObjectAtIndex:0];
    [_pending addObject:frame];
}

- (void)send:(NSDictionary *)message {
    NSData *frame = [self frameFor:message];
    if (!frame) return;
    dispatch_async(_queue, ^{ [self writeFrameLocked:frame]; });
}

@end
