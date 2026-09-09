#import <Foundation/Foundation.h>

/// Connects to the Snoopy Mac app over a Unix domain socket and streams
/// length-prefixed JSON frames. Never blocks the caller; never throws.
@interface SNPTransport : NSObject
+ (instancetype)shared;
/// Message sent first on every (re)connect.
@property (atomic, copy) NSDictionary *helloMessage;
- (void)startWithSocketPath:(NSString *)path;
- (void)send:(NSDictionary *)message;
@end
