
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static dispatch_queue_t gQ;
static NSMutableArray *gEvents;
static NSString *gLogPath;
static NSString *gJsonPath;

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
    return c.string ?: s;
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

static void ConsoleLine(NSString *line) {
    fprintf(stderr, "[V3.2.1] %s\n", (line ?: @"").UTF8String);
    NSLog(@"[V3.2.1] %@", line ?: @"");
}

static BOOL EnsureWritableFile(NSString *path) {
    if (!path.length) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSError *err = nil;
    if (![fm fileExistsAtPath:dir]) {
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err]) {
            ConsoleLine([NSString stringWithFormat:@"createDirectory failed path=%@ error=%@", dir, err]);
            return NO;
        }
    }
    if (![fm fileExistsAtPath:path]) {
        BOOL ok = [fm createFileAtPath:path contents:[NSData data] attributes:nil];
        if (!ok) {
            ConsoleLine([NSString stringWithFormat:@"createFile failed path=%@", path]);
            return NO;
        }
    }
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) {
        ConsoleLine([NSString stringWithFormat:@"fileHandle failed path=%@", path]);
        return NO;
    }
    [h closeFile];
    return YES;
}

static void InitPaths(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *base = docs.firstObject;

    if (!base.length) {
        base = NSTemporaryDirectory();
        ConsoleLine([NSString stringWithFormat:@"Documents unavailable, fallback temp=%@", base]);
    } else {
        ConsoleLine([NSString stringWithFormat:@"Documents=%@", base]);
    }

    gLogPath = [base stringByAppendingPathComponent:@"PaidPreviewV3_2_1_V20Compare.log"];
    gJsonPath = [base stringByAppendingPathComponent:@"preview_v3_2_1_compare.json"];

    if (!EnsureWritableFile(gLogPath)) {
        NSString *tmp = NSTemporaryDirectory();
        gLogPath = [tmp stringByAppendingPathComponent:@"PaidPreviewV3_2_1_V20Compare.log"];
        gJsonPath = [tmp stringByAppendingPathComponent:@"preview_v3_2_1_compare.json"];
        ConsoleLine([NSString stringWithFormat:@"fallback log=%@", gLogPath]);
        EnsureWritableFile(gLogPath);
    }

    ConsoleLine([NSString stringWithFormat:@"log=%@", gLogPath]);
    ConsoleLine([NSString stringWithFormat:@"json=%@", gJsonPath]);
}

static void WriteLineSync(NSString *line) {
    NSString *out = [NSString stringWithFormat:@"%@\n", line ?: @""];
    NSData *d = [out dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (!h) {
        ConsoleLine([NSString stringWithFormat:@"WRITE FAIL no handle path=%@", gLogPath]);
        return;
    }
    @try {
        [h seekToEndOfFile];
        [h writeData:d];
        [h synchronizeFile];
    } @catch (NSException *ex) {
        ConsoleLine([NSString stringWithFormat:@"WRITE EXCEPTION %@", ex]);
    }
    [h closeFile];
}

static void WriteLine(NSString *line) {
    ConsoleLine(line);
    if (!gQ) return;
    dispatch_async(gQ, ^{
        WriteLineSync(line);
    });
}

static void SaveEventSync(NSString *kind, NSDictionary *extra) {
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
        @"schema": @"paid-preview-v3.2.1-v20-compare",
        @"status": @"ready",
        @"classification": classification,
        @"paths": @{
            @"log": gLogPath ?: @"",
            @"json": gJsonPath ?: @""
        },
        @"evidence": @{
            @"preview_http_flv": @(sawPreview),
            @"webrtc_url": @(sawWebRTC),
            @"ijk_player": @(sawIJK),
            @"hwlls_or_hlll_runtime": @(sawHW)
        },
        @"events": gEvents
    };

    NSError *err = nil;
    NSData *jd = [NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted error:&err];
    if (!jd || err) {
        ConsoleLine([NSString stringWithFormat:@"JSON serialize failed error=%@", err]);
        return;
    }
    BOOL ok = [jd writeToFile:gJsonPath options:NSDataWritingAtomic error:&err];
    if (!ok || err) {
        ConsoleLine([NSString stringWithFormat:@"JSON write failed path=%@ error=%@", gJsonPath, err]);
    }
}

static void SaveEvent(NSString *kind, NSDictionary *extra) {
    if (!gQ) return;
    dispatch_async(gQ, ^{
        SaveEventSync(kind, extra);
    });
}

static void LogURL(NSString *source, NSString *raw) {
    if (!raw.length) return;
    NSString *red = RedactURLString(raw);
    NSString *route = RouteKind(raw);
    WriteLine([NSString stringWithFormat:@"URL source=%@ route=%@ url=%@", source, route, red]);
    SaveEvent(@"url", @{@"source": source ?: @"", @"route": route, @"url": red});
}

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

typedef NSURLSessionDataTask *(*TaskReqIMP)(id, SEL, NSURLRequest *, void(^)(NSData *, NSURLResponse *, NSError *));
static TaskReqIMP origTaskReq = NULL;

static NSURLSessionDataTask *replTaskReq(id self, SEL _cmd, NSURLRequest *req,
                                        void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    NSString *u = req.URL.absoluteString ?: @"";
    LogURL(@"NSURLSession request", u);
    return origTaskReq ? origTaskReq(self, _cmd, req, completion) : nil;
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

static void DumpInterestingRuntime(void) {
    int total = objc_getClassList(NULL, 0);
    WriteLine([NSString stringWithFormat:@"objc class count=%d", total]);
    if (total <= 0) return;

    Class __unsafe_unretained *classes =
        (Class __unsafe_unretained *)calloc((size_t)total, sizeof(Class));
    if (!classes) {
        WriteLine(@"calloc class list failed");
        return;
    }

    total = objc_getClassList(classes, total);
    NSArray<NSString *> *needles = @[@"HWLLS", @"HLLL", @"WebRTC", @"RTC", @"IJK"];

    for (int i=0; i<total; i++) {
        Class c = classes[i];
        NSString *name = NSStringFromClass(c) ?: @"";
        BOOL hit = NO;
        for (NSString *n in needles) {
            if ([name rangeOfString:n options:NSCaseInsensitiveSearch].location != NSNotFound) {
                hit = YES;
                break;
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
        gQ = dispatch_queue_create("paidpreview.v3_2_1.trace", DISPATCH_QUEUE_SERIAL);

        ConsoleLine(@"constructor entered");
        InitPaths();

        WriteLineSync(@"PaidPreviewV3.2.1 V20 Compare Trace active");
        SaveEventSync(@"startup", @{});

        int hooks = 0;

        Class ijk = objc_getClass("IJKFFMoviePlayerController");
        if (ijk) {
            if (HookInstance(ijk, sel_registerName("initWithContentURL:withOptions:"),
                             (IMP)replIJKURL, (IMP *)&origIJKURL)) hooks++;
            if (HookInstance(ijk, sel_registerName("initWithContentURLString:withOptions:"),
                             (IMP)replIJKString, (IMP *)&origIJKString)) hooks++;
        } else {
            WriteLine(@"IJKFFMoviePlayerController not present at constructor time");
        }

        Class openData = objc_getClass("IJKMediaUrlOpenData");
        if (openData) {
            if (HookInstance(openData, sel_registerName("setUrl:"),
                             (IMP)replSetUrl, (IMP *)&origSetUrl)) hooks++;
        } else {
            WriteLine(@"IJKMediaUrlOpenData not present at constructor time");
        }

        Class session = objc_getClass("NSURLSession");
        if (session) {
            if (HookInstance(session, @selector(dataTaskWithRequest:completionHandler:),
                             (IMP)replTaskReq, (IMP *)&origTaskReq)) hooks++;
        }

        DumpInterestingRuntime();

        SaveEventSync(@"ready", @{@"hooks": @(hooks)});
        WriteLineSync([NSString stringWithFormat:@"V3.2.1 READY hooks=%d", hooks]);
        ConsoleLine(@"constructor finished");
    }
}
