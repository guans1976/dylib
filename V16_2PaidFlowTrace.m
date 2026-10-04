#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>

static dispatch_queue_t gQ;
static NSString *gLogPath,*gJsonPath;
static NSMutableArray *gEvents;
static NSMutableDictionary<NSNumber*,NSMutableData*> *gTaskData;

static IMP gOrigSend;
static IMP gOrigDataTaskCH;
static IMP gOrigDidReceive;
static IMP gOrigDidComplete;

static BOOL gRTCInstalled=NO;

static NSString *DocPath(NSString *name) {
    NSString *base=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    return [(base ?: NSTemporaryDirectory()) stringByAppendingPathComponent:name];
}

static long long NowMs(void) {
    return (long long)(NSDate.date.timeIntervalSince1970*1000.0);
}

static BOOL SensitiveName(NSString *name) {
    NSString *l=name.lowercaseString ?: @"";
    NSArray *bad=@[@"authorization",@"cookie",@"token",@"secret",@"signature",@"sign",
                   @"password",@"passwd",@"pwd",@"credential",@"session",
                   @"apikey",@"accesskey",@"privatekey",@"txsecret",@"txtime",
                   @"x-live-butter",@"knockknock",@"deviceid",@"device_id"];
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

static NSDictionary *SanitizedHeaders(NSDictionary *h) {
    NSMutableDictionary *m=[NSMutableDictionary dictionary];
    [h enumerateKeysAndObjectsUsingBlock:^(id key,id val,BOOL *stop){
        NSString *k=[key description] ?: @"";
        m[k]=SensitiveName(k)?@"<redacted>":([val description] ?: @"");
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
    if([l hasPrefix:@"webrtc://"] || [l hasPrefix:@"http://"] || [l hasPrefix:@"https://"]) {
        return @{@"type":@"url",@"value":RedactedURLString(s)};
    }
    if(s.length>256) {
        return @{@"type":@"string",@"length":@(s.length),@"prefix":[s substringToIndex:MIN((NSUInteger)80,s.length)]};
    }
    return s;
}

static id SummarizeJSON(id obj) {
    if(!obj || obj==NSNull.null) return NSNull.null;
    if([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *d=obj;
        NSMutableDictionary *out=[NSMutableDictionary dictionary];
        out[@"_keys"]=SortedKeys(d);
        NSMutableDictionary *picked=[NSMutableDictionary dictionary];
        NSArray *allow=@[@"code",@"status",@"msg",@"message",@"success",@"private",@"preview_time",
                         @"prerequisite",@"plid",@"ptid",@"sid",@"bsid",@"room_id",@"roomid",
                         @"uid",@"aid",@"id",@"stream",@"streamurl",@"stream_url",@"url",@"play_url"];
        for(NSString *k in allow) {
            id v=d[k];
            if(!v) continue;
            if(SensitiveName(k)) { picked[k]=@"<redacted>"; continue; }
            if([v isKindOfClass:NSString.class]) picked[k]=SummarizeString(v);
            else if([v isKindOfClass:NSNumber.class] || v==NSNull.null) picked[k]=v;
            else picked[k]=SummarizeJSON(v);
        }
        if(picked.count) out[@"picked"]=picked;
        return out;
    }
    if([obj isKindOfClass:NSArray.class]) {
        NSArray *a=obj;
        NSMutableArray *items=[NSMutableArray array];
        NSUInteger n=MIN((NSUInteger)3,a.count);
        for(NSUInteger i=0;i<n;i++) [items addObject:SummarizeJSON(a[i]) ?: NSNull.null];
        return @{@"_type":@"array",@"count":@(a.count),@"sample":items};
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
    if(!s) return @{@"type":@"binary",@"bytes":@(data.length)};
    NSString *trim=[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL looksURL=[trim hasPrefix:@"http://"]||[trim hasPrefix:@"https://"]||[trim hasPrefix:@"webrtc://"];
    if(looksURL) return @{@"type":@"text_url",@"bytes":@(data.length),@"value":RedactedURLString(trim)};
    return @{@"type":@"opaque_text",
             @"bytes":@(data.length),
             @"length":@(trim.length),
             @"prefix": trim.length?[trim substringToIndex:MIN((NSUInteger)80,trim.length)]:@""};
}

static void Flush(void) {
    NSDictionary *doc=@{@"schema":@"v16.2-paid-flow-trace",
                        @"status":@"ready",
                        @"events":gEvents ?: @[]};
    NSData *d=[NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToFile:gJsonPath atomically:YES];
}

static void Event(NSString *kind, NSDictionary *extra) {
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

static BOOL TargetRequest(NSURLRequest *r) {
    NSString *host=r.URL.host.lowercaseString ?: @"";
    if(![host containsString:@"qituoc.com"]) return NO;
    NSString *p=r.URL.path.lowercaseString ?: @"";
    NSArray *targets=@[@"private",@"room",@"live",@"anchor",@"play",@"stream",@"preview"];
    for(NSString *x in targets) if([p containsString:x]) return YES;
    return NO;
}

static NSDictionary *ReqSummary(NSURLRequest *r) {
    if(!r) return @{};
    return @{@"method":r.HTTPMethod ?: @"",
             @"host":r.URL.host ?: @"",
             @"path":r.URL.path ?: @"",
             @"query_present":@(r.URL.query.length>0),
             @"headers":SanitizedHeaders(r.allHTTPHeaderFields ?: @{}),
             @"body":ParseBodySummary(r.HTTPBody ?: [NSData data])};
}

/* NSURLSession completion path */
typedef NSURLSessionDataTask *(*DataTaskCH)(id,SEL,NSURLRequest*,void(^)(NSData*,NSURLResponse*,NSError*));

static NSURLSessionDataTask *HookDataTaskCH(id self,SEL _cmd,NSURLRequest *req,
                                            void(^completion)(NSData*,NSURLResponse*,NSError*)) {
    if(TargetRequest(req)) Event(@"http_request",ReqSummary(req));
    void (^wrapped)(NSData*,NSURLResponse*,NSError*)=^(NSData *data,NSURLResponse *resp,NSError *err){
        if(TargetRequest(req)) {
            NSInteger status=0;
            if([resp isKindOfClass:NSHTTPURLResponse.class]) status=((NSHTTPURLResponse*)resp).statusCode;
            Event(@"http_response",@{@"request":ReqSummary(req),
                                     @"status":@(status),
                                     @"mime":resp.MIMEType ?: @"",
                                     @"body":ParseBodySummary(data ?: [NSData data]),
                                     @"error":err.localizedDescription ?: @""});
        }
        if(completion) completion(data,resp,err);
    };
    return gOrigDataTaskCH?((DataTaskCH)gOrigDataTaskCH)(self,_cmd,req,wrapped):nil;
}

/* Alamofire delegate path */
typedef void (*DidReceiveFn)(id,SEL,NSURLSession*,NSURLSessionDataTask*,NSData*);
static void HookDidReceive(id self,SEL _cmd,NSURLSession *session,NSURLSessionDataTask *task,NSData *data) {
    NSURLRequest *r=task.currentRequest ?: task.originalRequest;
    if(TargetRequest(r) && data.length) {
        NSNumber *tid=@(task.taskIdentifier);
        dispatch_sync(gQ,^{
            NSMutableData *buf=gTaskData[tid];
            if(!buf){buf=[NSMutableData data];gTaskData[tid]=buf;}
            if(buf.length<1024*1024) {
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
    if(TargetRequest(r)) {
        __block NSData *body=nil;
        NSNumber *tid=@(task.taskIdentifier);
        dispatch_sync(gQ,^{
            body=[gTaskData[tid] copy];
            [gTaskData removeObjectForKey:tid];
        });
        NSInteger status=0;
        if([task.response isKindOfClass:NSHTTPURLResponse.class]) status=((NSHTTPURLResponse*)task.response).statusCode;
        Event(@"http_response_delegate",@{@"request":ReqSummary(r),
                                          @"status":@(status),
                                          @"mime":task.response.MIMEType ?: @"",
                                          @"body":ParseBodySummary(body ?: [NSData data]),
                                          @"error":err.localizedDescription ?: @""});
    }
    if(gOrigDidComplete) ((DidCompleteFn)gOrigDidComplete)(self,_cmd,session,task,err);
}

/* Final RTC handoff */
static char Type(const char *s){if(!s)return 0;while(*s&&strchr("rnNoORV",*s))s++;return *s;}

static NSString *StringGetter(id object,NSString *name) {
    if(!object) return @"";
    SEL sel=NSSelectorFromString(name);
    Method m=class_getInstanceMethod(object_getClass(object),sel);
    if(!m || method_getNumberOfArguments(m)!=2) return @"";
    char *t=method_copyReturnType(m);
    BOOL ok=Type(t)=='@';
    free(t);
    if(!ok) return @"";
    id v=((id(*)(id,SEL))objc_msgSend)(object,sel);
    return [v isKindOfClass:NSString.class]?v:@"";
}

static id HookSend(id self,SEL _cmd,id param) {
    NSString *stream=StringGetter(param,@"streamUrl");
    NSString *domain=StringGetter(param,@"domain");
    NSString *host=StringGetter(param,@"hostIp");
    Event(@"rtc_handoff",@{@"stream_url":RedactedURLString(stream),
                           @"stream_present":@(stream.length>0),
                           @"domain":domain ?: @"",
                           @"host_ip":host ?: @""});
    return gOrigSend?((id(*)(id,SEL,id))gOrigSend)(self,_cmd,param):nil;
}

static BOOL HookInstance(Class c,SEL s,IMP repl,IMP *orig) {
    if(!c) return NO;
    Method m=class_getInstanceMethod(c,s);
    if(!m) return NO;
    if(orig) *orig=method_getImplementation(m);
    method_setImplementation(m,repl);
    Event(@"hook",@{@"class":NSStringFromClass(c),@"selector":NSStringFromSelector(s)});
    return YES;
}

static void InstallRTC(unsigned attempt) {
    if(gRTCInstalled) return;
    Class c=objc_getClass("RTCSignalingSender");
    Class meta=c?object_getClass(c):Nil;
    SEL sel=NSSelectorFromString(@"sendSignaling:");
    Method m=meta?class_getInstanceMethod(meta,sel):NULL;
    if(!m) {
        if(attempt<30) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{InstallRTC(attempt+1);});
        } else Event(@"rtc_hook_missing",@{});
        return;
    }
    gOrigSend=method_getImplementation(m);
    method_setImplementation(m,(IMP)HookSend);
    gRTCInstalled=YES;
    Event(@"hook",@{@"class":@"RTCSignalingSender",@"selector":@"+sendSignaling:"});
}

__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        gQ=dispatch_queue_create("v16.2.paid.flow.trace",DISPATCH_QUEUE_SERIAL);
        gEvents=[NSMutableArray array];
        gTaskData=[NSMutableDictionary dictionary];
        gLogPath=DocPath(@"V16_2_PaidFlowTrace.log");
        gJsonPath=DocPath(@"v16_2_paid_flow_trace.json");
        [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:nil attributes:nil];

        Event(@"startup",@{@"log":gLogPath,@"json":gJsonPath});

        HookInstance(objc_getClass("NSURLSession"),
                     sel_registerName("dataTaskWithRequest:completionHandler:"),
                     (IMP)HookDataTaskCH,&gOrigDataTaskCH);

        for(NSString *name in @[@"Alamofire.SessionDelegate",@"Alamofire.SessionDelegateImpl"]) {
            Class c=NSClassFromString(name);
            if(!c) continue;
            HookInstance(c,sel_registerName("URLSession:dataTask:didReceiveData:"),
                         (IMP)HookDidReceive,&gOrigDidReceive);
            HookInstance(c,sel_registerName("URLSession:task:didCompleteWithError:"),
                         (IMP)HookDidComplete,&gOrigDidComplete);
        }

        dispatch_async(dispatch_get_main_queue(),^{InstallRTC(0);});
        Event(@"ready",@{});
    }
}
