#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>

static dispatch_queue_t gQ;
static NSString *gLogPath,*gJsonPath;
static NSMutableArray *gEvents;
static NSMutableDictionary<NSNumber*,NSMutableData*> *gTaskData;

static IMP gOrigDataTaskCH;
static IMP gOrigDidReceive;
static IMP gOrigDidComplete;
static IMP gOrigJSONObjectWithData;
static IMP gOrigSend;
static IMP gOrigStartPlay;

static volatile long long gLastLimitResponseMs=0;
static volatile long long gLastLimitDecodeMs=0;

static NSString *DocPath(NSString *name) {
    NSString *base=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    return [(base ?: NSTemporaryDirectory()) stringByAppendingPathComponent:name];
}
static long long NowMs(void){ return (long long)(NSDate.date.timeIntervalSince1970*1000.0); }

static BOOL SensitiveName(NSString *name) {
    NSString *l=name.lowercaseString ?: @"";
    NSArray *bad=@[@"authorization",@"cookie",@"token",@"secret",@"signature",@"sign",
                   @"password",@"passwd",@"pwd",@"credential",@"session",
                   @"apikey",@"accesskey",@"privatekey",@"txsecret",@"txtime",
                   @"x-live-butter",@"knockknock",@"deviceid",@"device_id",
                   @"ice-pwd",@"fingerprint",@"usersig",@"user_sig"];
    for(NSString *x in bad) if([l containsString:x]) return YES;
    return NO;
}

static NSString *RedactedURLString(NSString *s) {
    if(!s.length) return @"";
    NSURLComponents *c=[NSURLComponents componentsWithString:s];
    if(!c) return s;
    if(c.query.length) c.query=@"<redacted>";
    return c.string ?: s;
}

static NSArray *ShortStack(void) {
    NSArray *a=NSThread.callStackSymbols ?: @[];
    NSUInteger n=MIN((NSUInteger)14,a.count);
    return [a subarrayWithRange:NSMakeRange(0,n)];
}

static NSDictionary *QueryShape(NSURL *url) {
    NSURLComponents *c=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableDictionary *shape=[NSMutableDictionary dictionary];
    for(NSURLQueryItem *item in c.queryItems ?: @[]) {
        NSString *k=item.name ?: @"";
        if(!k.length) continue;
        NSString *v=item.value ?: @"";
        if(SensitiveName(k)) {
            shape[k]=@"<redacted>";
        } else {
            // Keep non-sensitive identifiers only as type/length, not reusable values.
            BOOL numeric=([v rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location==NSNotFound);
            shape[k]=@{@"present":@YES,
                       @"length":@(v.length),
                       @"numeric":@(numeric)};
        }
    }
    return shape;
}

static NSDictionary *HeaderShape(NSDictionary *h) {
    NSMutableDictionary *m=[NSMutableDictionary dictionary];
    [h enumerateKeysAndObjectsUsingBlock:^(id key,id val,BOOL *stop){
        NSString *k=[key description] ?: @"";
        if(SensitiveName(k)) {
            m[k]=@"<redacted>";
        } else {
            NSString *v=[val description] ?: @"";
            m[k]=@{@"present":@YES,@"length":@(v.length)};
        }
    }];
    return m;
}

static NSArray *SortedKeys(NSDictionary *d) {
    NSArray *keys=[d.allKeys valueForKey:@"description"];
    return [keys sortedArrayUsingSelector:@selector(compare:)];
}

static id SummarizeJSON(id obj);

static id SummarizeString(NSString *s) {
    if(!s) return @"";
    NSString *l=s.lowercaseString;
    if([l hasPrefix:@"webrtc://"]||[l hasPrefix:@"rtmp://"]||[l hasPrefix:@"http://"]||[l hasPrefix:@"https://"]) {
        return @{@"type":@"url",@"value":RedactedURLString(s)};
    }
    return @{@"type":@"string",@"length":@(s.length)};
}

static id SummarizeJSON(id obj) {
    if(!obj || obj==NSNull.null) return NSNull.null;
    if([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *d=obj;
        NSMutableDictionary *out=[NSMutableDictionary dictionary];
        out[@"_keys"]=SortedKeys(d);
        if(d[@"stream"]) out[@"stream"]=SummarizeJSON(d[@"stream"]);
        for(NSString *k in @[@"code",@"status",@"msg",@"message",@"preview_time",@"prerequisite",@"plid",@"ptid",@"sid",@"bsid",@"id"]) {
            id v=d[k];
            if(!v) continue;
            if([v isKindOfClass:NSString.class]) out[k]=SummarizeString(v);
            else if([v isKindOfClass:NSNumber.class] || v==NSNull.null) out[k]=v;
        }
        for(NSString *k in @[@"pull_url",@"flv_pull_url",@"lll_pull_url",@"replace_url",@"stream_url",@"play_url"]) {
            id v=d[k];
            if([v isKindOfClass:NSString.class]) out[k]=SummarizeString(v);
        }
        return out;
    }
    if([obj isKindOfClass:NSArray.class]) {
        NSArray *a=obj;
        return @{@"_type":@"array",@"count":@(a.count)};
    }
    if([obj isKindOfClass:NSString.class]) return SummarizeString(obj);
    if([obj isKindOfClass:NSNumber.class]) return obj;
    return @{@"_type":NSStringFromClass([obj class]) ?: @"object"};
}

static id ParseBodySummary(NSData *data) {
    if(!data.length) return @{@"type":@"empty",@"bytes":@0};
    id j=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(j) return @{@"type":@"json",@"bytes":@(data.length),@"summary":SummarizeJSON(j)};
    NSString *s=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return @{@"type":s?@"opaque_text":@"binary",
             @"bytes":@(data.length),
             @"length":@(s.length)};
}

static void Flush(void) {
    NSDictionary *doc=@{@"schema":@"v16.4-get-private-limit-flow",
                        @"status":@"ready",
                        @"events":gEvents ?: @[]};
    NSData *d=[NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToFile:gJsonPath atomically:YES];
}

static void Event(NSString *kind,NSDictionary *extra) {
    dispatch_async(gQ,^{
        NSMutableDictionary *e=[NSMutableDictionary dictionaryWithDictionary:extra ?: @{}];
        e[@"kind"]=kind ?: @"event";
        e[@"ts_ms"]=@(NowMs());
        [gEvents addObject:e];

        NSString *line=[NSString stringWithFormat:@"%@ %@",kind ?: @"event",extra ?: @{}];
        NSData *data=[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if(h){[h seekToEndOfFile];[h writeData:data];[h closeFile];}
        else [data writeToFile:gLogPath atomically:YES];
        Flush();
    });
}

static BOOL IsLimitRequest(NSURLRequest *r) {
    NSString *host=r.URL.host.lowercaseString ?: @"";
    NSString *path=r.URL.path.lowercaseString ?: @"";
    return [host containsString:@"qituoc.com"] && [path containsString:@"/private/getprivatelimit"];
}

static NSDictionary *RequestShape(NSURLRequest *r) {
    if(!r) return @{};
    return @{@"method":r.HTTPMethod ?: @"",
             @"host":r.URL.host ?: @"",
             @"path":r.URL.path ?: @"",
             @"query_shape":QueryShape(r.URL),
             @"headers_shape":HeaderShape(r.allHTTPHeaderFields ?: @{}),
             @"body_bytes":@(r.HTTPBody.length)};
}

typedef NSURLSessionDataTask *(*DataTaskCH)(id,SEL,NSURLRequest*,void(^)(NSData*,NSURLResponse*,NSError*));
static NSURLSessionDataTask *HookDataTaskCH(id self,SEL _cmd,NSURLRequest *req,void(^completion)(NSData*,NSURLResponse*,NSError*)) {
    if(IsLimitRequest(req)) Event(@"limit_request",RequestShape(req));
    void (^wrapped)(NSData*,NSURLResponse*,NSError*)=^(NSData *data,NSURLResponse *resp,NSError *err){
        if(IsLimitRequest(req)) {
            gLastLimitResponseMs=NowMs();
            NSInteger status=0;
            if([resp isKindOfClass:NSHTTPURLResponse.class]) status=((NSHTTPURLResponse*)resp).statusCode;
            Event(@"limit_response",@{@"request":RequestShape(req),
                                      @"status":@(status),
                                      @"mime":resp.MIMEType ?: @"",
                                      @"body":ParseBodySummary(data ?: [NSData data]),
                                      @"stack":ShortStack(),
                                      @"error":err.localizedDescription ?: @""});
        }
        if(completion) completion(data,resp,err);
    };
    return gOrigDataTaskCH?((DataTaskCH)gOrigDataTaskCH)(self,_cmd,req,wrapped):nil;
}

typedef void (*DidReceiveFn)(id,SEL,NSURLSession*,NSURLSessionDataTask*,NSData*);
static void HookDidReceive(id self,SEL _cmd,NSURLSession *session,NSURLSessionDataTask *task,NSData *data) {
    NSURLRequest *r=task.currentRequest ?: task.originalRequest;
    if(IsLimitRequest(r)&&data.length) {
        NSNumber *tid=@(task.taskIdentifier);
        dispatch_sync(gQ,^{
            NSMutableData *buf=gTaskData[tid];
            if(!buf){buf=[NSMutableData data];gTaskData[tid]=buf;}
            if(buf.length<1024*1024){
                NSUInteger left=1024*1024-buf.length;
                [buf appendData:data.length<=left?data:[data subdataWithRange:NSMakeRange(0,left)]];
            }
        });
    }
    if(gOrigDidReceive) ((DidReceiveFn)gOrigDidReceive)(self,_cmd,session,task,data);
}

typedef void (*DidCompleteFn)(id,SEL,NSURLSession*,NSURLSessionTask*,NSError*);
static void HookDidComplete(id self,SEL _cmd,NSURLSession *session,NSURLSessionTask *task,NSError *err) {
    NSURLRequest *r=task.currentRequest ?: task.originalRequest;
    if(IsLimitRequest(r)) {
        __block NSData *body=nil;
        NSNumber *tid=@(task.taskIdentifier);
        dispatch_sync(gQ,^{body=[gTaskData[tid] copy];[gTaskData removeObjectForKey:tid];});
        gLastLimitResponseMs=NowMs();
        NSInteger status=0;
        if([task.response isKindOfClass:NSHTTPURLResponse.class]) status=((NSHTTPURLResponse*)task.response).statusCode;
        Event(@"limit_response_delegate",@{@"request":RequestShape(r),
                                           @"status":@(status),
                                           @"mime":task.response.MIMEType ?: @"",
                                           @"body":ParseBodySummary(body ?: [NSData data]),
                                           @"stack":ShortStack(),
                                           @"error":err.localizedDescription ?: @""});
    }
    if(gOrigDidComplete) ((DidCompleteFn)gOrigDidComplete)(self,_cmd,session,task,err);
}

/* Observe app-side JSON decode within 3s after getPrivateLimit response. */
typedef id (*JSONObjectWithDataFn)(id,SEL,NSData*,NSJSONReadingOptions,NSError**);
static id HookJSONObjectWithData(id cls,SEL _cmd,NSData *data,NSJSONReadingOptions options,NSError **error) {
    id obj=((JSONObjectWithDataFn)gOrigJSONObjectWithData)(cls,_cmd,data,options,error);
    long long delta=NowMs()-gLastLimitResponseMs;
    if(obj && gLastLimitResponseMs && delta>=0 && delta<=3000) {
        id sum=SummarizeJSON(obj);
        BOOL interesting=NO;
        if([sum isKindOfClass:NSDictionary.class]) {
            NSDictionary *d=sum;
            interesting=(d[@"stream"]!=nil || [d[@"_keys"] containsObject:@"stream"]);
        }
        if(interesting) {
            gLastLimitDecodeMs=NowMs();
            Event(@"limit_decoded_stream_object",@{@"delta_ms":@(delta),
                                                    @"bytes":@(data.length),
                                                    @"class":NSStringFromClass([obj class]) ?: @"",
                                                    @"summary":sum ?: @{},
                                                    @"stack":ShortStack()});
        } else {
            Event(@"json_decode_near_limit",@{@"delta_ms":@(delta),
                                              @"bytes":@(data.length),
                                              @"class":NSStringFromClass([obj class]) ?: @"",
                                              @"summary":sum ?: @{},
                                              @"stack":ShortStack()});
        }
    }
    return obj;
}

/* Final HWLLS signaling handoff */
static char Type(const char *s){if(!s)return 0;while(*s&&strchr("rnNoORV",*s))s++;return *s;}
static NSString *StringGetter(id object,NSString *name) {
    if(!object)return @"";
    SEL sel=NSSelectorFromString(name);
    Method m=class_getInstanceMethod(object_getClass(object),sel);
    if(!m||method_getNumberOfArguments(m)!=2)return @"";
    char *t=method_copyReturnType(m); BOOL ok=Type(t)=='@'; free(t); if(!ok)return @"";
    id v=((id(*)(id,SEL))objc_msgSend)(object,sel);
    return [v isKindOfClass:NSString.class]?v:@"";
}
static id HookSend(id self,SEL _cmd,id param) {
    NSString *stream=StringGetter(param,@"streamUrl");
    long long now=NowMs();
    Event(@"rtc_handoff",@{@"stream_url":RedactedURLString(stream),
                           @"stream_present":@(stream.length>0),
                           @"domain":StringGetter(param,@"domain") ?: @"",
                           @"host_ip":StringGetter(param,@"hostIp") ?: @"",
                           @"delta_limit_response_ms":@(gLastLimitResponseMs?now-gLastLimitResponseMs:-1),
                           @"delta_limit_decode_ms":@(gLastLimitDecodeMs?now-gLastLimitDecodeMs:-1),
                           @"stack":ShortStack()});
    return gOrigSend?((id(*)(id,SEL,id))gOrigSend)(self,_cmd,param):nil;
}

/* Trace HWLLSClientProxy startPlay without exposing option internals. */
typedef void (*StartPlayFn)(id,SEL,id,id);
static void HookStartPlay(id self,SEL _cmd,id arg1,id arg2) {
    long long now=NowMs();
    Event(@"hwlls_start_play",@{@"arg1_class":arg1?NSStringFromClass([arg1 class]):@"",
                                @"arg2_class":arg2?NSStringFromClass([arg2 class]):@"",
                                @"delta_limit_response_ms":@(gLastLimitResponseMs?now-gLastLimitResponseMs:-1),
                                @"delta_limit_decode_ms":@(gLastLimitDecodeMs?now-gLastLimitDecodeMs:-1),
                                @"stack":ShortStack()});
    if(gOrigStartPlay) ((StartPlayFn)gOrigStartPlay)(self,_cmd,arg1,arg2);
}

static BOOL HookInstance(Class c,SEL s,IMP repl,IMP *orig) {
    if(!c)return NO;
    Method m=class_getInstanceMethod(c,s);
    if(!m)return NO;
    if(orig)*orig=method_getImplementation(m);
    method_setImplementation(m,repl);
    Event(@"hook",@{@"class":NSStringFromClass(c),@"selector":NSStringFromSelector(s)});
    return YES;
}

static BOOL HookClassMethod(Class c,SEL s,IMP repl,IMP *orig) {
    if(!c)return NO;
    Class meta=object_getClass(c);
    Method m=class_getInstanceMethod(meta,s);
    if(!m)return NO;
    if(orig)*orig=method_getImplementation(m);
    method_setImplementation(m,repl);
    Event(@"hook",@{@"class":[@"+" stringByAppendingString:NSStringFromClass(c)],
                    @"selector":NSStringFromSelector(s)});
    return YES;
}

static void InstallLateHooks(unsigned attempt) {
    Class rtc=objc_getClass("RTCSignalingSender");
    if(rtc && !gOrigSend)
        HookClassMethod(rtc,NSSelectorFromString(@"sendSignaling:"),(IMP)HookSend,&gOrigSend);

    Class hw=objc_getClass("HWLLSClientProxy");
    if(hw && !gOrigStartPlay) {
        SEL sel=NSSelectorFromString(@"startPlay:startPlayOptions:");
        Method m=class_getInstanceMethod(hw,sel);
        if(m) {
            gOrigStartPlay=method_getImplementation(m);
            method_setImplementation(m,(IMP)HookStartPlay);
            Event(@"hook",@{@"class":@"HWLLSClientProxy",@"selector":@"startPlay:startPlayOptions:"});
        }
    }

    if((!gOrigSend || !gOrigStartPlay) && attempt<30) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{InstallLateHooks(attempt+1);});
    }
}

__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        gQ=dispatch_queue_create("v16.4.limit.flow",DISPATCH_QUEUE_SERIAL);
        gEvents=[NSMutableArray array];
        gTaskData=[NSMutableDictionary dictionary];
        gLogPath=DocPath(@"V16_4_GetPrivateLimitFlowTrace.log");
        gJsonPath=DocPath(@"v16_4_get_private_limit_flow.json");
        [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:nil attributes:nil];

        Event(@"startup",@{@"log":gLogPath,@"json":gJsonPath});

        HookInstance(objc_getClass("NSURLSession"),
                     sel_registerName("dataTaskWithRequest:completionHandler:"),
                     (IMP)HookDataTaskCH,&gOrigDataTaskCH);

        for(NSString *name in @[@"Alamofire.SessionDelegate",@"Alamofire.SessionDelegateImpl"]) {
            Class c=NSClassFromString(name);
            if(!c)continue;
            HookInstance(c,sel_registerName("URLSession:dataTask:didReceiveData:"),
                         (IMP)HookDidReceive,&gOrigDidReceive);
            HookInstance(c,sel_registerName("URLSession:task:didCompleteWithError:"),
                         (IMP)HookDidComplete,&gOrigDidComplete);
        }

        HookClassMethod(NSJSONSerialization.class,
                        @selector(JSONObjectWithData:options:error:),
                        (IMP)HookJSONObjectWithData,&gOrigJSONObjectWithData);

        dispatch_async(dispatch_get_main_queue(),^{InstallLateHooks(0);});
        Event(@"ready",@{@"target":@"/OpenAPI/v1/private/getPrivateLimit"});
    }
}
