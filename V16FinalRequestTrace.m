
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *FRDocsPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:@"V16_FinalRequestTrace.log"];
}

static NSString *FRSHA256Data(NSData *data) {
    if (!data || data.length == 0) return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];
    for (int i=0; i<CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", digest[i]];
    return s;
}

static NSString *FRSHA256String(NSString *s) {
    if (!s) return @"";
    return FRSHA256Data([s dataUsingEncoding:NSUTF8StringEncoding]);
}

static BOOL FRInterestingURL(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path ?: @"";
    if (![host isEqualToString:@"api.qituoc.com"]) return NO;
    return [path containsString:@"/OpenAPI/v1/anchor/all"] ||
           [path containsString:@"/OpenAPI/v1/private/getPrivateLimit"] ||
           [path containsString:@"/OpenAPI/v1/"];
}

static NSString *FRRedactedURL(NSURL *url) {
    if (!url) return @"";
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!c) return url.absoluteString ?: @"";
    NSSet *sensitive = [NSSet setWithArray:@[
        @"token",@"access_token",@"authorization",@"auth",@"secret",@"sign",@"signature",
        @"password",@"passwd",@"pwd",@"cookie",@"txsecret",@"txtime"
    ]];
    NSMutableArray *items = [NSMutableArray array];
    for (NSURLQueryItem *it in c.queryItems ?: @[]) {
        NSString *name = it.name ?: @"";
        NSString *value = it.value ?: @"";
        if ([sensitive containsObject:name.lowercaseString]) {
            NSString *v = [NSString stringWithFormat:@"<redacted,len=%lu,sha256=%@>",
                           (unsigned long)value.length, FRSHA256String(value)];
            [items addObject:[NSURLQueryItem queryItemWithName:name value:v]];
        } else {
            [items addObject:it];
        }
    }
    c.queryItems = items;
    return c.URL.absoluteString ?: url.absoluteString ?: @"";
}

static NSString *FRHeaderSummary(NSDictionary<NSString*,NSString*> *headers) {
    if (![headers isKindOfClass:[NSDictionary class]]) return @"";
    NSMutableArray *parts = [NSMutableArray array];
    NSSet *sensitive = [NSSet setWithArray:@[
        @"authorization",@"cookie",@"x-live-butter2"
    ]];
    NSArray *keys = [[headers allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    for (NSString *key in keys) {
        NSString *val = [NSString stringWithFormat:@"%@", headers[key] ?: @""];
        if ([sensitive containsObject:key.lowercaseString]) {
            [parts addObject:[NSString stringWithFormat:@"%@=<redacted,len=%lu,sha256=%@>",
                              key,(unsigned long)val.length,FRSHA256String(val)]];
        } else {
            [parts addObject:[NSString stringWithFormat:@"%@=%@",key,val]];
        }
    }
    return [parts componentsJoinedByString:@"; "];
}

static NSString *FRStack(void) {
    NSArray *syms = NSThread.callStackSymbols;
    NSUInteger n = MIN((NSUInteger)20, syms.count);
    return [[syms subarrayWithRange:NSMakeRange(0,n)] componentsJoinedByString:@" | "];
}

static void FRLogLine(NSString *line) {
    if (!line) return;
    NSString *ts = [[NSDate date] descriptionWithLocale:nil];
    NSString *full = [NSString stringWithFormat:@"[%@] %@\n", ts, line];
    NSData *d = [full dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = FRDocsPath();

    @synchronized([NSFileHandle class]) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [d writeToFile:path atomically:YES];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            [fh seekToEndOfFile];
            [fh writeData:d];
            [fh closeFile];
        }
    }
}

static NSString *FRBodySummary(NSURLRequest *req) {
    NSData *body = req.HTTPBody;
    if (body) {
        return [NSString stringWithFormat:@"body_source=HTTPBody body_len=%lu body_sha256=%@",
                (unsigned long)body.length, FRSHA256Data(body)];
    }
    if (req.HTTPBodyStream) {
        return @"body_source=HTTPBodyStream body_len=unknown body_sha256=not_read";
    }
    return @"body_source=none body_len=0 body_sha256=";
}

static void FRTraceRequest(NSURLRequest *req, NSString *stage) {
    if (!req || !FRInterestingURL(req.URL)) return;
    NSString *line = [NSString stringWithFormat:
        @"FINAL stage=%@ method=%@ url=%@ %@ headers={%@} session_main=%d stack=%@",
        stage ?: @"",
        req.HTTPMethod ?: @"",
        FRRedactedURL(req.URL),
        FRBodySummary(req),
        FRHeaderSummary(req.allHTTPHeaderFields ?: @{}),
        [NSThread isMainThread] ? 1 : 0,
        FRStack()
    ];
    FRLogLine(line);
}

static void FRSwizzle(Class cls, SEL original, SEL replacement) {
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (!a || !b) return;
    BOOL added = class_addMethod(cls, original, method_getImplementation(b), method_getTypeEncoding(b));
    if (added) {
        class_replaceMethod(cls, replacement, method_getImplementation(a), method_getTypeEncoding(a));
    } else {
        method_exchangeImplementations(a, b);
    }
}

@interface NSURLSession (V16FinalRequestTrace)
- (NSURLSessionDataTask *)fr_dataTaskWithRequest:(NSURLRequest *)request;
- (NSURLSessionDataTask *)fr_dataTaskWithRequest:(NSURLRequest *)request
                               completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
- (NSURLSessionUploadTask *)fr_uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData;
- (NSURLSessionUploadTask *)fr_uploadTaskWithRequest:(NSURLRequest *)request
                                           fromData:(NSData *)bodyData
                                  completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
@end

@implementation NSURLSession (V16FinalRequestTrace)

- (NSURLSessionDataTask *)fr_dataTaskWithRequest:(NSURLRequest *)request {
    FRTraceRequest(request, @"NSURLSession dataTaskWithRequest:");
    return [self fr_dataTaskWithRequest:request];
}

- (NSURLSessionDataTask *)fr_dataTaskWithRequest:(NSURLRequest *)request
                               completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    FRTraceRequest(request, @"NSURLSession dataTaskWithRequest:completionHandler:");
    return [self fr_dataTaskWithRequest:request completionHandler:completionHandler];
}

- (NSURLSessionUploadTask *)fr_uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData {
    if (request && FRInterestingURL(request.URL)) {
        FRTraceRequest(request, @"NSURLSession uploadTaskWithRequest:fromData:");
        FRLogLine([NSString stringWithFormat:@"UPLOAD body_len=%lu body_sha256=%@",
                   (unsigned long)bodyData.length, FRSHA256Data(bodyData)]);
    }
    return [self fr_uploadTaskWithRequest:request fromData:bodyData];
}

- (NSURLSessionUploadTask *)fr_uploadTaskWithRequest:(NSURLRequest *)request
                                           fromData:(NSData *)bodyData
                                  completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (request && FRInterestingURL(request.URL)) {
        FRTraceRequest(request, @"NSURLSession uploadTaskWithRequest:fromData:completionHandler:");
        FRLogLine([NSString stringWithFormat:@"UPLOAD body_len=%lu body_sha256=%@",
                   (unsigned long)bodyData.length, FRSHA256Data(bodyData)]);
    }
    return [self fr_uploadTaskWithRequest:request fromData:bodyData completionHandler:completionHandler];
}
@end

@interface NSURLSessionTask (V16FinalRequestTrace)
- (void)fr_resume;
@end

@implementation NSURLSessionTask (V16FinalRequestTrace)
- (void)fr_resume {
    NSURLRequest *cur = nil;
    @try { cur = self.currentRequest ?: self.originalRequest; } @catch (__unused NSException *e) {}
    FRTraceRequest(cur, @"NSURLSessionTask resume");
    [self fr_resume];
}
@end

__attribute__((constructor))
static void V16FinalRequestTraceInit(void) {
    @autoreleasepool {
        FRSwizzle([NSURLSession class],
                  @selector(dataTaskWithRequest:),
                  @selector(fr_dataTaskWithRequest:));
        FRSwizzle([NSURLSession class],
                  @selector(dataTaskWithRequest:completionHandler:),
                  @selector(fr_dataTaskWithRequest:completionHandler:));
        FRSwizzle([NSURLSession class],
                  @selector(uploadTaskWithRequest:fromData:),
                  @selector(fr_uploadTaskWithRequest:fromData:));
        FRSwizzle([NSURLSession class],
                  @selector(uploadTaskWithRequest:fromData:completionHandler:),
                  @selector(fr_uploadTaskWithRequest:fromData:completionHandler:));
        FRSwizzle([NSURLSessionTask class],
                  @selector(resume),
                  @selector(fr_resume));
        FRLogLine(@"V16 Final Request Trace loaded");
    }
}
