#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>

static dispatch_queue_t exportQ;
static NSString *exportPath,*paidExportPath,*logPath;

static IMP originalSend;
static IMP originalDataTask;
static IMP originalDataTaskCompletion;

static BOOL installedRTC;
static BOOL installedNetwork;

static volatile BOOL paidPending = NO;
static volatile NSTimeInterval paidMarkedAt = 0;
static const NSTimeInterval kPaidWindowSeconds = 120.0;

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

static void SaveToPath(NSDictionary *record, NSString *path, NSString *tag) {
    dispatch_async(exportQ, ^{
        NSError *error=nil;
        NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:&error];
        BOOL ok=data && [data writeToFile:path options:NSDataWritingAtomic error:&error];
        NSLog(@"[V16.1] %@ export %@",tag,ok?@"saved":@"failed");
    });
}

static void SaveNormal(NSDictionary *record) {
    SaveToPath(record,exportPath,@"normal");
}

static void SavePaid(NSDictionary *record) {
    SaveToPath(record,paidExportPath,@"paid");
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
        paidPending=NO;
        paidMarkedAt=0;
        Log([NSString stringWithFormat:@"PAID_MARK expired age=%.1fs",age]);
        return NO;
    }
    return YES;
}

static void MarkPaidRequest(NSURLRequest *request) {
    if(![request isKindOfClass:NSURLRequest.class])return;
    NSString *url=request.URL.absoluteString ?: @"";
    if([url containsString:@"/private/checkPrivateCharge"]) {
        paidPending=YES;
        paidMarkedAt=NSDate.date.timeIntervalSince1970;
        Log([NSString stringWithFormat:@"PAID_MARK request method=%@ urlPath=%@",
             request.HTTPMethod ?: @"",
             request.URL.path ?: @""]);
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

    Log([NSString stringWithFormat:
         @"SEND transport=%d streamLength=%lu offerLength=%lu domainLength=%lu paidFresh=%d",
         transport,
         (unsigned long)stream.length,
         (unsigned long)offer.length,
         (unsigned long)domain.length,
         PaidMarkIsFresh()?1:0]);

    if(!stream.length || ![offer hasPrefix:@"v=0"] || ![offer containsString:@"m="]) {
        return @{@"schema":@"hwlls-playback-v16",
                 @"status":@"incomplete",
                 @"reason":@"SDK parameter missing streamUrl or localSdp"};
    }

    NSURLComponents *streamParts=[NSURLComponents componentsWithString:stream];
    NSString *server=domain.length?domain:streamParts.host;
    if(!server.length)server=hostIp;
    if(!server.length) {
        return @{@"schema":@"hwlls-playback-v16",
                 @"status":@"incomplete",
                 @"reason":@"SDK parameter missing signaling host"};
    }

    NSURLComponents *url=[NSURLComponents new];
    url.scheme=transport==0?@"http":@"https";
    url.host=(transport==0 && hostIp.length)?hostIp:server;
    url.port=transport==0?@80:@443;
    url.path=@"/webrtc/v1/pullstream";

    if(!url.URL) {
        return @{@"schema":@"hwlls-playback-v16",
                 @"status":@"incomplete",
                 @"reason":@"Invalid signaling host"};
    }

    NSMutableDictionary *headers=[@{
        @"Content-Type":@"application/json;charset=utf-8"
    } mutableCopy];
    if(transport==0 && domain.length)headers[@"Host"]=domain;

    NSDictionary *body=@{
        @"streamurl":stream,
        @"localsdp":@{
            @"type":@"offer",
            @"sdp":offer
        }
    };

    return @{
        @"schema":@"hwlls-playback-v16",
        @"status":@"ready",
        @"updated_at_ms":@((long long)(NSDate.date.timeIntervalSince1970*1000)),
        @"request_origin":@"verified-sdk-http-format",
        @"requires_http_transport_test":@(transport==2),
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

static void ExportParam(id param) {
    if(BoolValue(param,@"isStop")) {
        Log(@"STOP ignored; retaining playback export");
        return;
    }

    BOOL paid=PaidMarkIsFresh();
    NSDictionary *record=BuildRecord(param);

    // Preserve original V16 behavior unconditionally.
    SaveNormal(record);

    // Extension: if a checkPrivateCharge request was seen shortly before
    // a real RTC signaling send, mirror the same V20-compatible record
    // to paid_playback_info.json.
    if(paid && [record[@"status"] isEqual:@"ready"]) {
        SavePaid(record);
        paidPending=NO;
        paidMarkedAt=0;
        Log(@"PAID_EXPORT ready -> paid_playback_info.json");
    } else if(paid) {
        Log(@"PAID_EXPORT skipped because RTC record is not ready");
    }

    if([record[@"status"] isEqual:@"ready"]) {
        int transport=IntValue(param,@"signalingType");
        Log(transport==2
            ? @"EXPORT ready; native UDP, desktop HTTPS endpoint requires testing"
            : @"EXPORT ready; native HTTP/HTTPS");
    }
}

static id Send(id self,SEL sel,id param) {
    @try {
        ExportParam(param);
    } @catch(NSException *exception) {
        Log([@"EXPORT exception " stringByAppendingString:exception.name]);
    }

    id response=((id(*)(id,SEL,id))originalSend)(self,sel,param);

    Log([NSString stringWithFormat:
         @"SDK_RESPONSE httpCode=%d errCode=%d remoteSdpLength=%lu",
         IntValue(response,@"httpCode"),
         IntValue(response,@"errCode"),
         (unsigned long)StringValue(response,@"remoteSdp").length]);

    return response;
}

static void InstallNetwork(void) {
    if(installedNetwork)return;

    Class c=objc_getClass("NSURLSession");
    if(!c) {
        Log(@"NETWORK_HOOK_MISSING NSURLSession");
        return;
    }

    SEL s1=NSSelectorFromString(@"dataTaskWithRequest:");
    Method m1=class_getInstanceMethod(c,s1);
    if(m1) {
        originalDataTask=method_getImplementation(m1);
        method_setImplementation(m1,(IMP)DataTask);
        Log(@"HOOK NSURLSession -dataTaskWithRequest:");
    } else {
        Log(@"NETWORK_HOOK_MISSING dataTaskWithRequest:");
    }

    SEL s2=NSSelectorFromString(@"dataTaskWithRequest:completionHandler:");
    Method m2=class_getInstanceMethod(c,s2);
    if(m2) {
        originalDataTaskCompletion=method_getImplementation(m2);
        method_setImplementation(m2,(IMP)DataTaskCompletion);
        Log(@"HOOK NSURLSession -dataTaskWithRequest:completionHandler:");
    } else {
        Log(@"NETWORK_HOOK_MISSING dataTaskWithRequest:completionHandler:");
    }

    installedNetwork=YES;
}

static void InstallRTC(unsigned attempt) {
    if(installedRTC)return;

    Class c=objc_getClass("RTCSignalingSender");
    Class meta=c?object_getClass(c):Nil;
    SEL sel=NSSelectorFromString(@"sendSignaling:");
    Method m=meta?class_getInstanceMethod(meta,sel):NULL;

    if(!m) {
        if(attempt<30) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),
                           dispatch_get_main_queue(),^{ InstallRTC(attempt+1); });
        } else {
            Log(@"HOOK_MISSING RTCSignalingSender sendSignaling:");
            SaveNormal(@{@"schema":@"hwlls-playback-v16",@"status":@"hook_missing"});
        }
        return;
    }

    char *ret=method_copyReturnType(m);
    char *arg=method_copyArgumentType(m,2);
    BOOL valid=method_getNumberOfArguments(m)==3 && Type(ret)=='@' && Type(arg)=='@';
    free(ret);
    free(arg);

    if(!valid) {
        Log(@"ABI_SKIP sendSignaling:");
        SaveNormal(@{@"schema":@"hwlls-playback-v16",@"status":@"abi_mismatch"});
        return;
    }

    originalSend=method_getImplementation(m);
    if(!class_addMethod(meta,sel,(IMP)Send,method_getTypeEncoding(m))) {
        method_setImplementation(m,(IMP)Send);
    }

    installedRTC=YES;
    Log(@"HOOK RTCSignalingSender +sendSignaling:");
}

__attribute__((constructor))
static void Initialize(void) {
    @autoreleasepool {
        exportQ=dispatch_queue_create("v16.1.playback.export",DISPATCH_QUEUE_SERIAL);

        NSString *documents=NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory,NSUserDomainMask,YES).firstObject;

        exportPath=[documents stringByAppendingPathComponent:@"playback_info.json"];
        paidExportPath=[documents stringByAppendingPathComponent:@"paid_playback_info.json"];
        logPath=[documents stringByAppendingPathComponent:@"V16_1_PaidPlaybackExport.log"];

        // Preserve original normal output.
        SaveNormal(@{@"schema":@"hwlls-playback-v16",@"status":@"waiting"});
        // Separate extension output.
        SavePaid(@{@"schema":@"hwlls-playback-v16",@"status":@"waiting"});

        dispatch_async(dispatch_get_main_queue(),^{
            InstallNetwork();
            InstallRTC(0);
        });
    }
}
