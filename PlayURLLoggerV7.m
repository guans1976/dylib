#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>

static dispatch_queue_t gLogQ;
static NSString *gLogPath;

static NSString *Redact(NSString *s) {
    if (!s) return @"(null)";
    NSString *out = [s copy];
    NSArray *keys = @[@"txSecret", @"token", @"access_token", @"authorization",
                      @"cookie", @"password", @"secret", @"credential", @"signature"];
    for (NSString *key in keys) {
        NSString *pat = [NSString stringWithFormat:@"(?i)(%@=)[^&\\s]+",
                         [NSRegularExpression escapedPatternForString:key]];
        NSRegularExpression *re =
            [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
        out = [re stringByReplacingMatchesInString:out options:0
                                             range:NSMakeRange(0, out.length)
                                      withTemplate:@"$1<redacted>"];
    }
    return out;
}

static NSString *SafeDesc(id obj) {
    if (!obj) return @"(nil)";
    @try { return Redact([obj description]); }
    @catch (__unused NSException *e) { return @"<description failed>"; }
}

static void Log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    dispatch_async(gLogQ ?: dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSDateFormatter *df=[NSDateFormatter new];
        df.dateFormat=@"yyyy-MM-dd HH:mm:ss.SSS Z";
        NSString *line=[NSString stringWithFormat:@"[%@] %@\n",[df stringFromDate:[NSDate date]],msg];
        NSData *d=[line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if(!h){ [d writeToFile:gLogPath atomically:YES]; return; }
        [h seekToEndOfFile]; [h writeData:d]; [h closeFile];
    });
}

/* Original IMPs are stored by class+selector so the generic trampolines can
   call through without assuming one global implementation per selector. */
static NSMutableDictionary<NSString*,NSValue*> *gOrig;
static NSString *K(id self, SEL _cmd) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
}
static IMP Orig(id self, SEL _cmd) {
    return (IMP)[gOrig[K(self,_cmd)] pointerValue];
}
static void Remember(Class c, SEL s, IMP imp) {
    gOrig[[NSString stringWithFormat:@"%@|%@",NSStringFromClass(c),NSStringFromSelector(s)]]=[NSValue valueWithPointer:imp];
}

static void hook_v0(id self, SEL _cmd) {
    Log(@"[CALL] %@ -%@",NSStringFromClass([self class]),NSStringFromSelector(_cmd));
    void(*f)(id,SEL)=(void*)Orig(self,_cmd); if(f) f(self,_cmd);
}
static void hook_v1(id self, SEL _cmd, id a) {
    Log(@"[CALL] %@ -%@ arg=%@",NSStringFromClass([self class]),NSStringFromSelector(_cmd),SafeDesc(a));
    void(*f)(id,SEL,id)=(void*)Orig(self,_cmd); if(f) f(self,_cmd,a);
}
static void hook_v2(id self, SEL _cmd, id a, id b) {
    Log(@"[CALL] %@ -%@ arg1=%@ arg2=%@",NSStringFromClass([self class]),NSStringFromSelector(_cmd),SafeDesc(a),SafeDesc(b));
    void(*f)(id,SEL,id,id)=(void*)Orig(self,_cmd); if(f) f(self,_cmd,a,b);
}
static void hook_v1q(id self, SEL _cmd, id a, NSInteger q) {
    Log(@"[CALL] %@ -%@ arg=%@ state=%ld",NSStringFromClass([self class]),NSStringFromSelector(_cmd),SafeDesc(a),(long)q);
    void(*f)(id,SEL,id,NSInteger)=(void*)Orig(self,_cmd); if(f) f(self,_cmd,a,q);
}
static void hook_v3(id self, SEL _cmd, id a, id b, id c) {
    Log(@"[CALL] %@ -%@ arg1=%@ arg2=%@ arg3=%@",NSStringFromClass([self class]),NSStringFromSelector(_cmd),SafeDesc(a),SafeDesc(b),SafeDesc(c));
    void(*f)(id,SEL,id,id,id)=(void*)Orig(self,_cmd); if(f) f(self,_cmd,a,b,c);
}
static id hook_obj0(id self, SEL _cmd) {
    id(*f)(id,SEL)=(void*)Orig(self,_cmd);
    id r=f?f(self,_cmd):nil;
    Log(@"[CALL] %@ -%@ => %@",NSStringFromClass([self class]),NSStringFromSelector(_cmd),SafeDesc(r));
    return r;
}
static id hook_obj1(id self, SEL _cmd, id a) {
    Log(@"[CALL] %@ -%@ arg=%@",NSStringFromClass([self class]),NSStringFromSelector(_cmd),SafeDesc(a));
    id(*f)(id,SEL,id)=(void*)Orig(self,_cmd);
    id r=f?f(self,_cmd,a):nil;
    Log(@"[RET ] %@ -%@ => %@",NSStringFromClass([self class]),NSStringFromSelector(_cmd),SafeDesc(r));
    return r;
}
static id hook_obj2(id self, SEL _cmd, id a, id b) {
    Log(@"[CALL] %@ -%@ arg1=%@ arg2=%@",NSStringFromClass([self class]),NSStringFromSelector(_cmd),SafeDesc(a),SafeDesc(b));
    id(*f)(id,SEL,id,id)=(void*)Orig(self,_cmd);
    id r=f?f(self,_cmd,a,b):nil;
    Log(@"[RET ] %@ -%@ => %@",NSStringFromClass([self class]),NSStringFromSelector(_cmd),SafeDesc(r));
    return r;
}
static id hook_obj3(id self, SEL _cmd, id a, id b, id c) {
    Log(@"[CALL] %@ -%@ arg1=%@ arg2=%@ arg3=%@",NSStringFromClass([self class]),NSStringFromSelector(_cmd),SafeDesc(a),SafeDesc(b),SafeDesc(c));
    id(*f)(id,SEL,id,id,id)=(void*)Orig(self,_cmd);
    id r=f?f(self,_cmd,a,b,c):nil;
    Log(@"[RET ] %@ -%@ => %@",NSStringFromClass([self class]),NSStringFromSelector(_cmd),SafeDesc(r));
    return r;
}

static void Hook(const char *cn,const char *sn,IMP repl) {
    Class c=objc_getClass(cn); SEL s=sel_registerName(sn);
    if(!c){ Log(@"[MISS CLASS] %s",cn); return; }
    Method m=class_getInstanceMethod(c,s);
    if(!m){ Log(@"[MISS METHOD] %s -%s",cn,sn); return; }
    const char *types=method_getTypeEncoding(m);
    IMP old=method_getImplementation(m);
    Remember(c,s,old);
    method_setImplementation(m,repl);
    Log(@"[HOOK] %s -%s type=%s",cn,sn,types?: "?");
}

/* NSURL remains useful for seeing the SDK entry URL and any HLS/FLV fallback. */
@interface NSURL (PLV7)
+ (instancetype)plv7_URLWithString:(NSString *)URLString;
@end
@implementation NSURL (PLV7)
+ (void)load {
    Method a=class_getClassMethod(self,@selector(URLWithString:));
    Method b=class_getClassMethod(self,@selector(plv7_URLWithString:));
    if(a&&b) method_exchangeImplementations(a,b);
}
+ (instancetype)plv7_URLWithString:(NSString *)s {
    NSString *l=s.lowercaseString;
    if ([l containsString:@"webrtc://"] || [l containsString:@".m3u8"] ||
        [l containsString:@".flv"] || [l hasPrefix:@"rtmp://"] ||
        [l hasPrefix:@"rtmps://"]) Log(@"[MEDIA URL] %@",Redact(s));
    return [self plv7_URLWithString:s];
}
@end

static void InstallHooks(void) {
    Log(@"========== V7 INSTALL HOOKS ==========");

    /* Exact HWLLS selectors discovered by V6.1 */
    Hook("HWLLSClientProxy","setStreamUrl:",(IMP)hook_v1);
    Hook("HWLLSClientProxy","setLocalSDP:",(IMP)hook_v1);
    Hook("HWLLSClientProxy","setRemoteSDP:",(IMP)hook_v1);
    Hook("HWLLSClientProxy","playRequestResultDoingWithSdpResp:",(IMP)hook_v1);
    Hook("HWLLSClientProxy","createPeerConnection",(IMP)hook_v0);
    Hook("HWLLSClientProxy","createRemoteDescriptionWithRemoteSdp:completionHandler:",(IMP)hook_v2);
    Hook("HWLLSClientProxy","peerConnection:didChangeSignalingState:",(IMP)hook_v1q);
    Hook("HWLLSClientProxy","peerConnection:didChangeIceConnectionState:",(IMP)hook_v1q);
    Hook("HWLLSClientProxy","peerConnection:didChangeConnectionState:",(IMP)hook_v1q);
    Hook("HWLLSClientProxy","peerConnection:didChangeIceGatheringState:",(IMP)hook_v1q);
    Hook("HWLLSClientProxy","peerConnection:didGenerateIceCandidate:",(IMP)hook_v2);
    Hook("HWLLSClientProxy","peerConnection:didAddStream:",(IMP)hook_v2);
    Hook("HWLLSClientProxy","peerConnection:didAddReceiver:streams:",(IMP)hook_v3);
    Hook("HWLLSClientProxy","streamUrl",(IMP)hook_obj0);
    Hook("HWLLSClientProxy","localSDP",(IMP)hook_obj0);
    Hook("HWLLSClientProxy","remoteSDP",(IMP)hook_obj0);
    Hook("HWLLSClientProxy","playSignalingRequest",(IMP)hook_obj0);

    /* Exact WebRTC selectors discovered by V6.1 */
    Hook("RTCPeerConnection","addIceCandidate:",(IMP)hook_v1);
    Hook("RTCPeerConnection","addIceCandidate:completionHandler:",(IMP)hook_v2);

    /* Known IJK fallback selectors. V7 logs MISS safely if this build lacks one. */
    Hook("IJKFFMoviePlayerController","initWithContentURL:",(IMP)hook_obj1);
    Hook("IJKFFMoviePlayerController","initWithContentURL:withOptions:",(IMP)hook_obj2);
    Hook("IJKFFMoviePlayerController","initWithContentURLString:",(IMP)hook_obj1);
    Hook("IJKFFMoviePlayerController","initWithContentURLString:withOptions:",(IMP)hook_obj2);
    Hook("IJKFFMoviePlayerController","prepareToPlay",(IMP)hook_v0);
    Hook("IJKMediaUrlOpenData","setUrl:",(IMP)hook_v1);

    Log(@"========== V7 HOOKS READY ==========");
}

__attribute__((constructor))
static void V7Init(void) {
    @autoreleasepool {
        gLogQ=dispatch_queue_create("com.playurllogger.v7.log",DISPATCH_QUEUE_SERIAL);
        gOrig=[NSMutableDictionary dictionary];
        NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        gLogPath=[docs stringByAppendingPathComponent:@"PlayURLLoggerV7.txt"];
        Log(@"######## PLAYURLLOGGER V7 ACTIVE ########");
        Log(@"[SELF] bundle=%@ pid=%d",[NSBundle mainBundle].bundleIdentifier,getpid());

        /* No global runtime scan. Give app/frameworks time to finish loading. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(6*NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
            InstallHooks();
        });
    }
}
