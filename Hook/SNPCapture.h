#import <Foundation/Foundation.h>

/// Per-task capture state, attached to NSURLSessionTask via associated object.
@interface SNPRecord : NSObject
@property (nonatomic, copy) NSString *exchangeId;
@property (nonatomic, strong) NSMutableData *responseBody;
@property (nonatomic, strong) NSData *uploadBody;      // set by uploadTask... hooks
@property (nonatomic, strong) NSDictionary *metrics;
@property (nonatomic) NSTimeInterval startedAt;
@property (nonatomic) BOOL requestSent, responseSent, completeSent;
@end

SNPRecord *SNPRecordForTask(NSURLSessionTask *task);
void SNPSendRequest(NSURLSessionTask *task);
void SNPSendResponse(NSURLSessionTask *task, NSURLResponse *response);
void SNPAppendResponseData(NSURLSessionTask *task, NSData *data);
void SNPStoreMetrics(NSURLSessionTask *task, NSURLSessionTaskMetrics *metrics);
/// bodyOverride: data from a completion handler or downloaded file; may be nil to use accumulated data.
void SNPSendComplete(NSURLSessionTask *task, NSURLResponse *response, NSData *bodyOverride, NSError *error);
NSDictionary *SNPHelloMessage(void);
