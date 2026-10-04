
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static dispatch_queue_t gQ;
static NSString *gLogPath;
static NSString *gJsonPath;
static NSMutableArray *gEvents;

static NSString *DocPath(NSString *name) {
    NSArray *a = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *base = a.firstObject ?: NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:name];
}

static void Console(NSString *s) {
    fprintf(stderr, "[V3.3] %s\n", (s ?: @"").UTF8String);
    NSLog(@"[V3.3] %@", s ?: @"");
}

static NSString *RedactURL(NSString *s) {
    if (!s.length) return @"";
    NSURLComponents *c = [NSURLComponents componentsWithString:s];
    if (!c) return s;
    if (c.query.length) c.query = @"<redacted>";
    c.fragment = nil;
    return c.string ?: s;
}

static NSString *Route(NSString *s) {
    NSString *l = s.lowercaseString;
    if ([l hasPrefix:@"webrtc://"]) return @"webrtc";
    if ([l containsString:@"/preview/"] && [l containsString:@".flv"]) return @"preview_http_flv";
    if ([l hasPrefix:@"http://"] || [l hasPrefix:@"https://"]) return [l containsString:@".flv"] ? @"http_flv" : @"http";
    return @"other";
}

static void FlushJSON(void) {
    if (!gEvents) return;
    BOOL ijk = NO, preview = NO, activeV20 = NO;
    for (NSDictionary *e in gEvents) {
        NSString *k = e[@"kind"] ?: @"";
        NSString *r = e[@"route"] ?: @"";
        if ([k hasPrefix:@"ijk_"]) ijk = YES;
        if ([r isEqualToString:@"preview_http_flv"]) preview = YES;
        if ([k hasPrefix:@"v20_call_"] || [k hasPrefix:@"hlll_call_"]) activeV20 = YES;
    }
    NSString *c = @"unknown";
    if (preview && !activeV20) c = @"preview_http_flv_active_only";
    else if (preview && activeV20) c = @"dual_path_actively_called";
    else if (activeV20) c = @"v20_path_actively_called";
    NSDictionary *doc = @{
        @"schema": @"paid-preview-v3.3-active-path",
        @"status": @"ready",
        @"classification": c,
        @"evidence": @{
            @"ijk_called": @(ijk),
            @"preview_http_flv_called": @(preview),
            @"v20_or_hlll_methods_called": @(activeV20)
        },
        @"events": gEvents
    };
    NSData *d = [NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToFile:gJsonPath atomically:YES];
}

static void Event(NSString *kind, NSDictionary *extra) {
    dispatch_async(gQ, ^{
        if (!gEvents) gEvents = [NSMutableArray array];
        NSMutableDictionary *e = [NSMutableDictionary dictionaryWithDictionary:extra ?: @{}];
        e[@"kind"] = kind ?: @"event";
        e[@"ts_ms"] = @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0));
        [gEvents addObject:e];

        NSString *line = [NSString stringWithFormat:@"%@ %@", kind ?: @"event", extra ?: @{}];
        NSData *d = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:d];
            [h closeFile];
        }
        Console(line);
        FlushJSON();
    });
}

static void URLHit(NSString *source, id obj) {
    NSString *s = nil;
    if ([obj isKindOfClass:NSString.class]) s = obj;
    else if ([obj isKindOfClass:NSURL.class]) s = [(NSURL *)obj absoluteString];
    else if (obj) s = [obj description];
    if (!s.length) return;
    NSString *u = RedactURL(s);
    Event(@"url", @{@"source":source ?: @"", @"route":Route(s), @"url":u ?: @""});
}

static BOOL Hook(Class c, SEL s, IMP repl, IMP *orig) {
    if (!c) return NO;
    Method m = class_getInstanceMethod(c, s);
    if (!m) return NO;
    if (orig) *orig = method_getImplementation(m);
    method_setImplementation(m, repl);
    Event(@"hook", @{@"class":NSStringFromClass(c), @"selector":NSStringFromSelector(s)});
    return YES;
}

/* -------- IJK -------- */
typedef id (*Init2)(id,SEL,id,id);
static Init2 oIJKURL, oIJKStr;
static id hIJKURL(id self,SEL _cmd,id url,id opt) {
    URLHit(@"IJK initWithContentURL",url);
    Event(@"ijk_init_url", @{@"options_present":@(opt!=nil)});
    return oIJKURL ? oIJKURL(self,_cmd,url,opt) : self;
}
static id hIJKStr(id self,SEL _cmd,id url,id opt) {
    URLHit(@"IJK initWithContentURLString",url);
    Event(@"ijk_init_string", @{@"options_present":@(opt!=nil)});
    return oIJKStr ? oIJKStr(self,_cmd,url,opt) : self;
}

/* -------- HLLLManager active calls -------- */
typedef int (*RetIntObj)(id,SEL,id);
typedef void (*VoidObj)(id,SEL,id);
typedef void (*Void0)(id,SEL);
static RetIntObj oHLLLPlayStream;
static VoidObj oHLLLSetURL;
static Void0 oHLLLInitClient, oHLLLStop;

static int hHLLLPlayStream(id self,SEL _cmd,id url) {
    URLHit(@"HLLLManager playStream",url);
    Event(@"hlll_call_playStream", @{});
    return oHLLLPlayStream ? oHLLLPlayStream(self,_cmd,url) : 0;
}
static void hHLLLSetURL(id self,SEL _cmd,id url) {
    URLHit(@"HLLLManager setCurrentUrl",url);
    Event(@"hlll_call_setCurrentUrl", @{});
    if (oHLLLSetURL) oHLLLSetURL(self,_cmd,url);
}
static void hHLLLInitClient(id self,SEL _cmd) {
    Event(@"hlll_call_initClient", @{});
    if (oHLLLInitClient) oHLLLInitClient(self,_cmd);
}
static void hHLLLStop(id self,SEL _cmd) {
    Event(@"hlll_call_stop", @{});
    if (oHLLLStop) oHLLLStop(self,_cmd);
}

/* -------- HWLLSClientProxy / V20 chain -------- */
typedef void (*Void0T)(id,SEL);
typedef void (*VoidObjT)(id,SEL,id);
typedef id (*Id0T)(id,SEL);
typedef id (*IdObjT)(id,SEL,id);
typedef id (*IdObjBoolT)(id,SEL,id,BOOL);
typedef int (*IntObjObjT)(id,SEL,id,id);

static Void0T oCreatePC;
static VoidObjT oSetLocalSDP, oSetRemoteSDP, oPrepareStart;
static Id0T oPlaySignaling;
static IdObjT oPlayReqDNS;
static IdObjBoolT oSendSignalDNS;
static IntObjObjT oStartPlay;

static void hCreatePC(id self,SEL _cmd) {
    Event(@"v20_call_createPeerConnection", @{});
    if (oCreatePC) oCreatePC(self,_cmd);
}
static void hSetLocalSDP(id self,SEL _cmd,id sdp) {
    Event(@"v20_call_setLocalSDP", @{@"present":@(sdp!=nil), @"class":sdp?NSStringFromClass([sdp class]):@""});
    if (oSetLocalSDP) oSetLocalSDP(self,_cmd,sdp);
}
static void hSetRemoteSDP(id self,SEL _cmd,id sdp) {
    Event(@"v20_call_setRemoteSDP", @{@"present":@(sdp!=nil), @"class":sdp?NSStringFromClass([sdp class]):@""});
    if (oSetRemoteSDP) oSetRemoteSDP(self,_cmd,sdp);
}
static void hPrepareStart(id self,SEL _cmd,id arg) {
    Event(@"v20_call_prepareStartPlay", @{@"arg_class":arg?NSStringFromClass([arg class]):@""});
    if (oPrepareStart) oPrepareStart(self,_cmd,arg);
}
static id hPlaySignaling(id self,SEL _cmd) {
    Event(@"v20_call_playSignalingRequest", @{});
    return oPlaySignaling ? oPlaySignaling(self,_cmd) : nil;
}
static id hPlayReqDNS(id self,SEL _cmd,id arg) {
    Event(@"v20_call_playRequestWithDnsResult", @{@"arg_class":arg?NSStringFromClass([arg class]):@""});
    return oPlayReqDNS ? oPlayReqDNS(self,_cmd,arg) : nil;
}
static id hSendSignalDNS(id self,SEL _cmd,id arg,BOOL stop) {
    Event(@"v20_call_sendSignalingWithDnsResult", @{@"isStop":@(stop), @"arg_class":arg?NSStringFromClass([arg class]):@""});
    return oSendSignalDNS ? oSendSignalDNS(self,_cmd,arg,stop) : nil;
}
static int hStartPlay(id self,SEL _cmd,id url,id opts) {
    URLHit(@"HWLLSClientProxy startPlay",url);
    Event(@"v20_call_startPlay", @{@"options_class":opts?NSStringFromClass([opts class]):@""});
    return oStartPlay ? oStartPlay(self,_cmd,url,opts) : 0;
}

/* -------- HWLLSManager configuration calls -------- */
typedef void (*VoidIntT)(id,SEL,int);
static VoidObjT oSetSigHost, oSetDomain, oSetTargetDomain;
static VoidIntT oSetSigPort, oSetSigType;

static void hSetSigHost(id self,SEL _cmd,id v){ Event(@"v20_call_setSignalingHost",@{@"value":RedactURL([v description]?:@"")}); if(oSetSigHost)oSetSigHost(self,_cmd,v); }
static void hSetDomain(id self,SEL _cmd,id v){ Event(@"v20_call_setDomain",@{@"value":RedactURL([v description]?:@"")}); if(oSetDomain)oSetDomain(self,_cmd,v); }
static void hSetTargetDomain(id self,SEL _cmd,id v){ Event(@"v20_call_setTargetDomain",@{@"value":RedactURL([v description]?:@"")}); if(oSetTargetDomain)oSetTargetDomain(self,_cmd,v); }
static void hSetSigPort(id self,SEL _cmd,int v){ Event(@"v20_call_setSignalingPort",@{@"port":@(v)}); if(oSetSigPort)oSetSigPort(self,_cmd,v); }
static void hSetSigType(id self,SEL _cmd,int v){ Event(@"v20_call_setSignalingType",@{@"type":@(v)}); if(oSetSigType)oSetSigType(self,_cmd,v); }

__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        gQ = dispatch_queue_create("paidpreview.v3_3", DISPATCH_QUEUE_SERIAL);
        gLogPath = DocPath(@"PaidPreviewV3_3_ActivePathTrace.log");
        gJsonPath = DocPath(@"preview_v3_3_active_path.json");
        [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:nil attributes:nil];
        gEvents = [NSMutableArray array];
        Event(@"startup", @{@"log":gLogPath, @"json":gJsonPath});

        Class ijk = objc_getClass("IJKFFMoviePlayerController");
        Hook(ijk, sel_registerName("initWithContentURL:withOptions:"), (IMP)hIJKURL, (IMP *)&oIJKURL);
        Hook(ijk, sel_registerName("initWithContentURLString:withOptions:"), (IMP)hIJKStr, (IMP *)&oIJKStr);

        Class hlll = objc_getClass("HLLLManager");
        Hook(hlll, sel_registerName("playStream:"), (IMP)hHLLLPlayStream, (IMP *)&oHLLLPlayStream);
        Hook(hlll, sel_registerName("setCurrentUrl:"), (IMP)hHLLLSetURL, (IMP *)&oHLLLSetURL);
        Hook(hlll, sel_registerName("initClient"), (IMP)hHLLLInitClient, (IMP *)&oHLLLInitClient);
        Hook(hlll, sel_registerName("stop"), (IMP)hHLLLStop, (IMP *)&oHLLLStop);

        Class cp = objc_getClass("HWLLSClientProxy");
        Hook(cp, sel_registerName("createPeerConnection"), (IMP)hCreatePC, (IMP *)&oCreatePC);
        Hook(cp, sel_registerName("setLocalSDP:"), (IMP)hSetLocalSDP, (IMP *)&oSetLocalSDP);
        Hook(cp, sel_registerName("setRemoteSDP:"), (IMP)hSetRemoteSDP, (IMP *)&oSetRemoteSDP);
        Hook(cp, sel_registerName("prepareStartPlay:"), (IMP)hPrepareStart, (IMP *)&oPrepareStart);
        Hook(cp, sel_registerName("playSignalingRequest"), (IMP)hPlaySignaling, (IMP *)&oPlaySignaling);
        Hook(cp, sel_registerName("playRequestWithDnsResult:"), (IMP)hPlayReqDNS, (IMP *)&oPlayReqDNS);
        Hook(cp, sel_registerName("sendSignalingWithDnsResult:isStop:"), (IMP)hSendSignalDNS, (IMP *)&oSendSignalDNS);
        Hook(cp, sel_registerName("startPlay:startPlayOptions:"), (IMP)hStartPlay, (IMP *)&oStartPlay);

        Class hm = objc_getClass("HWLLSManager");
        Hook(hm, sel_registerName("setSignalingHost:"), (IMP)hSetSigHost, (IMP *)&oSetSigHost);
        Hook(hm, sel_registerName("setSignalingPort:"), (IMP)hSetSigPort, (IMP *)&oSetSigPort);
        Hook(hm, sel_registerName("setSignalingType:"), (IMP)hSetSigType, (IMP *)&oSetSigType);
        Hook(hm, sel_registerName("setDomain:"), (IMP)hSetDomain, (IMP *)&oSetDomain);
        Hook(hm, sel_registerName("setTargetDomain:"), (IMP)hSetTargetDomain, (IMP *)&oSetTargetDomain);

        Event(@"ready", @{});
    }
}
