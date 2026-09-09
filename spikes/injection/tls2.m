#import <Foundation/Foundation.h>
int main(int argc, char **argv) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSString *u = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"https://localhost:8443/";
    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:u] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        printf("TLS status=%ld body=%s\nERR=%s\n", (long)((NSHTTPURLResponse*)r).statusCode, d ? [[NSString alloc] initWithData:d encoding:4].UTF8String : "", e ? e.description.UTF8String : "none");
        dispatch_semaphore_signal(sem);
    }];
    [t resume]; dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15*NSEC_PER_SEC)); return 0;
}
