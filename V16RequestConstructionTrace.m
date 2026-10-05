
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *V16RCTPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:@"V16_RequestConstructionTrace.log"];
}

static NSString *V16SHA256(NSData *data) {
    if (!data || data.length == 0) return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *s=[NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];
    for (int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [s appendFormat:@"%02x",digest[i]];
    return s;
}

static BOOL V16InterestingURL(NSURL *url) {
    if (!url) return NO;
    NSString *s = url.absoluteString ?: @"";
    return [s containsString:@"/OpenAPI/v1/anchor/all"] ||
           [s containsString:@"/OpenAPI/v1/private/getPrivateLimit"] ||
           [s containsString:@"api.qituoc.com"];
}

static void V16Log(NSString *line) {
    if (!line) return;
    NSString *ts = [[NSDate date] descriptionWithLocale:nil];
    NSString *full = [NSString stringWithFormat:@"[%@] %@\n", ts, line];
    NSData *d=[full dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path=V16RCTPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [d writeToFile:path atomically:YES];
    } else {
        NSFileHandle *fh=[NSFileHandle fileHandleForWritingAtPath:path];
        [fh seekToEndOfFile];
        [fh writeData:d];
        [fh closeFile];
    }
}

static NSString *V16Stack(void) {
    NSArray *syms=[NSThread callStackSymbols];
    NSUInteger n=MIN((NSUInteger)18, syms.count);
    return [[syms subarrayWithRange:NSMakeRange(0,n)] componentsJoinedByString:@" | "];
}

static NSString *V16SafeHeaderSummary(NSDictionary *headers) {
    if (![headers isKindOfClass:[NSDictionary class]]) return @"";
    NSMutableArray *parts=[NSMutableArray array];
    for (id k in headers) {
        NSString *key=[NSString stringWithFormat:@"%@",k];
        NSString *val=[NSString stringWithFormat:@"%@",headers[k]];
        NSString *lower=key.lowercaseString;
        if ([lower isEqualToString:@"authorization"] ||
            [lower isEqualToString:@"cookie"] ||
            [lower isEqualToString:@"x-live-butter2"]) {
            [parts addObject:[NSString stringWithFormat:@"%@=<redacted,len=%lu>",
                              key,(unsigned long)val.length]];
        } else {
            [parts addObject:[NSString stringWithFormat:@"%@=%@",key,val]];
        }
    }
    return [parts componentsJoinedByString:@"; "];
}

static void V16TraceRequest(NSMutableURLRequest *req, NSString *op, NSString *extra) {
    if (!req) return;
    NSURL *url=req.URL;
    if (!V16InterestingURL(url)) return;

    NSData *body=req.HTTPBody;
    NSString *bodyInfo=[NSString stringWithFormat:@"body_len=%lu body_sha256=%@",
                        (unsigned long)(body.length), V16SHA256(body)];
    NSString *headers=V16SafeHeaderSummary(req.allHTTPHeaderFields ?: @{});
    V16Log([NSString stringWithFormat:
            @"REQ op=%@ method=%@ url=%@ %@ headers={%@} extra={%@} stack=%@",
            op ?: @"",
            req.HTTPMethod ?: @"",
            url.absoluteString ?: @"",
            bodyInfo,
            headers,
            extra ?: @"",
            V16Stack()]);
}

@interface NSMutableURLRequest (V16RequestConstructionTrace)
@end

@implementation NSMutableURLRequest (V16RequestConstructionTrace)
@end

static void v16_swizzle(Class cls, SEL orig, SEL repl) {
    Method m1=class_getInstanceMethod(cls,orig);
    Method m2=class_getInstanceMethod(cls,repl);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1,m2);
}

@interface NSMutableURLRequest (V16Hooks)
- (void)v16_setValue:(NSString *)value forHTTPHeaderField:(NSString *)field;
- (void)v16_addValue:(NSString *)value forHTTPHeaderField:(NSString *)field;
- (void)v16_setAllHTTPHeaderFields:(NSDictionary<NSString *,NSString *> *)headerFields;
- (void)v16_setHTTPBody:(NSData *)data;
- (void)v16_setURL:(NSURL *)URL;
- (void)v16_setHTTPMethod:(NSString *)method;
@end

@implementation NSMutableURLRequest (V16Hooks)

- (void)v16_setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    [self v16_setValue:value forHTTPHeaderField:field];
    if (V16InterestingURL(self.URL)) {
        NSString *lower=field.lowercaseString ?: @"";
        NSString *shown=value ?: @"";
        if ([lower isEqualToString:@"authorization"] ||
            [lower isEqualToString:@"cookie"] ||
            [lower isEqualToString:@"x-live-butter2"]) {
            shown=[NSString stringWithFormat:@"<redacted,len=%lu>",(unsigned long)shown.length];
        }
        V16TraceRequest(self, @"setValue:forHTTPHeaderField:",
                        [NSString stringWithFormat:@"%@=%@",field ?: @"",shown]);
    }
}

- (void)v16_addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    [self v16_addValue:value forHTTPHeaderField:field];
    if (V16InterestingURL(self.URL)) {
        NSString *lower=field.lowercaseString ?: @"";
        NSString *shown=value ?: @"";
        if ([lower isEqualToString:@"authorization"] ||
            [lower isEqualToString:@"cookie"] ||
            [lower isEqualToString:@"x-live-butter2"]) {
            shown=[NSString stringWithFormat:@"<redacted,len=%lu>",(unsigned long)shown.length];
        }
        V16TraceRequest(self, @"addValue:forHTTPHeaderField:",
                        [NSString stringWithFormat:@"%@=%@",field ?: @"",shown]);
    }
}

- (void)v16_setAllHTTPHeaderFields:(NSDictionary<NSString *,NSString *> *)headerFields {
    [self v16_setAllHTTPHeaderFields:headerFields];
    if (V16InterestingURL(self.URL)) {
        V16TraceRequest(self, @"setAllHTTPHeaderFields:",
                        V16SafeHeaderSummary(headerFields ?: @{}));
    }
}

- (void)v16_setHTTPBody:(NSData *)data {
    [self v16_setHTTPBody:data];
    if (V16InterestingURL(self.URL)) {
        V16TraceRequest(self, @"setHTTPBody:",
                        [NSString stringWithFormat:@"len=%lu sha256=%@",
                         (unsigned long)data.length,V16SHA256(data)]);
    }
}

- (void)v16_setURL:(NSURL *)URL {
    [self v16_setURL:URL];
    if (V16InterestingURL(URL)) {
        V16TraceRequest(self, @"setURL:", URL.absoluteString ?: @"");
    }
}

- (void)v16_setHTTPMethod:(NSString *)method {
    [self v16_setHTTPMethod:method];
    if (V16InterestingURL(self.URL)) {
        V16TraceRequest(self, @"setHTTPMethod:", method ?: @"");
    }
}

@end

__attribute__((constructor))
static void V16RequestConstructionTraceInit(void) {
    @autoreleasepool {
        Class cls=[NSMutableURLRequest class];
        v16_swizzle(cls,@selector(setValue:forHTTPHeaderField:),@selector(v16_setValue:forHTTPHeaderField:));
        v16_swizzle(cls,@selector(addValue:forHTTPHeaderField:),@selector(v16_addValue:forHTTPHeaderField:));
        v16_swizzle(cls,@selector(setAllHTTPHeaderFields:),@selector(v16_setAllHTTPHeaderFields:));
        v16_swizzle(cls,@selector(setHTTPBody:),@selector(v16_setHTTPBody:));
        v16_swizzle(cls,@selector(setURL:),@selector(v16_setURL:));
        v16_swizzle(cls,@selector(setHTTPMethod:),@selector(v16_setHTTPMethod:));
        V16Log(@"V16 Request Construction Trace loaded");
    }
}
