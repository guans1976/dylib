#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static dispatch_queue_t q;
static NSString *logPath;

static void Log(NSString *s) {
    dispatch_async(q, ^{
        NSString *line=[NSString stringWithFormat:@"[%@] %@\n",NSDate.date,s?:@""];
        NSData *b=[line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:logPath];
        if(!h){[b writeToFile:logPath atomically:YES]; return;}
        [h seekToEndOfFile]; [h writeData:b]; [h closeFile];
    });
}
static NSString *Proto(id v) {
    if(!v) return @"nil";
    NSString *s=[[v description] lowercaseString];
    if([s hasPrefix:@"webrtc://"]) return @"webrtc";
    if([s hasPrefix:@"rtmp://"]||[s hasPrefix:@"rtmps://"]) return @"rtmp";
    if([s containsString:@".m3u8"]) return @"hls";
    if([s containsString:@".flv"]) return @"http-flv";
    if([s hasPrefix:@"http://"]||[s hasPrefix:@"https://"]) return @"http(s)";
    return @"other";
}
static NSString *Safe(id v) {
    if(!v) return @"<nil>";
    NSString *s=[v description]?:@"";
    NSString *l=s.lowercaseString;
    if([l containsString:@"://"] || [l containsString:@"txsecret"] ||
       [l containsString:@"txtime"] || [l containsString:@"token"] ||
       [l containsString:@"signature"] || [l containsString:@"password"] ||
       [l containsString:@"candidate:"] || [l containsString:@"ice-ufrag"] ||
       [l containsString:@"ice-pwd"] || [l containsString:@"fingerprint"])
        return [NSString stringWithFormat:@"<redacted:%@>",Proto(v)];
    return s.length>220 ? [[s substringToIndex:220] stringByAppendingString:@"…"] : s;
}
static void DumpObj(id o, NSString *tag) {
    if(!o){Log([NSString stringWithFormat:@"%@=<nil>",tag]); return;}
    Log([NSString stringWithFormat:@"%@ class=%@",tag,NSStringFromClass([o class])]);
    unsigned n=0; objc_property_t *ps=class_copyPropertyList([o class],&n);
    for(unsigned i=0;i<n;i++){
        NSString *k=@(property_getName(ps[i]));
        NSString *lk=k.lowercaseString;
        if([lk containsString:@"code"]||[lk containsString:@"message"]||
           [lk containsString:@"type"]||[lk containsString:@"url"]||
           [lk containsString:@"domain"]||[lk containsString:@"downgrade"]||
           [lk containsString:@"policy"]||[lk containsString:@"stream"]){
            @try { Log([NSString stringWithFormat:@"  %@=%@",k,Safe([o valueForKey:k])]); } @catch(...) {}
        }
    } free(ps);
}

static IMP oldSetDown, oldSignal, oldResult, oldGetDomain, oldSetStream, oldGetStream;

static void SetDown(id self, SEL cmd, BOOL v) {
    Log([NSString stringWithFormat:@"setIsNeedDowngrade:%@",v?@"YES":@"NO"]);
    ((void(*)(id,SEL,BOOL))oldSetDown)(self,cmd,v);
}
static id Signal(id self, SEL cmd) {
    BOOL d=NO; @try { d=((BOOL(*)(id,SEL))objc_msgSend)(self,@selector(isNeedDowngrade)); } @catch(...) {}
    id su=nil; @try { su=((id(*)(id,SEL))objc_msgSend)(self,@selector(streamUrl)); } @catch(...) {}
    Log([NSString stringWithFormat:@"playSignalingRequest ENTER downgrade=%@ streamProtocol=%@",d?@"YES":@"NO",Proto(su)]);
    id r=((id(*)(id,SEL))oldSignal)(self,cmd);
    Log([NSString stringWithFormat:@"playSignalingRequest RETURN class=%@ value=%@",r?NSStringFromClass([r class]):@"nil",Safe(r)]);
    return r;
}
static void Result(id self, SEL cmd, id resp) {
    BOOL d=NO; @try { d=((BOOL(*)(id,SEL))objc_msgSend)(self,@selector(isNeedDowngrade)); } @catch(...) {}
    Log([NSString stringWithFormat:@"playRequestResultDoingWithSdpResp ENTER downgrade=%@",d?@"YES":@"NO"]);
    DumpObj(resp,@"SdpResp");
    ((void(*)(id,SEL,id))oldResult)(self,cmd,resp);
    BOOL d2=NO; @try { d2=((BOOL(*)(id,SEL))objc_msgSend)(self,@selector(isNeedDowngrade)); } @catch(...) {}
    Log([NSString stringWithFormat:@"playRequestResultDoingWithSdpResp EXIT downgrade=%@",d2?@"YES":@"NO"]);
}
static id GetDomain(id self, SEL cmd) {
    id r=((id(*)(id,SEL))oldGetDomain)(self,cmd);
    Log([NSString stringWithFormat:@"getDomain => %@",Safe(r)]);
    return r;
}
static void SetStream(id self, SEL cmd, id v) {
    Log([NSString stringWithFormat:@"setStreamUrl protocol=%@",Proto(v)]);
    ((void(*)(id,SEL,id))oldSetStream)(self,cmd,v);
}
static id GetStream(id self, SEL cmd) {
    id r=((id(*)(id,SEL))oldGetStream)(self,cmd);
    return r; // deliberately quiet: avoids repeated sensitive URL logging
}
static void Hook(Class c, SEL s, IMP n, IMP *old) {
    Method m=c?class_getInstanceMethod(c,s):NULL;
    if(!m){Log([NSString stringWithFormat:@"MISS %@",NSStringFromSelector(s)]);return;}
    *old=method_getImplementation(m); method_setImplementation(m,n);
    Log([NSString stringWithFormat:@"HOOK %@ type=%s",NSStringFromSelector(s),method_getTypeEncoding(m)]);
}
__attribute__((constructor)) static void InitV13(void){ @autoreleasepool {
    q=dispatch_queue_create("v13.trace",DISPATCH_QUEUE_SERIAL);
    NSString *d=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    logPath=[d stringByAppendingPathComponent:@"V13_HWLLS_SignalingDowngradeTrace.log"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),
      dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        Log(@"V13 ready");
        Class c=objc_getClass("HWLLSClientProxy");
        Hook(c,@selector(setIsNeedDowngrade:),(IMP)SetDown,&oldSetDown);
        Hook(c,@selector(playSignalingRequest),(IMP)Signal,&oldSignal);
        Hook(c,@selector(playRequestResultDoingWithSdpResp:),(IMP)Result,&oldResult);
        Hook(c,@selector(getDomain),(IMP)GetDomain,&oldGetDomain);
        Hook(c,@selector(setStreamUrl:),(IMP)SetStream,&oldSetStream);
        Hook(c,@selector(streamUrl),(IMP)GetStream,&oldGetStream);
    });
}}
