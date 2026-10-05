#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>

static dispatch_queue_t gQ;
static NSString *gLogPath,*gJsonPath;
static NSMutableArray *gEvents;
static NSMutableDictionary<NSNumber*,NSMutableData*> *gTaskData;
static NSMutableArray *gSamples;

static IMP gOrigDidReceive;
static IMP gOrigDidComplete;
static IMP gOrigJSONObjectWithData;
static IMP gOrigSend;
static volatile long long gLastLimitResponseMs=0;
static NSString *gLastRawHash=nil;
static NSUInteger gLastRawBytes=0;

static NSString *DocPath(NSString *name){
    NSString *base=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    return [(base ?: NSTemporaryDirectory()) stringByAppendingPathComponent:name];
}
static long long NowMs(void){ return (long long)(NSDate.date.timeIntervalSince1970*1000.0); }

static NSString *SHA256(NSData *data){
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *s=[NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];
    for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [s appendFormat:@"%02x",digest[i]];
    return s;
}

static NSString *RedactedURL(NSString *s){
    if(!s.length) return @"";
    NSURLComponents *c=[NSURLComponents componentsWithString:s];
    if(!c) return s;
    if(c.query.length) c.query=@"<redacted>";
    return c.string ?: s;
}

static NSArray *ShortStack(void){
    NSArray *a=NSThread.callStackSymbols ?: @[];
    NSUInteger n=MIN((NSUInteger)12,a.count);
    return [a subarrayWithRange:NSMakeRange(0,n)];
}

static void Flush(void){
    NSDictionary *doc=@{
        @"schema":@"v16.5-decode-feasibility-probe",
        @"status":@"ready",
        @"samples":gSamples ?: @[],
        @"events":gEvents ?: @[]
    };
    NSData *d=[NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToFile:gJsonPath atomically:YES];
}

static void Event(NSString *kind,NSDictionary *extra){
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

static BOOL IsLimitRequest(NSURLRequest *r){
    NSString *host=r.URL.host.lowercaseString ?: @"";
    NSString *path=r.URL.path.lowercaseString ?: @"";
    return [host containsString:@"qituoc.com"] && [path containsString:@"/private/getprivatelimit"];
}

typedef void (*DidReceiveFn)(id,SEL,NSURLSession*,NSURLSessionDataTask*,NSData*);
static void HookDidReceive(id self,SEL _cmd,NSURLSession *session,NSURLSessionDataTask *task,NSData *data){
    NSURLRequest *r=task.currentRequest ?: task.originalRequest;
    if(IsLimitRequest(r)&&data.length){
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
static void HookDidComplete(id self,SEL _cmd,NSURLSession *session,NSURLSessionTask *task,NSError *err){
    NSURLRequest *r=task.currentRequest ?: task.originalRequest;
    if(IsLimitRequest(r)){
        __block NSData *body=nil;
        NSNumber *tid=@(task.taskIdentifier);
        dispatch_sync(gQ,^{
            body=[gTaskData[tid] copy] ?: [NSData data];
            [gTaskData removeObjectForKey:tid];
        });

        gLastLimitResponseMs=NowMs();
        gLastRawHash=SHA256(body);
        gLastRawBytes=body.length;

        Event(@"limit_raw_response",@{
            @"status":@([task.response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse*)task.response).statusCode:0),
            @"bytes":@(body.length),
            @"sha256_prefix":[gLastRawHash substringToIndex:MIN((NSUInteger)16,gLastRawHash.length)],
            @"stack":ShortStack(),
            @"error":err.localizedDescription ?: @""
        });
    }
    if(gOrigDidComplete) ((DidCompleteFn)gOrigDidComplete)(self,_cmd,session,task,err);
}

static NSDictionary *StreamSummaryFromObject(id obj){
    if(![obj isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *d=obj;
    id stream=d[@"stream"];
    if(![stream isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *s=stream;
    NSMutableDictionary *out=[NSMutableDictionary dictionary];
    for(NSString *k in @[@"flv_pull_url",@"lll_pull_url",@"pull_url",@"replace_url"]){
        id v=s[k];
        if([v isKindOfClass:NSString.class]) out[k]=RedactedURL(v);
    }
    out[@"stream_keys"]=[s.allKeys valueForKey:@"description"];
    return out;
}

typedef id (*JSONObjectWithDataFn)(id,SEL,NSData*,NSJSONReadingOptions,NSError**);
static id HookJSONObjectWithData(id cls,SEL _cmd,NSData *data,NSJSONReadingOptions options,NSError **error){
    id obj=((JSONObjectWithDataFn)gOrigJSONObjectWithData)(cls,_cmd,data,options,error);
    long long delta=NowMs()-gLastLimitResponseMs;

    if(obj && gLastLimitResponseMs && delta>=0 && delta<=3000){
        NSDictionary *stream=StreamSummaryFromObject(obj);
        if(stream){
            NSString *jsonHash=SHA256(data);
            NSMutableDictionary *sample=[@{
                @"raw_bytes":@(gLastRawBytes),
                @"raw_sha256_prefix":gLastRawHash.length?[gLastRawHash substringToIndex:MIN((NSUInteger)16,gLastRawHash.length)]:@"",
                @"decoded_bytes":@(data.length),
                @"decoded_sha256_prefix":[jsonHash substringToIndex:MIN((NSUInteger)16,jsonHash.length)],
                @"decode_delta_ms":@(delta),
                @"decoded_class":NSStringFromClass([obj class]) ?: @"",
                @"stream":stream,
                @"stack":ShortStack()
            } mutableCopy];

            dispatch_async(gQ,^{
                [gSamples addObject:sample];
                Flush();
            });

            Event(@"decoded_stream_sample",sample);
        }
    }
    return obj;
}

static char Type(const char *s){if(!s)return 0;while(*s&&strchr("rnNoORV",*s))s++;return *s;}
static NSString *StringGetter(id object,NSString *name){
    if(!object)return @"";
    SEL sel=NSSelectorFromString(name);
    Method m=class_getInstanceMethod(object_getClass(object),sel);
    if(!m||method_getNumberOfArguments(m)!=2)return @"";
    char *t=method_copyReturnType(m); BOOL ok=Type(t)=='@'; free(t); if(!ok)return @"";
    id v=((id(*)(id,SEL))objc_msgSend)(object,sel);
    return [v isKindOfClass:NSString.class]?v:@"";
}

static id HookSend(id self,SEL _cmd,id param){
    Event(@"rtc_handoff",@{
        @"stream_url":RedactedURL(StringGetter(param,@"streamUrl")),
        @"domain":StringGetter(param,@"domain") ?: @"",
        @"host_ip":StringGetter(param,@"hostIp") ?: @"",
        @"delta_limit_response_ms":@(gLastLimitResponseMs?NowMs()-gLastLimitResponseMs:-1),
        @"stack":ShortStack()
    });
    return gOrigSend?((id(*)(id,SEL,id))gOrigSend)(self,_cmd,param):nil;
}

static BOOL HookInstance(Class c,SEL s,IMP repl,IMP *orig){
    if(!c)return NO;
    Method m=class_getInstanceMethod(c,s);
    if(!m)return NO;
    if(orig)*orig=method_getImplementation(m);
    method_setImplementation(m,repl);
    Event(@"hook",@{@"class":NSStringFromClass(c),@"selector":NSStringFromSelector(s)});
    return YES;
}
static BOOL HookClassMethod(Class c,SEL s,IMP repl,IMP *orig){
    if(!c)return NO;
    Class meta=object_getClass(c);
    Method m=class_getInstanceMethod(meta,s);
    if(!m)return NO;
    if(orig)*orig=method_getImplementation(m);
    method_setImplementation(m,repl);
    Event(@"hook",@{@"class":[@"+" stringByAppendingString:NSStringFromClass(c)],@"selector":NSStringFromSelector(s)});
    return YES;
}

static void InstallRTC(unsigned attempt){
    Class rtc=objc_getClass("RTCSignalingSender");
    if(rtc && !gOrigSend) HookClassMethod(rtc,NSSelectorFromString(@"sendSignaling:"),(IMP)HookSend,&gOrigSend);
    if(!gOrigSend && attempt<30){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{InstallRTC(attempt+1);});
    }
}

__attribute__((constructor))
static void Init(void){
    @autoreleasepool{
        gQ=dispatch_queue_create("v16.5.decode.feasibility",DISPATCH_QUEUE_SERIAL);
        gEvents=[NSMutableArray array];
        gSamples=[NSMutableArray array];
        gTaskData=[NSMutableDictionary dictionary];
        gLogPath=DocPath(@"V16_5_DecodeFeasibilityProbe.log");
        gJsonPath=DocPath(@"v16_5_decode_feasibility_probe.json");
        [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:nil attributes:nil];

        Event(@"startup",@{@"log":gLogPath,@"json":gJsonPath});

        for(NSString *name in @[@"Alamofire.SessionDelegate",@"Alamofire.SessionDelegateImpl"]){
            Class c=NSClassFromString(name);
            if(!c)continue;
            HookInstance(c,sel_registerName("URLSession:dataTask:didReceiveData:"),(IMP)HookDidReceive,&gOrigDidReceive);
            HookInstance(c,sel_registerName("URLSession:task:didCompleteWithError:"),(IMP)HookDidComplete,&gOrigDidComplete);
        }

        HookClassMethod(NSJSONSerialization.class,@selector(JSONObjectWithData:options:error:),(IMP)HookJSONObjectWithData,&gOrigJSONObjectWithData);

        dispatch_async(dispatch_get_main_queue(),^{InstallRTC(0);});
        Event(@"ready",@{@"target":@"/OpenAPI/v1/private/getPrivateLimit"});
    }
}
