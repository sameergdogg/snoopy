#import <Foundation/Foundation.h>
#import "SNPTransport.h"
#import "SNPCapture.h"
#import <objc/runtime.h>
#import <objc/message.h>

// ---------------------------------------------------------------------------
// Swizzle helpers
// ---------------------------------------------------------------------------
static void SNPSwizzle(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

static void SNPInstallOnDelegateClass(Class cls); // fwd

// Install our capture hooks on whatever delegate actually drives this task.
// Covers async/await and any session we didn't see created (e.g. URLSession.shared),
// whose completion is delivered through an internal delegate class.
// The concrete class that owns -[NSURLSessionTask resume] (walk from a real task).
static Class SNPTaskResumeOwner(void) {
    NSURLSession *s = [NSURLSession sharedSession];
    NSURLSessionDataTask *probe = [s dataTaskWithURL:[NSURL URLWithString:@"https://snoopy.invalid/"]];
    Class owner = object_getClass(probe);
    while (owner) {
        unsigned n = 0; Method *ms = class_copyMethodList(owner, &n); BOOL found = NO;
        for (unsigned i = 0; i < n; i++) if (method_getName(ms[i]) == @selector(resume)) found = YES;
        free(ms);
        if (found) break;
        owner = class_getSuperclass(owner);
    }
    [probe cancel];
    return owner ?: NSClassFromString(@"__NSCFURLSessionTask");
}

// ---------------------------------------------------------------------------
// resume
// ---------------------------------------------------------------------------
static IMP g_origResume;
static void snp_resume(id self, SEL _cmd) {
    @try { SNPSendRequest((NSURLSessionTask *)self); } @catch (__unused id e) {}
    ((void (*)(id, SEL))g_origResume)(self, _cmd);
}

// ---------------------------------------------------------------------------
// completion-handler task factories: capture upload bodies + wrap the handler
// ---------------------------------------------------------------------------
typedef void (^SNPDataHandler)(NSData *, NSURLResponse *, NSError *);

static SNPDataHandler SNPWrapHandler(SNPDataHandler original) {
    if (!original) return nil;
    return ^(NSData *data, NSURLResponse *response, NSError *error) {
        // We can't see the task here; completion is matched by the delegate path for
        // delegate-based sessions. For handler-based sessions we still get metrics via
        // the shared delegate swizzles below. This wrapper is a safety net for bodies:
        original(data, response, error);
    };
}

// dataTaskWithRequest:completionHandler:
static IMP g_origDataReqCH;
static NSURLSessionDataTask *snp_dataReqCH(id self, SEL _cmd, NSURLRequest *req, SNPDataHandler ch) {
    __block NSURLSessionDataTask *task = nil;
    SNPDataHandler wrapped = ch ? ^(NSData *data, NSURLResponse *response, NSError *error) {
        @try { SNPSendComplete(task, response, data, error); } @catch (__unused id e) {}
        ch(data, response, error);
    } : nil;
    task = ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, SNPDataHandler))g_origDataReqCH)(self, _cmd, req, wrapped);
    return task;
}

// dataTaskWithURL:completionHandler:
static IMP g_origDataURLCH;
static NSURLSessionDataTask *snp_dataURLCH(id self, SEL _cmd, NSURL *url, SNPDataHandler ch) {
    __block NSURLSessionDataTask *task = nil;
    SNPDataHandler wrapped = ch ? ^(NSData *data, NSURLResponse *response, NSError *error) {
        @try { SNPSendComplete(task, response, data, error); } @catch (__unused id e) {}
        ch(data, response, error);
    } : nil;
    task = ((NSURLSessionDataTask *(*)(id, SEL, NSURL *, SNPDataHandler))g_origDataURLCH)(self, _cmd, url, wrapped);
    return task;
}

// uploadTaskWithRequest:fromData:completionHandler:
static IMP g_origUploadDataCH;
static NSURLSessionUploadTask *snp_uploadDataCH(id self, SEL _cmd, NSURLRequest *req, NSData *bodyData, SNPDataHandler ch) {
    __block NSURLSessionUploadTask *task = nil;
    SNPDataHandler wrapped = ch ? ^(NSData *data, NSURLResponse *response, NSError *error) {
        @try { SNPSendComplete(task, response, data, error); } @catch (__unused id e) {}
        ch(data, response, error);
    } : nil;
    task = ((NSURLSessionUploadTask *(*)(id, SEL, NSURLRequest *, NSData *, SNPDataHandler))g_origUploadDataCH)(self, _cmd, req, bodyData, wrapped);
    if (task && bodyData) { SNPRecord *r = SNPRecordForTask(task); r.uploadBody = bodyData; }
    return task;
}

// uploadTaskWithRequest:fromData: (no handler; delegate path)
static IMP g_origUploadData;
static NSURLSessionUploadTask *snp_uploadData(id self, SEL _cmd, NSURLRequest *req, NSData *bodyData) {
    NSURLSessionUploadTask *task = ((NSURLSessionUploadTask *(*)(id, SEL, NSURLRequest *, NSData *))g_origUploadData)(self, _cmd, req, bodyData);
    if (task && bodyData) { SNPRecord *r = SNPRecordForTask(task); r.uploadBody = bodyData; }
    return task;
}

// ---------------------------------------------------------------------------
// Delegate interposition (rename-based swizzling).
// NSURLSession forwards to the user's delegate. For each delegate class we see,
// we rename any existing target method to a backup selector and install ours.
// Our impl forwards to the backup only if it exists, so classes that don't
// implement a method get our capture with a safe no-op "original".
// ---------------------------------------------------------------------------
@interface SNPHookMarker : NSObject @end
@implementation SNPHookMarker @end
static id kSNPInstallLock = nil;

static SEL SNPBackupSel(SEL sel) {
    return sel_registerName([[NSString stringWithFormat:@"snp_orig_%s", sel_getName(sel)] UTF8String]);
}
static BOOL SNPHasBackup(id self, SEL backup) {
    return class_respondsToSelector(object_getClass(self), backup);
}

static void snp_didFinishMetrics(id self, SEL _cmd, NSURLSession *session, NSURLSessionTask *task, NSURLSessionTaskMetrics *metrics) {
    @try { SNPStoreMetrics(task, metrics); } @catch (__unused id e) {}
    SEL b = SNPBackupSel(_cmd);
    if (SNPHasBackup(self, b))
        ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSURLSessionTaskMetrics *))objc_msgSend)(self, b, session, task, metrics);
}

static void SNPInstallOnDelegateClass(Class cls) {
    if (!cls) return;
    static const void *kInstalledKey = &kInstalledKey;
    @synchronized (kSNPInstallLock) {
        if (objc_getAssociatedObject(cls, kInstalledKey)) return;
        objc_setAssociatedObject(cls, kInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN);
    }
    struct { SEL sel; IMP imp; const char *types; BOOL addIfMissing; } specs[] = {
        { @selector(URLSession:task:didFinishCollectingMetrics:), (IMP)snp_didFinishMetrics, "v@:@@@", YES },
    };
    for (size_t i = 0; i < sizeof(specs)/sizeof(specs[0]); i++) {
        SEL sel = specs[i].sel;
        // Only treat as "implemented" if THIS class (not a superclass) defines it,
        // so we don't rename an inherited method onto the wrong class.
        unsigned n = 0; Method *ms = class_copyMethodList(cls, &n); Method own = NULL;
        for (unsigned j = 0; j < n; j++) if (method_getName(ms[j]) == sel) own = ms[j];
        free(ms);
        if (own) {
            IMP orig = method_getImplementation(own);
            const char *types = method_getTypeEncoding(own);
            class_addMethod(cls, SNPBackupSel(sel), orig, types); // stash original
            method_setImplementation(own, specs[i].imp);          // install ours
        } else if (specs[i].addIfMissing) {
            class_addMethod(cls, sel, specs[i].imp, specs[i].types);
        }
    }
}

// Swizzle sessionWithConfiguration:delegate:delegateQueue: to learn delegate classes.
static IMP g_origSessionWithConfig;
static NSURLSession *snp_sessionWithConfig(id self, SEL _cmd, NSURLSessionConfiguration *cfg, id<NSURLSessionDelegate> delegate, NSOperationQueue *queue) {
    if (delegate) { @try { SNPInstallOnDelegateClass(object_getClass(delegate)); } @catch (__unused id e) {} }
    return ((NSURLSession *(*)(id, SEL, NSURLSessionConfiguration *, id, NSOperationQueue *))g_origSessionWithConfig)(self, _cmd, cfg, delegate, queue);
}

// ---------------------------------------------------------------------------
// Task-class chokepoint. Every local task routes CFNetwork callbacks through
// __NSCFLocalSessionTask's connection:* methods, whether the caller used a
// completion handler, a delegate, async/await, or URLSession.shared. `self` is
// the task, so this is our single source of truth for response/data/finish and
// covers cases where no user delegate exists.
// ---------------------------------------------------------------------------
static IMP g_origConnResponse;
static void snp_connResponse(id self, SEL _cmd, id connection, NSURLResponse *response, id completion) {
    @try { SNPSendResponse((NSURLSessionTask *)self, response); } @catch (__unused id e) {}
    ((void (*)(id, SEL, id, NSURLResponse *, id))g_origConnResponse)(self, _cmd, connection, response, completion);
}
static IMP g_origConnData;
static void snp_connData(id self, SEL _cmd, id connection, NSData *data, id completion) {
    @try { SNPAppendResponseData((NSURLSessionTask *)self, data); } @catch (__unused id e) {}
    ((void (*)(id, SEL, id, NSData *, id))g_origConnData)(self, _cmd, connection, data, completion);
}
static IMP g_origConnFinish;
static void snp_connFinish(id self, SEL _cmd, id connection, NSError *error) {
    NSURLSessionTask *task = (NSURLSessionTask *)self;
    @try { SNPSendComplete(task, task.response, nil, error); } @catch (__unused id e) {}
    ((void (*)(id, SEL, id, NSError *))g_origConnFinish)(self, _cmd, connection, error);
}

static void SNPInstallTaskChokepoints(void) {
    Class taskCls = NSClassFromString(@"__NSCFLocalSessionTask");
    if (!taskCls) return;
    SNPSwizzle(taskCls, @selector(connection:didReceiveResponse:completion:), (IMP)snp_connResponse, &g_origConnResponse);
    SNPSwizzle(taskCls, @selector(connection:didReceiveData:completion:), (IMP)snp_connData, &g_origConnData);
    SNPSwizzle(taskCls, @selector(connection:didFinishLoadingWithError:), (IMP)snp_connFinish, &g_origConnFinish);
}

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------
__attribute__((constructor))
static void SNPHookInit(void) {
    @autoreleasepool {
        kSNPInstallLock = [NSObject new];
        const char *sock = getenv("SNOOPY_SOCKET");
        if (!sock || strlen(sock) == 0) return; // not launched by Snoopy: stay dormant.

        [SNPTransport shared].helloMessage = SNPHelloMessage();
        [[SNPTransport shared] startWithSocketPath:[NSString stringWithUTF8String:sock]];

        Class taskOwner = SNPTaskResumeOwner();
        SNPSwizzle(taskOwner, @selector(resume), (IMP)snp_resume, &g_origResume);
        SNPInstallTaskChokepoints();

        Class sessionCls = [NSURLSession class];
        SNPSwizzle(sessionCls, @selector(dataTaskWithRequest:completionHandler:), (IMP)snp_dataReqCH, &g_origDataReqCH);
        SNPSwizzle(sessionCls, @selector(dataTaskWithURL:completionHandler:), (IMP)snp_dataURLCH, &g_origDataURLCH);
        SNPSwizzle(sessionCls, @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)snp_uploadDataCH, &g_origUploadDataCH);
        SNPSwizzle(sessionCls, @selector(uploadTaskWithRequest:fromData:), (IMP)snp_uploadData, &g_origUploadData);
        // Class methods live on the metaclass.
        SNPSwizzle(object_getClass(sessionCls), @selector(sessionWithConfiguration:delegate:delegateQueue:), (IMP)snp_sessionWithConfig, &g_origSessionWithConfig);

        [[SNPTransport shared] send:@{ @"type": @"log", @"message": @"SnoopyHook installed" }];
    }
}
