#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>

static dispatch_queue_t exportQ, brokerQ;
static NSString *exportPath,*paidExportPath,*logPath,*brokerCachePath;

static IMP originalSend;
static IMP originalDataTask;
static IMP originalDataTaskCompletion;

static BOOL installedRTC;
static BOOL installedNetwork;

static volatile BOOL paidPending = NO;
static volatile NSTimeInterval paidMarkedAt = 0;
static const NSTimeInterval kPaidWindowSeconds = 120.0;

static NSString *lastLimitUID = @"";
static NSData *latestBrokerJSON = nil;

static void Log(NSString *text) {
    dispatch_async(exportQ, ^{
        NSData *data=[[NSString stringWithFormat:@"[%@] %@\n",NSDate.date,text] dataUsingEncoding:NSUTF8StringEncoding];
        @try {
            NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:logPath];
            if(h) {[h seekToEndOfFile];[h writeData:data];[h closeFile];}
            else [data writeToFile:logPath atomically:YES];
        } @catch(NSException *exception) { (void)exception; }
    });
}

static char Type(const char *s) {
    if(!s)return 0;
    while(*s && strchr("rnNoORV",*s))s++;
    return *s;
}

static BOOL Getter(id object,NSString *name,char expected) {
    if(!object)return NO;
    SEL sel=NSSelectorFromString(name);
    Method m=class_getInstanceMethod(object_getClass(object),sel);
    if(!m || method_getNumberOfArguments(m)!=2)return NO;
    char *t=method_copyReturnType(m);
    BOOL ok=Type(t)==expected;
    free(t);
    return ok;
}

static NSString *StringValue(id object,NSString *name) {
    if(!Getter(object,name,'@'))return @"";
    id value=((id(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name));
    return [value isKindOfClass:NSString.class]?value:@"";
}

static int IntValue(id object,NSString *name) {
    if(!Getter(object,name,'i'))return -1;
    return ((int(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name));
}

static BOOL BoolValue(id object,NSString *name) {
    if(!Getter(object,name,'B'))return NO;
    return ((BOOL(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name));
}

static BOOL PaidMarkIsFresh(void) {
    if(!paidPending)return NO;
    NSTimeInterval age=NSDate.date.timeIntervalSince1970-paidMarkedAt;
    if(age<0 || age>kPaidWindowSeconds) {
        paidPending=NO; paidMarkedAt=0;
        Log([NSString stringWithFormat:@"PAID_MARK expired age=%.1fs",age]);
        return NO;
    }
    return YES;
}

static void CaptureLimitUID(NSURLRequest *request) {
    if(![request isKindOfClass:NSURLRequest.class])return;
    NSString *path=request.URL.path.lowercaseString ?: @"";
    if(![path containsString:@"/private/getprivatelimit"]) return;
    NSURLComponents *c=[NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    for(NSURLQueryItem *item in c.queryItems ?: @[]) {
        if([item.name.lowercaseString isEqualToString:@"uid"] && item.value.length) {
            @synchronized([NSObject class]) { lastLimitUID=[item.value copy]; }
            Log([NSString stringWithFormat:@"BROKER_META captured getPrivateLimit uid(length=%lu)",
                 (unsigned long)item.value.length]);
            break;
        }
    }
}

static void MarkPaidRequest(NSURLRequest *request) {
    if(![request isKindOfClass:NSURLRequest.class])return;
    CaptureLimitUID(request);
    NSString *url=request.URL.absoluteString ?: @"";
    if([url containsString:@"/private/checkPrivateCharge"]) {
        paidPending=YES;
        paidMarkedAt=NSDate.date.timeIntervalSince1970;
        Log([NSString stringWithFormat:@"PAID_MARK request method=%@ urlPath=%@",
             request.HTTPMethod ?: @"", request.URL.path ?: @""]);
    }
}

static id DataTask(id self, SEL sel, NSURLRequest *request) {
    MarkPaidRequest(request);
    return ((id(*)(id,SEL,id))originalDataTask)(self,sel,request);
}

static id DataTaskCompletion(id self, SEL sel, NSURLRequest *request, id completion) {
    MarkPaidRequest(request);
    return ((id(*)(id,SEL,id,id))originalDataTaskCompletion)(self,sel,request,completion);
}

static NSDictionary *BuildRecord(id param) {
    NSString *stream=StringValue(param,@"streamUrl");
    NSString *offer=StringValue(param,@"localSdp");
    NSString *domain=StringValue(param,@"domain");
    NSString *hostIp=StringValue(param,@"hostIp");
    int transport=IntValue(param,@"signalingType");

    if(!stream.length || ![offer hasPrefix:@"v=0"] || ![offer containsString:@"m="]) {
        return @{@"schema":@"hwlls-playback-v16-broker",
                 @"status":@"incomplete",
                 @"reason":@"SDK parameter missing streamUrl or localSdp"};
    }

    NSURLComponents *streamParts=[NSURLComponents componentsWithString:stream];
    NSString *server=domain.length?domain:streamParts.host;
    if(!server.length)server=hostIp;
    if(!server.length) {
        return @{@"schema":@"hwlls-playback-v16-broker",
                 @"status":@"incomplete",
                 @"reason":@"SDK parameter missing signaling host"};
    }

    NSURLComponents *url=[NSURLComponents new];
    url.scheme=transport==0?@"http":@"https";
    url.host=(transport==0 && hostIp.length)?hostIp:server;
    url.port=transport==0?@80:@443;
    url.path=@"/webrtc/v1/pullstream";
    if(!url.URL) {
        return @{@"schema":@"hwlls-playback-v16-broker",
                 @"status":@"incomplete",
                 @"reason":@"Invalid signaling host"};
    }

    NSMutableDictionary *headers=[@{@"Content-Type":@"application/json;charset=utf-8"} mutableCopy];
    if(transport==0 && domain.length)headers[@"Host"]=domain;

    NSDictionary *body=@{
        @"streamurl":stream,
        @"localsdp":@{@"type":@"offer",@"sdp":offer}
    };

    NSString *uid=@"";
    @synchronized([NSObject class]) { uid=lastLimitUID ?: @""; }

    return @{
        @"schema":@"hwlls-playback-v16-broker",
        @"status":@"ready",
        @"updated_at_ms":@((long long)(NSDate.date.timeIntervalSince1970*1000)),
        @"request_origin":@"verified-sdk-http-format",
        @"channel_id":uid,
        @"native_signaling_type":@(transport),
        @"native_signaling_port":@(IntValue(param,@"port")),
        @"stream_url":stream,
        @"signaling_domain":server,
        @"signaling_host_ip":hostIp ?: @"",
        @"request":@{
            @"url":url.URL.absoluteString,
            @"method":@"POST",
            @"headers":headers,
            @"body":body
        }
    };
}

static void UpdateBrokerCache(NSDictionary *record) {
    if(![record[@"status"] isEqual:@"ready"]) return;
    NSError *e=nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:&e];
    if(!data) return;
    @synchronized([NSObject class]) { latestBrokerJSON=data; }
    [data writeToFile:brokerCachePath atomically:YES];
    Log(@"BROKER_CACHE updated from authorized RTC handoff");
}

static void SaveToPath(NSDictionary *record, NSString *path, NSString *tag) {
    dispatch_async(exportQ, ^{
        NSError *error=nil;
        NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:&error];
        BOOL ok=data && [data writeToFile:path options:NSDataWritingAtomic error:&error];
        NSLog(@"[V16.1 Broker] %@ export %@",tag,ok?@"saved":@"failed");
    });
}

static void ExportParam(id param) {
    if(BoolValue(param,@"isStop")) {
        Log(@"STOP ignored; retaining playback export");
        return;
    }
    BOOL paid=PaidMarkIsFresh();
    NSDictionary *record=BuildRecord(param);
    SaveToPath(record,exportPath,@"normal");
    if(paid && [record[@"status"] isEqual:@"ready"]) {
        SaveToPath(record,paidExportPath,@"paid");
        paidPending=NO; paidMarkedAt=0;
        Log(@"PAID_EXPORT ready -> paid_playback_info.json");
    }
    if([record[@"status"] isEqual:@"ready"]) UpdateBrokerCache(record);
}

static id Send(id self,SEL sel,id param) {
    @try { ExportParam(param); }
    @catch(NSException *exception) { Log([@"EXPORT exception " stringByAppendingString:exception.name]); }
    id response=((id(*)(id,SEL,id))originalSend)(self,sel,param);
    return response;
}

/* -------- Minimal HTTP broker -------- */

static NSData *HTTPResponse(NSInteger code, NSDictionary *obj) {
    NSData *body=[NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] ?: [NSData data];
    NSString *status=(code==200?@"200 OK":code==409?@"409 Conflict":@"400 Bad Request");
    NSString *head=[NSString stringWithFormat:
                    @"HTTP/1.1 %@\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n",
                    status,(unsigned long)body.length];
    NSMutableData *d=[NSMutableData dataWithData:[head dataUsingEncoding:NSUTF8StringEncoding]];
    [d appendData:body];
    return d;
}

static NSDictionary *ParseJSONBody(NSData *reqData) {
    NSString *s=[[NSString alloc] initWithData:reqData encoding:NSUTF8StringEncoding];
    NSRange r=[s rangeOfString:@"\r\n\r\n"];
    if(r.location==NSNotFound) return @{};
    NSString *body=[s substringFromIndex:r.location+r.length];
    NSData *d=[body dataUsingEncoding:NSUTF8StringEncoding];
    id obj=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class]?obj:@{};
}

static BOOL StreamRecordExpired(NSDictionary *doc) {
    NSString *stream=doc[@"stream_url"];
    if(![stream isKindOfClass:NSString.class]) return YES;
    NSURLComponents *c=[NSURLComponents componentsWithString:stream];
    NSString *tx=nil;
    for(NSURLQueryItem *i in c.queryItems ?: @[]) {
        if([i.name.lowercaseString isEqualToString:@"txtime"]) { tx=i.value; break; }
    }
    if(!tx.length) return NO;
    unsigned long long v=0;
    NSScanner *sc=[NSScanner scannerWithString:tx];
    if(![sc scanHexLongLong:&v]) return NO;
    return (NSTimeInterval)v <= NSDate.date.timeIntervalSince1970;
}

static void HandleClient(int fd) {
    NSMutableData *buf=[NSMutableData data];
    char tmp[4096];
    while(buf.length<65536) {
        ssize_t n=recv(fd,tmp,sizeof(tmp),0);
        if(n<=0) break;
        [buf appendBytes:tmp length:(NSUInteger)n];
        NSString *s=[[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
        if([s containsString:@"\r\n\r\n"]) {
            NSRange hr=[s rangeOfString:@"Content-Length:" options:NSCaseInsensitiveSearch];
            NSUInteger need=0;
            if(hr.location!=NSNotFound) {
                NSString *tail=[s substringFromIndex:hr.location+hr.length];
                NSScanner *sc=[NSScanner scannerWithString:tail];
                NSInteger x=0; [sc scanInteger:&x]; if(x>0) need=(NSUInteger)x;
            }
            NSRange sep=[s rangeOfString:@"\r\n\r\n"];
            NSUInteger have=[s substringFromIndex:sep.location+sep.length].lengthOfBytesUsingEncoding:NSUTF8StringEncoding;
            if(have>=need) break;
        }
    }

    NSString *req=[[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] ?: @"";
    BOOL health=[req hasPrefix:@"GET /health "];
    BOOL refresh=[req hasPrefix:@"POST /refresh "] || [req hasPrefix:@"GET /latest "];

    NSData *resp=nil;
    if(health) {
        NSString *uid=@""; @synchronized([NSObject class]) { uid=lastLimitUID ?: @""; }
        BOOL hasCache=NO; @synchronized([NSObject class]) { hasCache=(latestBrokerJSON!=nil); }
        resp=HTTPResponse(200,@{@"status":@"ok",
                                @"broker":@"v16.1",
                                @"channel_id":uid,
                                @"has_cache":@(hasCache)});
    } else if(refresh) {
        NSDictionary *want=ParseJSONBody(buf);
        NSString *wantChannel=[want[@"channel_id"] description] ?: @"";
        NSData *data=nil; @synchronized([NSObject class]) { data=latestBrokerJSON; }
        NSDictionary *doc=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;

        if(![doc isKindOfClass:NSDictionary.class]) {
            resp=HTTPResponse(409,@{@"error":@"no authorized playback observed yet",
                                    @"action":@"open the channel normally in the app"});
        } else {
            NSString *got=[doc[@"channel_id"] description] ?: @"";
            if(wantChannel.length && got.length && ![wantChannel isEqualToString:got]) {
                resp=HTTPResponse(409,@{@"error":@"latest authorized playback is for another channel",
                                        @"channel_id":got});
            } else if(StreamRecordExpired(doc)) {
                resp=HTTPResponse(409,@{@"error":@"latest authorized playback is expired",
                                        @"action":@"let the app obtain a fresh playback session"});
            } else {
                resp=HTTPResponse(200,doc);
            }
        }
    } else {
        resp=HTTPResponse(400,@{@"error":@"use GET /health or POST /refresh"});
    }
    send(fd,resp.bytes,resp.length,0);
    shutdown(fd,SHUT_RDWR);
    close(fd);
}

static void StartBroker(void) {
    dispatch_async(brokerQ,^{
        int s=socket(AF_INET,SOCK_STREAM,0);
        if(s<0){Log(@"BROKER socket failed");return;}
        int yes=1; setsockopt(s,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
        struct sockaddr_in addr; memset(&addr,0,sizeof(addr));
        addr.sin_family=AF_INET;
        addr.sin_addr.s_addr=htonl(INADDR_ANY);
        addr.sin_port=htons(8766);
        if(bind(s,(struct sockaddr*)&addr,sizeof(addr))<0){Log(@"BROKER bind 8766 failed");close(s);return;}
        if(listen(s,8)<0){Log(@"BROKER listen failed");close(s);return;}
        Log(@"BROKER listening on 0.0.0.0:8766");
        while(1){
            int c=accept(s,NULL,NULL);
            if(c<0){ if(errno==EINTR)continue; break; }
            @autoreleasepool { HandleClient(c); }
        }
        close(s);
    });
}

static void InstallNetwork(void) {
    if(installedNetwork)return;
    Class c=objc_getClass("NSURLSession");
    if(!c) return;

    SEL s1=NSSelectorFromString(@"dataTaskWithRequest:");
    Method m1=class_getInstanceMethod(c,s1);
    if(m1) { originalDataTask=method_getImplementation(m1); method_setImplementation(m1,(IMP)DataTask); }

    SEL s2=NSSelectorFromString(@"dataTaskWithRequest:completionHandler:");
    Method m2=class_getInstanceMethod(c,s2);
    if(m2) { originalDataTaskCompletion=method_getImplementation(m2); method_setImplementation(m2,(IMP)DataTaskCompletion); }

    installedNetwork=YES;
    Log(@"HOOK NSURLSession installed");
}

static void InstallRTC(unsigned attempt) {
    if(installedRTC)return;
    Class c=objc_getClass("RTCSignalingSender");
    Class meta=c?object_getClass(c):Nil;
    SEL sel=NSSelectorFromString(@"sendSignaling:");
    Method m=meta?class_getInstanceMethod(meta,sel):NULL;
    if(!m) {
        if(attempt<30) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{InstallRTC(attempt+1);});
        } else Log(@"HOOK_MISSING RTCSignalingSender sendSignaling:");
        return;
    }
    originalSend=method_getImplementation(m);
    method_setImplementation(m,(IMP)Send);
    installedRTC=YES;
    Log(@"HOOK RTCSignalingSender +sendSignaling:");
}

__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        exportQ=dispatch_queue_create("v16.1.broker.export",DISPATCH_QUEUE_SERIAL);
        brokerQ=dispatch_queue_create("v16.1.broker.http",DISPATCH_QUEUE_SERIAL);
        NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        exportPath=[docs stringByAppendingPathComponent:@"playback_info.json"];
        paidExportPath=[docs stringByAppendingPathComponent:@"paid_playback_info.json"];
        logPath=[docs stringByAppendingPathComponent:@"V16_1_Broker.log"];
        brokerCachePath=[docs stringByAppendingPathComponent:@"broker_latest_authorized.json"];
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];

        NSData *cached=[NSData dataWithContentsOfFile:brokerCachePath];
        if(cached.length) latestBrokerJSON=cached;

        InstallNetwork();
        dispatch_async(dispatch_get_main_queue(),^{InstallRTC(0);});
        StartBroker();
        Log(@"V16.1 Broker started");
    }
}
