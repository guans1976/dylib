
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static dispatch_queue_t gQ;
static NSString *gLogPath;
static NSString *gJsonPath;
static NSMutableArray *gEvents;
static NSMutableDictionary<NSNumber*, NSMutableData*> *gTaskData;

static NSString *DocPath(NSString *name) {
    NSArray *a = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *base = a.firstObject ?: NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:name];
}

static void Console(NSString *s) {
    fprintf(stderr, "[V3.5] %s\n", (s ?: @"").UTF8String);
    NSLog(@"[V3.5] %@", s ?: @"");
}

static BOOL SensitiveKey(NSString *k) {
    NSString *l = k.lowercaseString;
    NSArray *bad = @[@"token",@"secret",@"signature",@"sign",@"authorization",@"cookie",
                     @"password",@"passwd",@"pwd",@"credential",@"privatekey",@"apikey",
                     @"accesskey",@"usersig",@"user_sig",@"txsecret",@"txtime",
                     @"sessionid",@"session_id",@"deviceid",@"device_id",
                     @"phone",@"mobile",@"email"];
    for (NSString *x in bad) if ([l containsString:x]) return YES;
    return NO;
}

static id Sanitize(id obj) {
    if (!obj || obj == [NSNull null]) return obj ?: [NSNull null];
    if ([obj isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
            NSString *ks = [key description] ?: @"";
            if (SensitiveKey(ks)) m[ks] = @"<redacted>";
            else m[ks] = Sanitize(val);
        }];
        return m;
    }
    if ([obj isKindOfClass:NSArray.class]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id x in (NSArray *)obj) [a addObject:Sanitize(x) ?: [NSNull null]];
        return a;
    }
    if ([obj isKindOfClass:NSString.class]) {
        NSString *s = obj;
        if ([s length] > 8192) return [s substringToIndex:8192];
        return s;
    }
    return obj;
}

static NSDictionary *SanitizedHeaders(NSDictionary *h) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    [h enumerateKeysAndObjectsUsingBlock:^(id key,id val,BOOL *stop){
        NSString *ks=[key description]?:@"";
        if (SensitiveKey(ks)) m[ks]=@"<redacted>";
        else m[ks]=[val description]?:@"";
    }];
    return m;
}

static id ParseBody(NSData *data) {
    if (!data.length) return [NSNull null];
    id j = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (j) return Sanitize(j);
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) return [NSString stringWithFormat:@"<binary %lu bytes>",(unsigned long)data.length];
    if (s.length > 8192) s = [s substringToIndex:8192];
    return s;
}

static BOOL IsTargetRequest(NSURLRequest *r) {
    NSString *host = r.URL.host.lowercaseString ?: @"";
    return [host containsString:@"qituoc.com"];
}

static void Flush(void) {
    NSDictionary *doc=@{
        @"schema":@"paid-preview-v3.5-channel-info-trace",
        @"status":@"ready",
        @"events":gEvents ?: @[]
    };
    NSData *d=[NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToFile:gJsonPath atomically:YES];
}

static void Event(NSString *kind, NSDictionary *extra) {
    dispatch_async(gQ,^{
        NSMutableDictionary *e=[NSMutableDictionary dictionaryWithDictionary:extra ?: @{}];
        e[@"kind"]=kind ?: @"event";
        e[@"ts_ms"]=@((long long)(NSDate.date.timeIntervalSince1970*1000.0));
        [gEvents addObject:e];

        NSString *line=[NSString stringWithFormat:@"%@ %@",kind,extra ?: @{}];
        NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
        Console(line);
        Flush();
    });
}

static NSDictionary *ReqInfo(NSURLRequest *r) {
    if (!r) return @{};
    NSMutableDictionary *d=[NSMutableDictionary dictionary];
    d[@"url"]=r.URL.absoluteString ?: @"";
    d[@"method"]=r.HTTPMethod ?: @"";
    d[@"headers"]=SanitizedHeaders(r.allHTTPHeaderFields ?: @{});
    if (r.HTTPBody.length) d[@"body"]=ParseBody(r.HTTPBody);
    return d;
}

static BOOL HookMethod(Class c, SEL s, IMP repl, IMP *orig) {
    if (!c) return NO;
    Method m=class_getInstanceMethod(c,s);
    if (!m) return NO;
    if (orig) *orig=method_getImplementation(m);
    method_setImplementation(m,repl);
    Event(@"hook",@{@"class":NSStringFromClass(c),@"selector":NSStringFromSelector(s)});
    return YES;
}

/* NSURLSession completion-based requests */
typedef NSURLSessionDataTask *(*DataTaskCH)(id,SEL,NSURLRequest*,void(^)(NSData*,NSURLResponse*,NSError*));
static DataTaskCH oDataTaskCH;

static NSURLSessionDataTask *hDataTaskCH(id self,SEL _cmd,NSURLRequest *req,
                                        void(^completion)(NSData*,NSURLResponse*,NSError*)) {
    if (IsTargetRequest(req)) Event(@"request",ReqInfo(req));
    void (^wrapped)(NSData*,NSURLResponse*,NSError*) = ^(NSData *data, NSURLResponse *resp, NSError *err){
        if (IsTargetRequest(req)) {
            NSInteger status=0;
            if ([resp isKindOfClass:NSHTTPURLResponse.class]) status=((NSHTTPURLResponse*)resp).statusCode;
            Event(@"response",@{
                @"request":ReqInfo(req),
                @"status":@(status),
                @"mime":resp.MIMEType ?: @"",
                @"body":ParseBody(data ?: [NSData data]),
                @"error":err.localizedDescription ?: @""
            });
        }
        if (completion) completion(data,resp,err);
    };
    return oDataTaskCH ? oDataTaskCH(self,_cmd,req,wrapped) : nil;
}

/* Alamofire delegate path */
typedef void (*DidReceiveDataFn)(id,SEL,NSURLSession*,NSURLSessionDataTask*,NSData*);
static DidReceiveDataFn oDidReceiveData;
static void hDidReceiveData(id self,SEL _cmd,NSURLSession *session,NSURLSessionDataTask *task,NSData *data) {
    NSURLRequest *r=task.currentRequest ?: task.originalRequest;
    if (IsTargetRequest(r) && data.length) {
        NSNumber *tid=@(task.taskIdentifier);
        dispatch_sync(gQ,^{
            NSMutableData *buf=gTaskData[tid];
            if (!buf) { buf=[NSMutableData data]; gTaskData[tid]=buf; }
            if (buf.length < 2*1024*1024) {
                NSUInteger left=2*1024*1024-buf.length;
                [buf appendData:(data.length<=left?data:[data subdataWithRange:NSMakeRange(0,left)])];
            }
        });
    }
    if (oDidReceiveData) oDidReceiveData(self,_cmd,session,task,data);
}

typedef void (*DidCompleteFn)(id,SEL,NSURLSession*,NSURLSessionTask*,NSError*);
static DidCompleteFn oDidComplete;
static void hDidComplete(id self,SEL _cmd,NSURLSession *session,NSURLSessionTask *task,NSError *err) {
    NSURLRequest *r=task.currentRequest ?: task.originalRequest;
    if (IsTargetRequest(r)) {
        __block NSData *body=nil;
        NSNumber *tid=@(task.taskIdentifier);
        dispatch_sync(gQ,^{
            body=[gTaskData[tid] copy];
            [gTaskData removeObjectForKey:tid];
        });
        NSInteger status=0;
        if ([task.response isKindOfClass:NSHTTPURLResponse.class]) status=((NSHTTPURLResponse*)task.response).statusCode;
        Event(@"response_delegate",@{
            @"request":ReqInfo(r),
            @"status":@(status),
            @"mime":task.response.MIMEType ?: @"",
            @"body":ParseBody(body ?: [NSData data]),
            @"error":err.localizedDescription ?: @""
        });
    }
    if (oDidComplete) oDidComplete(self,_cmd,session,task,err);
}

__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        gQ=dispatch_queue_create("paidpreview.v3_5",DISPATCH_QUEUE_SERIAL);
        gEvents=[NSMutableArray array];
        gTaskData=[NSMutableDictionary dictionary];
        gLogPath=DocPath(@"PaidPreviewV3_5_ChannelInfoTrace.log");
        gJsonPath=DocPath(@"preview_v3_5_channel_info.json");
        [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:nil attributes:nil];

        Event(@"startup",@{@"log":gLogPath,@"json":gJsonPath});

        HookMethod(objc_getClass("NSURLSession"),
                   sel_registerName("dataTaskWithRequest:completionHandler:"),
                   (IMP)hDataTaskCH,(IMP*)&oDataTaskCH);

        NSArray *names=@[@"Alamofire.SessionDelegate",@"Alamofire.SessionDelegateImpl"];
        for (NSString *n in names) {
            Class c=NSClassFromString(n);
            if (!c) continue;
            HookMethod(c,sel_registerName("URLSession:dataTask:didReceiveData:"),
                       (IMP)hDidReceiveData,(IMP*)&oDidReceiveData);
            HookMethod(c,sel_registerName("URLSession:task:didCompleteWithError:"),
                       (IMP)hDidComplete,(IMP*)&oDidComplete);
        }

        Event(@"ready",@{});
    }
}
