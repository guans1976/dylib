
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const kLogPath = @"/var/mobile/Documents/PaidPreviewV3_2_V20Compare.log";
static NSString * const kJsonPath = @"/var/mobile/Documents/preview_v3_2_compare.json";
static dispatch_queue_t gQ;
static NSMutableArray *gEvents;

static NSString *SafeString(id x) {
    if (!x) return @"";
    @try { return [x description] ?: @""; } @catch (...) { return @""; }
}

static NSString *RedactURLString(NSString *s) {
    if (!s.length) return @"";
    NSURLComponents *c = [NSURLComponents componentsWithString:s];
    if (!c) return s;
    c.query = c.query.length ? @"<redacted>" : nil;
    c.fragment = nil;
    NSString *r = c.string;
    return r ?: s;
}

static NSString *RouteKind(NSString *s) {
    NSString *l = [s lowercaseString];
    if ([l hasPrefix:@"webrtc://"]) return @"webrtc";
    if ([l containsString:@"/preview/"] && [l containsString:@".flv"]) return @"preview_http_flv";
    if ([l hasPrefix:@"http://"] || [l hasPrefix:@"https://"]) {
        if ([l containsString:@".flv"]) return @"http_flv";
        return @"http";
    }
    return @"other";
}

static void WriteLine(NSString *line) {
    dispatch_async(gQ, ^{
        NSString *out = [NSString stringWithFormat:@"%@\n", line ?: @""];
        NSData *d = [out dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (!h) {
            [d writeToFile:kLogPath atomically:YES];
        } else {
            [h seekToEndOfFile];
            [h writeData:d];
            [h closeFile];
        }
    });
}

static void SaveEvent(NSString *kind, NSDictionary *extra) {
    dispatch_async(gQ, ^{
        if (!gEvents) gEvents = [NSMutableArray array];
        NSMutableDictionary *e = [NSMutableDictionary dictionary];
        e[@"ts_ms"] = @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0));
        e[@"kind"] = kind ?: @"event";
        if (extra) [e addEntriesFromDictionary:extra];
        [gEvents addObject:e];

        BOOL sawPreview = NO, sawWebRTC = NO, sawIJK = NO, sawHW = NO;
        for (NSDictionary *x in gEvents) {
            NSString *k = x[@"kind"] ?: @"";
            NSString *route = x[@"route"] ?: @"";
            if ([route isEqualToString:@"preview_http_flv"]) sawPreview = YES;
            if ([route isEqualToString:@"webrtc"]) sawWebRTC = YES;
            if ([k hasPrefix:@"ijk_"]) sawIJK = YES;
            if ([k hasPrefix:@"hwlls_"] || [k hasPrefix:@"hlll_"]) sawHW = YES;
        }
        NSString *classification = @"unknown";
        if (sawPreview && !sawWebRTC && !sawHW) classification = @"preview_http_flv_only";
        else if (sawWebRTC || sawHW) classification = sawPreview ? @"dual_path_evidence" : @"v20_webrtc_like";
        NSDictionary *doc = @{
            @"schema": @"paid-preview-v3.2-v20-compare",
            @"status": @"ready",
            @"classification": classification,
            @"evidence": @{
                @"preview_http_flv": @(sawPreview),
                @"webrtc_url": @(sawWebRTC),
                @"ijk_player": @(sawIJK),
                @"hwlls_or_hlll_runtime": @(sawHW)
            },
            @"events": gEvents
        };
        NSData *jd = [NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted error:nil];
        [jd writeToFile:kJsonPath atomically:YES];
    });
}

static void LogURL(NSString *source, NSString *raw) {
    if (!raw.length) return;
    NSString *red = RedactURLString(raw);
    NSString *route = RouteKind(raw);
    WriteLine([NSString stringWithFormat:@"URL source=%@ route=%@ url=%@", source, route, red]);
    SaveEvent(@"url", @{@"source": source ?: @"", @"route": route, @"url": red});
}

#pragma mark - IJK hooks

typedef id (*Init2IMP)(id, SEL, id, id);
static Init2IMP origIJKURL = NULL;
static Init2IMP origIJKString = NULL;

static id replIJKURL(id self, SEL _cmd, id url, id options) {
    LogURL(@"IJK initWithContentURL:withOptions:", SafeString(url));
    SaveEvent(@"ijk_init_url", @{@"options_present": @(options != nil)});
    return origIJKURL ? origIJKURL(self, _cmd, url, options) : self;
}

static id replIJKString(id self, SEL _cmd, id url, id options) {
    LogURL(@"IJK initWithContentURLString:withOptions:", SafeString(url));
    SaveEvent(@"ijk_init_string", @{@"options_present": @(options != nil)});
    return origIJKString ? origIJKString(self, _cmd, url, options) : self;
}

typedef void (*SetObjIMP)(id, SEL, id);
static SetObjIMP origSetUrl = NULL;
static void replSetUrl(id self, SEL _cmd, id url) {
    LogURL(@"IJKMediaUrlOpenData setUrl:", SafeString(url));
    SaveEvent(@"ijk_media_set_url", @{});
    if (origSetUrl) origSetUrl(self, _cmd, url);
}

static BOOL HookInstance(Class c, SEL s, IMP replacement, IMP *origOut) {
    if (!c || !s) return NO;
    Method m = class_getInstanceMethod(c, s);
    if (!m) return NO;
    IMP old = method_getImplementation(m);
    if (!old) return NO;
    if (origOut) *origOut = old;
    method_setImplementation(m, replacement);
    WriteLine([NSString stringWithFormat:@"HOOK %@ %@ types=%s",
               NSStringFromClass(c), NSStringFromSelector(s), method_getTypeEncoding(m)]);
    return YES;
}

#pragma mark - NSURLSession metadata-only trace

typedef NSURLSessionDataTask *(*TaskReqIMP)(id,SEL,NSURLRequest *,void(^)(NSData *,NSURLResponse *,NSError *));
static TaskReqIMP origTaskReq = NULL;
static NSURLSessionDataTask *replTaskReq(id self, SEL _cmd, NSURLRequest *req,
                                        void (^completion)(NSData *,NSURLResponse *,NSError *)) {
    NSString *u = req.URL.absoluteString ?: @"";
    LogURL(@"NSURLSession request", u);
    return origTaskReq ? origTaskReq(self,_cmd,req,completion) : nil;
}

#pragma mark - Runtime evidence

static void DumpInterestingRuntime(void) {
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return;

    Class __unsafe_unretained *classes =
        (Class __unsafe_unretained *)calloc((size_t)total, sizeof(Class));
    if (!classes) return;

    total = objc_getClassList(classes, total);
    NSArray<NSString *> *needles = @[@"HWLLS", @"HLLL", @"WebRTC", @"RTC", @"IJK"];
    for (int i=0; i<total; i++) {
        Class c = classes[i];
        NSString *name = NSStringFromClass(c) ?: @"";
        BOOL hit = NO;
        for (NSString *n in needles) {
            if ([name rangeOfString:n options:NSCaseInsensitiveSearch].location != NSNotFound) {
                hit = YES; break;
            }
        }
        if (!hit) continue;

        NSString *prefix = @"runtime";
        if ([name rangeOfString:@"HWLLS" options:NSCaseInsensitiveSearch].location != NSNotFound) prefix = @"hwlls_runtime";
        else if ([name rangeOfString:@"HLLL" options:NSCaseInsensitiveSearch].location != NSNotFound) prefix = @"hlll_runtime";

        unsigned int mc = 0;
        Method *methods = class_copyMethodList(c, &mc);
        NSMutableArray *names = [NSMutableArray array];
        for (unsigned int j=0; j<mc && j<80; j++) {
            SEL s = method_getName(methods[j]);
            const char *t = method_getTypeEncoding(methods[j]);
            [names addObject:[NSString stringWithFormat:@"%@ [%s]", NSStringFromSelector(s), t ?: ""]];
        }
        if (methods) free(methods);

        SaveEvent(prefix, @{@"class": name, @"methods": names});
        WriteLine([NSString stringWithFormat:@"CLASS %@ METHODS %@", name, [names componentsJoinedByString:@" | "]]);
    }
    free(classes);
}

__attribute__((constructor))
static void PPInit(void) {
    @autoreleasepool {
        gQ = dispatch_queue_create("paidpreview.v3_2.trace", DISPATCH_QUEUE_SERIAL);
        [[NSFileManager defaultManager] createFileAtPath:kLogPath contents:nil attributes:nil];

        WriteLine(@"PaidPreviewV3.2 V20 Compare Trace active");
        SaveEvent(@"startup", @{});

        Class ijk = objc_getClass("IJKFFMoviePlayerController");
        if (ijk) {
            HookInstance(ijk, sel_registerName("initWithContentURL:withOptions:"),
                         (IMP)replIJKURL, (IMP *)&origIJKURL);
            HookInstance(ijk, sel_registerName("initWithContentURLString:withOptions:"),
                         (IMP)replIJKString, (IMP *)&origIJKString);
        }

        Class openData = objc_getClass("IJKMediaUrlOpenData");
        if (openData) {
            HookInstance(openData, sel_registerName("setUrl:"),
                         (IMP)replSetUrl, (IMP *)&origSetUrl);
        }

        Class session = objc_getClass("NSURLSession");
        if (session) {
            HookInstance(session, @selector(dataTaskWithRequest:completionHandler:),
                         (IMP)replTaskReq, (IMP *)&origTaskReq);
        }

        DumpInterestingRuntime();
        SaveEvent(@"ready", @{});
        WriteLine(@"V3.2 READY");
    }
}
