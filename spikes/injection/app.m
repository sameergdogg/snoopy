#import <Foundation/Foundation.h>
int main(void) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://httpbin.org/post"]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [@"{\"hello\":\"snoopy\"}" dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSLog(@"app: status=%ld err=%@ bytes=%lu", (long)((NSHTTPURLResponse*)r).statusCode, e, (unsigned long)d.length);
        dispatch_semaphore_signal(sem);
    }];
    [t resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20*NSEC_PER_SEC));
    return 0;
}
