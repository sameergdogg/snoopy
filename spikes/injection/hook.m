#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Minimal spike: swizzle -[NSURLSessionTask resume] and log the request.
static IMP g_origResume;
static void swz_resume(id self, SEL _cmd) {
    NSURLRequest *r = [self currentRequest] ?: [self originalRequest];
    NSString *body = r.HTTPBody ? [[NSString alloc] initWithData:r.HTTPBody encoding:NSUTF8StringEncoding] : @"<nil>";
    fprintf(stderr, "[snoopy-hook] resume %s %s body=%s\n", r.HTTPMethod.UTF8String, r.URL.absoluteString.UTF8String, body.UTF8String);
    ((void(*)(id,SEL))g_origResume)(self, _cmd);
}

__attribute__((constructor)) static void snoopy_init(void) {
    fprintf(stderr, "[snoopy-hook] loaded into pid %d (%s)\n", getpid(), [[NSProcessInfo processInfo] processName].UTF8String);
    // The concrete class that implements resume is private (__NSCFLocalDataTask); walk up from a real task.
    NSURLSessionDataTask *probe = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:@"https://example.invalid/"]];
    Class c = object_getClass(probe);
    Method m = NULL;
    while (c && !(m = class_getInstanceMethod(c, @selector(resume)))) c = class_getSuperclass(c);
    // find the class that actually *owns* the method (not inherited)
    Class owner = object_getClass(probe);
    while (owner) {
        unsigned n = 0; Method *ms = class_copyMethodList(owner, &n); BOOL found = NO;
        for (unsigned i = 0; i < n; i++) if (method_getName(ms[i]) == @selector(resume)) found = YES;
        free(ms);
        if (found) break;
        owner = class_getSuperclass(owner);
    }
    fprintf(stderr, "[snoopy-hook] resume owner class: %s\n", class_getName(owner));
    Method target = class_getInstanceMethod(owner, @selector(resume));
    g_origResume = method_setImplementation(target, (IMP)swz_resume);
}
