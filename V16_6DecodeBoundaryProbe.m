#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>

static dispatch_queue_t gQ;
static NSString *gLogPath,*gJsonPath;
static NSMutableArray *gEvents;
static NSMutableDictionary<NSNumber*,NSMutableData*> *gTaskData;

static IMP gOrigDidReceive;
static IMP gOrigDidComplete;
static IMP gOrigJSONObjectWithData;
static IMP gOrigDataBase64String;
static IMP gOrigDataBase64Data;
static IMP gOrigSend;

static volatile long long gLastLimitResponseMs=0;
static NSString *gLastRawHash=nil;
static NSUInteger gLastRawBytes=0;

static NSString *DocPath(NSString *name){
    NSString *base=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    return [(base ?: NSTemporaryDirectory()) stringByAppendingPathComponent:name];
}
static long long NowMs(void){ return (long long)(NSDate.date.timeIntervalSince1970*1000.0); }

static NSString *SHA256Prefix(NSData *data){
    if(!data) return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *s=[NSMutableString stringWithCapacity:16];
    for(int i=0;i<8;i++) [s appendFormat:@"%02x",digest[i]];
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
    NSUInteger n=MIN((NSUInteger)14,a.count);
    return [a subarrayWithRange:NSMakeRange(0,n)];
}

static void Flush(void){
    NSDictionary *doc=@{
        @"schema":@"v16.6-decode-boundary-probe",
        @"status":@"ready",
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

static BOOL NearLimit(long long windowMs){
    if(!gLastLimitResponseMs) return NO;
    long long d=NowMs()-gLastLimitResponseMs;
    return d>=0 && d<=windowMs;
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
        gLastRawHash=SHA256Prefix(body);
        gLastRawBytes=body.length;

        Event(@"boundary_raw_response",@{
            @"bytes":@(body.length),
            @"sha256_prefix":gLastRawHash ?: @"",
            @"status":@([task.response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse*)task.response).statusCode:0),
            @"stack":ShortStack(),
            @"error":err.localizedDescription ?: @""
        });
    }
    if(gOrigDidComplete) ((DidCompleteFn)gOrigDidComplete)(self,_cmd,session,task,err);
}

/* Probe Foundation base64 boundaries. We record only length/hash, never content. */
typedef id (*DataBase64StringFn)(id,SEL,NSString*,NSDataBase64DecodingOptions);
static id HookDataBase64String(id self,SEL _cmd,NSString *s,NSDataBase64DecodingOptions opt){
    id out=((DataBase64StringFn)gOrigDataBase64String)(self,_cmd,s,opt);
    if(NearLimit(2000)){
        NSData *d=[out isKindOfClass:NSData.class]?out:nil;
        Event(@"boundary_base64_string",@{
            @"input_chars":@(s.length),
            @"output_bytes":@(d.length),
            @"output_sha256_prefix":SHA256Prefix(d),
            @"delta_ms":@(NowMs()-gLastLimitResponseMs),
            @"stack":ShortStack()
        });
    }
    return out;
}

typedef id (*DataBase64DataFn)(id,SEL,NSData*,NSDataBase64DecodingOptions);
static id HookDataBase64Data(id self,SEL _cmd,NSData *inData,NSDataBase64DecodingOptions opt){
    id out=((DataBase64DataFn)gOrigDataBase64Data)(self,_cmd,inData,opt);
    if(NearLimit(2000)){
        NSData *d=[out isKindOfClass:NSData.class]?out:nil;
        Event(@"boundary_base64_data",@{
            @"input_bytes":@(inData.length),
            @"input_sha256_prefix":SHA256Prefix(inData),
            @"output_bytes":@(d.length),
            @"output_sha256_prefix":SHA256Prefix(d),
            @"delta_ms":@(NowMs()-gLastLimitResponseMs),
            @"stack":ShortStack()
        });
    }
    return out;
}

static NSDictionary *StreamSummary(id obj){
    if(![obj isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *d=obj;
    id stream=d[@"stream"];
    if(![stream isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *s=stream;
    NSMutableDictionary *m=[NSMutableDictionary dictionary];
    for(NSString *k in @[@"flv_pull_url",@"lll_pull_url",@"pull_url",@"replace_url"]){
        id v=s[k];
        if([v isKindOfClass:NSString.class]) m[k]=RedactedURL(v);
    }
    m[@"stream_keys"]=[s.allKeys valueForKey:@"description"];
    return m;
}

typedef id (*JSONObjectWithDataFn)(id,SEL,NSData*,NSJSONReadingOptions,NSError**);
static id HookJSONObjectWithData(id cls,SEL _cmd,NSData *data,NSJSONReadingOptions options,NSError **error){
    id obj=((JSONObjectWithDataFn)gOrigJSONObjectWithData)(cls,_cmd,data,options,error);
    if(NearLimit(3000)){
        NSDictionary *stream=StreamSummary(obj);
        if(stream){
            Event(@"boundary_json_output",@{
                @"raw_bytes":@(gLastRawBytes),
                @"raw_sha256_prefix":gLastRawHash ?: @"",
                @"json_bytes":@(data.length),
                @"json_sha256_prefix":SHA256Prefix(data),
                @"delta_ms":@(NowMs()-gLastLimitResponseMs),
                @"stream":stream,
                @"stack":ShortStack()
            });
        } else {
            Event(@"boundary_json_nearby",@{
                @"json_bytes":@(data.length),
                @"json_sha256_prefix":SHA256Prefix(data),
                @"delta_ms":@(NowMs()-gLastLimitResponseMs),
                @"class":obj?NSStringFromClass([obj class]):@"",
                @"stack":ShortStack()
            });
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
    Event(@"boundary_rtc_handoff",@{
        @"stream_url":RedactedURL(StringGetter(param,@"streamUrl")),
        @"domain":StringGetter(param,@"domain") ?: @"",
        @"host_ip":StringGetter(param,@"hostIp") ?: @"",
        @"delta_ms":@(gLastLimitResponseMs?NowMs()-gLastLimitResponseMs:-1),
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
    if(rtc && !gOrigSend){
        HookClassMethod(rtc,NSSelectorFromString(@"sendSignaling:"),(IMP)HookSend,&gOrigSend);
    }
    if(!gOrigSend && attempt<30){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{InstallRTC(attempt+1);});
    }
}

__attribute__((constructor))
static void Init(void){
    @autoreleasepool{
        gQ=dispatch_queue_create("v16.6.decode.boundary",DISPATCH_QUEUE_SERIAL);
        gEvents=[NSMutableArray array];
        gTaskData=[NSMutableDictionary dictionary];
        gLogPath=DocPath(@"V16_6_DecodeBoundaryProbe.log");
        gJsonPath=DocPath(@"v16_6_decode_boundary_probe.json");
        [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:nil attributes:nil];

        Event(@"startup",@{@"log":gLogPath,@"json":gJsonPath});

        for(NSString *name in @[@"Alamofire.SessionDelegate",@"Alamofire.SessionDelegateImpl"]){
            Class c=NSClassFromString(name);
            if(!c)continue;
            HookInstance(c,sel_registerName("URLSession:dataTask:didReceiveData:"),(IMP)HookDidReceive,&gOrigDidReceive);
            HookInstance(c,sel_registerName("URLSession:task:didCompleteWithError:"),(IMP)HookDidComplete,&gOrigDidComplete);
        }

        HookClassMethod(NSJSONSerialization.class,
                        @selector(JSONObjectWithData:options:error:),
                        (IMP)HookJSONObjectWithData,&gOrigJSONObjectWithData);

        Class dataClass=NSData.class;
        HookInstance(dataClass,
                     @selector(initWithBase64EncodedString:options:),
                     (IMP)HookDataBase64String,&gOrigDataBase64String);
        HookInstance(dataClass,
                     @selector(initWithBase64EncodedData:options:),
                     (IMP)HookDataBase64Data,&gOrigDataBase64Data);

        dispatch_async(dispatch_get_main_queue(),^{InstallRTC(0);});
        Event(@"ready",@{@"target":@"/OpenAPI/v1/private/getPrivateLimit"});
    }
}
