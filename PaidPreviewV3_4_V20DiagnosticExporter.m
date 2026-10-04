
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static dispatch_queue_t gQ;
static NSString *gLogPath;
static NSString *gJsonPath;
static NSMutableArray *gEvents;
static NSMutableDictionary *gState;

static NSString *DocPath(NSString *name) {
    NSArray *a = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *base = a.firstObject ?: NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:name];
}

static void Console(NSString *s) {
    fprintf(stderr, "[V3.4] %s\n", (s ?: @"").UTF8String);
    NSLog(@"[V3.4] %@", s ?: @"");
}

static NSString *SafeDesc(id x) {
    if (!x) return @"";
    @try { return [x description] ?: @""; } @catch (...) { return @""; }
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

/* Sanitized SDP summary only.
   We deliberately do NOT export ICE passwords, ICE ufrags, fingerprints,
   candidates, auth tokens, or full SDP blobs. */
static NSDictionary *SDPSummary(NSString *sdp) {
    if (!sdp.length) return @{@"present":@NO};
    NSMutableArray *media = [NSMutableArray array];
    NSMutableArray *codecs = [NSMutableArray array];
    NSMutableArray *mids = [NSMutableArray array];
    NSMutableArray *dirs = [NSMutableArray array];

    NSArray *lines = [sdp componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([line hasPrefix:@"m="]) [media addObject:line];
        else if ([line hasPrefix:@"a=rtpmap:"]) [codecs addObject:line];
        else if ([line hasPrefix:@"a=mid:"]) [mids addObject:line];
        else if ([line isEqualToString:@"a=recvonly"] ||
                 [line isEqualToString:@"a=sendonly"] ||
                 [line isEqualToString:@"a=sendrecv"] ||
                 [line isEqualToString:@"a=inactive"]) [dirs addObject:line];
    }
    return @{
        @"present": @YES,
        @"length": @(sdp.length),
        @"media": media,
        @"codecs": codecs,
        @"mids": mids,
        @"directions": dirs
    };
}

static void FlushJSON(void) {
    NSDictionary *doc = @{
        @"schema": @"paid-preview-v3.4-v20-diagnostic",
        @"status": @"ready",
        @"state": gState ?: @{},
        @"events": gEvents ?: @[]
    };
    NSError *err = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted error:&err];
    if (!d || err) {
        Console([NSString stringWithFormat:@"JSON serialize failed %@", err]);
        return;
    }
    [d writeToFile:gJsonPath options:NSDataWritingAtomic error:&err];
    if (err) Console([NSString stringWithFormat:@"JSON write failed %@", err]);
}

static void Event(NSString *kind, NSDictionary *extra) {
    dispatch_async(gQ, ^{
        if (!gEvents) gEvents = [NSMutableArray array];
        NSMutableDictionary *e = [NSMutableDictionary dictionaryWithDictionary:extra ?: @{}];
        e[@"kind"] = kind ?: @"event";
        e[@"ts_ms"] = @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0));
        [gEvents addObject:e];

        NSString *line = [NSString stringWithFormat:@"%@ %@", kind ?: @"event", extra ?: @{}];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
        Console(line);
        FlushJSON();
    });
}

static void StateSet(NSString *key, id value) {
    dispatch_async(gQ, ^{
        if (!gState) gState = [NSMutableDictionary dictionary];
        if (key && value) gState[key] = value;
        FlushJSON();
    });
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

static void URLHit(NSString *source, id obj) {
    NSString *s = nil;
    if ([obj isKindOfClass:NSString.class]) s = obj;
    else if ([obj isKindOfClass:NSURL.class]) s = [(NSURL *)obj absoluteString];
    else s = SafeDesc(obj);
    if (!s.length) return;
    NSString *r = RedactURL(s);
    Event(@"url", @{@"source":source ?: @"", @"route":Route(s), @"url":r ?: @""});
    if ([Route(s) isEqualToString:@"webrtc"]) StateSet(@"webrtc_stream_url_redacted", r);
    if ([Route(s) isEqualToString:@"preview_http_flv"]) StateSet(@"preview_flv_url", r);
}

/* IJK */
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

/* HLLL */
typedef int (*RetIntObj)(id,SEL,id);
typedef void (*VoidObj)(id,SEL,id);
typedef void (*Void0)(id,SEL);

static RetIntObj oPlayStream;
static VoidObj oSetCurrentUrl;
static Void0 oInitClient, oStop;

static int hPlayStream(id self,SEL _cmd,id url) {
    URLHit(@"HLLLManager playStream",url);
    Event(@"hlll_playStream", @{});
    return oPlayStream ? oPlayStream(self,_cmd,url) : 0;
}
static void hSetCurrentUrl(id self,SEL _cmd,id url) {
    URLHit(@"HLLLManager setCurrentUrl",url);
    Event(@"hlll_setCurrentUrl", @{});
    if (oSetCurrentUrl) oSetCurrentUrl(self,_cmd,url);
}
static void hInitClient(id self,SEL _cmd) {
    Event(@"hlll_initClient", @{});
    if (oInitClient) oInitClient(self,_cmd);
}
static void hStop(id self,SEL _cmd) {
    Event(@"hlll_stop", @{});
    StateSet(@"stop_ts_ms", @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)));
    if (oStop) oStop(self,_cmd);
}

/* HWLLSClientProxy */
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
    Event(@"v20_createPeerConnection", @{});
    StateSet(@"peer_connection_created", @YES);
    if (oCreatePC) oCreatePC(self,_cmd);
}

static void hSetLocalSDP(id self,SEL _cmd,id sdpObj) {
    NSString *sdp = SafeDesc(sdpObj);
    NSDictionary *sum = SDPSummary(sdp);
    Event(@"v20_setLocalSDP", sum);
    StateSet(@"local_sdp_summary", sum);
    if (oSetLocalSDP) oSetLocalSDP(self,_cmd,sdpObj);
}

static void hSetRemoteSDP(id self,SEL _cmd,id sdpObj) {
    NSString *sdp = SafeDesc(sdpObj);
    NSDictionary *sum = SDPSummary(sdp);
    Event(@"v20_setRemoteSDP", sum);
    StateSet(@"remote_sdp_summary", sum);
    if (oSetRemoteSDP) oSetRemoteSDP(self,_cmd,sdpObj);
}

static void hPrepareStart(id self,SEL _cmd,id arg) {
    Event(@"v20_prepareStartPlay", @{@"arg_class":arg?NSStringFromClass([arg class]):@""});
    if (oPrepareStart) oPrepareStart(self,_cmd,arg);
}
static id hPlaySignaling(id self,SEL _cmd) {
    Event(@"v20_playSignalingRequest", @{});
    StateSet(@"signaling_started", @YES);
    return oPlaySignaling ? oPlaySignaling(self,_cmd) : nil;
}
static id hPlayReqDNS(id self,SEL _cmd,id arg) {
    NSMutableDictionary *d=[NSMutableDictionary dictionary];
    d[@"arg_class"] = arg?NSStringFromClass([arg class]):@"";
    @try {
        if ([arg respondsToSelector:NSSelectorFromString(@"hostIp")]) {
            id v = ((id(*)(id,SEL))objc_msgSend)(arg, NSSelectorFromString(@"hostIp"));
            if (v) d[@"host_ip"] = SafeDesc(v);
        }
        if ([arg respondsToSelector:NSSelectorFromString(@"port")]) {
            NSInteger p = ((NSInteger(*)(id,SEL))objc_msgSend)(arg, NSSelectorFromString(@"port"));
            d[@"port"] = @(p);
        }
    } @catch (...) {}
    Event(@"v20_playRequestWithDnsResult", d);
    return oPlayReqDNS ? oPlayReqDNS(self,_cmd,arg) : nil;
}
static id hSendSignalDNS(id self,SEL _cmd,id arg,BOOL stop) {
    Event(@"v20_sendSignalingWithDnsResult", @{@"isStop":@(stop), @"arg_class":arg?NSStringFromClass([arg class]):@""});
    return oSendSignalDNS ? oSendSignalDNS(self,_cmd,arg,stop) : nil;
}
static int hStartPlay(id self,SEL _cmd,id url,id opts) {
    URLHit(@"HWLLSClientProxy startPlay",url);
    Event(@"v20_startPlay", @{@"options_class":opts?NSStringFromClass([opts class]):@""});
    StateSet(@"start_ts_ms", @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)));
    return oStartPlay ? oStartPlay(self,_cmd,url,opts) : 0;
}

/* HWLLSManager */
typedef void (*VoidIntT)(id,SEL,int);
static VoidObjT oSetSigHost, oSetDomain, oSetTargetDomain;
static VoidIntT oSetSigPort, oSetSigType;

static void hSetSigHost(id self,SEL _cmd,id v) {
    NSString *s=SafeDesc(v); Event(@"v20_setSignalingHost",@{@"value":s}); StateSet(@"signaling_host",s);
    if(oSetSigHost)oSetSigHost(self,_cmd,v);
}
static void hSetDomain(id self,SEL _cmd,id v) {
    NSString *s=SafeDesc(v); Event(@"v20_setDomain",@{@"value":s}); StateSet(@"domain",s);
    if(oSetDomain)oSetDomain(self,_cmd,v);
}
static void hSetTargetDomain(id self,SEL _cmd,id v) {
    NSString *s=SafeDesc(v); Event(@"v20_setTargetDomain",@{@"value":s}); StateSet(@"target_domain",s);
    if(oSetTargetDomain)oSetTargetDomain(self,_cmd,v);
}
static void hSetSigPort(id self,SEL _cmd,int v) {
    Event(@"v20_setSignalingPort",@{@"port":@(v)}); StateSet(@"signaling_port",@(v));
    if(oSetSigPort)oSetSigPort(self,_cmd,v);
}
static void hSetSigType(id self,SEL _cmd,int v) {
    Event(@"v20_setSignalingType",@{@"type":@(v)}); StateSet(@"signaling_type",@(v));
    if(oSetSigType)oSetSigType(self,_cmd,v);
}

__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        gQ = dispatch_queue_create("paidpreview.v3_4", DISPATCH_QUEUE_SERIAL);
        gLogPath = DocPath(@"PaidPreviewV3_4_V20DiagnosticExporter.log");
        gJsonPath = DocPath(@"preview_v3_4_v20_diagnostic.json");
        [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:nil attributes:nil];
        gEvents = [NSMutableArray array];
        gState = [NSMutableDictionary dictionary];

        Event(@"startup", @{@"log":gLogPath, @"json":gJsonPath});

        Class ijk = objc_getClass("IJKFFMoviePlayerController");
        Hook(ijk, sel_registerName("initWithContentURL:withOptions:"), (IMP)hIJKURL, (IMP *)&oIJKURL);
        Hook(ijk, sel_registerName("initWithContentURLString:withOptions:"), (IMP)hIJKStr, (IMP *)&oIJKStr);

        Class hlll = objc_getClass("HLLLManager");
        Hook(hlll, sel_registerName("playStream:"), (IMP)hPlayStream, (IMP *)&oPlayStream);
        Hook(hlll, sel_registerName("setCurrentUrl:"), (IMP)hSetCurrentUrl, (IMP *)&oSetCurrentUrl);
        Hook(hlll, sel_registerName("initClient"), (IMP)hInitClient, (IMP *)&oInitClient);
        Hook(hlll, sel_registerName("stop"), (IMP)hStop, (IMP *)&oStop);

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
