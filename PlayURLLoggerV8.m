#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>

static dispatch_queue_t gLogQ;
static NSString *gLogPath;
static NSMutableDictionary<NSString*,NSValue*> *gOrig;

static NSString *Redact(NSString *s) {
    if (!s) return @"(null)";
    NSString *out=[s copy];
    NSArray *keys=@[@"txSecret",@"token",@"access_token",@"authorization",@"cookie",
                    @"password",@"secret",@"credential",@"signature",@"ice-pwd",@"ice-ufrag"];
    for(NSString *key in keys){
        NSString *p=[NSString stringWithFormat:@"(?i)(%@\\s*[:=]\\s*)[^&\\s\\\\r\\\\n]+",
                     [NSRegularExpression escapedPatternForString:key]];
        NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:p options:0 error:nil];
        out=[re stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0,out.length)
                                    withTemplate:@"$1<redacted>"];
    }
    return out;
}
static NSString *D(id x){ @try{return x?Redact([x description]):@"(nil)";}@catch(...){return @"<desc failed>";} }

static void L(NSString *fmt,...){
    va_list ap; va_start(ap,fmt);
    NSString *m=[[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
    dispatch_async(gLogQ?:dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSDateFormatter *df=[NSDateFormatter new]; df.dateFormat=@"HH:mm:ss.SSS";
        NSString *line=[NSString stringWithFormat:@"[%@] %@\n",[df stringFromDate:[NSDate date]],m];
        NSData *d=[line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if(!h){[d writeToFile:gLogPath atomically:YES];return;}
        [h seekToEndOfFile]; [h writeData:d]; [h closeFile];
    });
}

static NSString *Key(Class c,SEL s){return [NSString stringWithFormat:@"%@|%@",NSStringFromClass(c),NSStringFromSelector(s)];}
static IMP O(id self,SEL s){return (IMP)[gOrig[Key([self class],s)] pointerValue];}
static void Save(Class c,SEL s,IMP p){gOrig[Key(c,s)]=[NSValue valueWithPointer:p];}

static void V0(id self,SEL s){ L(@"[CALL] %@ -%@",NSStringFromClass([self class]),NSStringFromSelector(s)); void(*f)(id,SEL)=(void*)O(self,s);if(f)f(self,s); }
static void V1O(id self,SEL s,id a){ L(@"[CALL] %@ -%@ %@",NSStringFromClass([self class]),NSStringFromSelector(s),D(a)); void(*f)(id,SEL,id)=(void*)O(self,s);if(f)f(self,s,a); }
static void V2O(id self,SEL s,id a,id b){ L(@"[CALL] %@ -%@ a=%@ b=%@",NSStringFromClass([self class]),NSStringFromSelector(s),D(a),D(b)); void(*f)(id,SEL,id,id)=(void*)O(self,s);if(f)f(self,s,a,b); }
static void V1Q(id self,SEL s,NSInteger q){ L(@"[CALL] %@ -%@ value=%ld",NSStringFromClass([self class]),NSStringFromSelector(s),(long)q); void(*f)(id,SEL,NSInteger)=(void*)O(self,s);if(f)f(self,s,q); }
static BOOL B0(id self,SEL s){ BOOL(*f)(id,SEL)=(void*)O(self,s); BOOL r=f?f(self,s):NO; L(@"[STATE] %@ -%@ => %@",NSStringFromClass([self class]),NSStringFromSelector(s),r?@"YES":@"NO"); return r; }
static id O1(id self,SEL s,id a){ L(@"[CALL] %@ -%@ %@",NSStringFromClass([self class]),NSStringFromSelector(s),D(a)); id(*f)(id,SEL,id)=(void*)O(self,s); id r=f?f(self,s,a):nil; L(@"[RET] %@ -%@ => %@",NSStringFromClass([self class]),NSStringFromSelector(s),D(r));return r; }
static id O2(id self,SEL s,id a,id b){ L(@"[CALL] %@ -%@ a=%@ b=%@",NSStringFromClass([self class]),NSStringFromSelector(s),D(a),D(b)); id(*f)(id,SEL,id,id)=(void*)O(self,s); id r=f?f(self,s,a,b):nil; L(@"[RET] %@ -%@ => %@",NSStringFromClass([self class]),NSStringFromSelector(s),D(r));return r; }

static BOOL IsObj(const char *t){ while(*t && strchr("rnNoORV",*t))t++; return *t=='@'||*t=='#'; }
static char Ret(Method m){ const char *t=method_getTypeEncoding(m); while(*t && strchr("rnNoORV",*t))t++; return *t; }

static void HookIf(Class c,const char *sn,IMP imp,const char *tag){
    SEL s=sel_registerName(sn); Method m=class_getInstanceMethod(c,s);
    if(!m)return;
    IMP old=method_getImplementation(m); Save(c,s,old); method_setImplementation(m,imp);
    L(@"[HOOK/%s] %@ -%s type=%s",tag,NSStringFromClass(c),sn,method_getTypeEncoding(m));
}

/* Only hook when the runtime ABI matches the trampoline. */
static void SafeHook(Class c,const char *sn,const char *kind,const char *tag){
    SEL s=sel_registerName(sn); Method m=class_getInstanceMethod(c,s); if(!m)return;
    unsigned n=method_getNumberOfArguments(m); char r=Ret(m);
    char a2[128]={0},a3[128]={0}; if(n>2)method_getArgumentType(m,2,a2,sizeof(a2)); if(n>3)method_getArgumentType(m,3,a3,sizeof(a3));
    IMP imp=NULL;
    if(!strcmp(kind,"v0") && r=='v' && n==2) imp=(IMP)V0;
    else if(!strcmp(kind,"v1o") && r=='v' && n==3 && IsObj(a2)) imp=(IMP)V1O;
    else if(!strcmp(kind,"v2o") && r=='v' && n==4 && IsObj(a2)&&IsObj(a3)) imp=(IMP)V2O;
    else if(!strcmp(kind,"v1q") && r=='v' && n==3 && strchr("qQiIlLsScCB",a2[0])) imp=(IMP)V1Q;
    else if(!strcmp(kind,"b0") && strchr("Bc",r) && n==2) imp=(IMP)B0;
    else if(!strcmp(kind,"o1") && r=='@' && n==3 && IsObj(a2)) imp=(IMP)O1;
    else if(!strcmp(kind,"o2") && r=='@' && n==4 && IsObj(a2)&&IsObj(a3)) imp=(IMP)O2;
    if(imp) HookIf(c,sn,imp,tag);
    else L(@"[ABI-SKIP/%s] %@ -%s type=%s",tag,NSStringFromClass(c),sn,method_getTypeEncoding(m));
}

@interface NSURL(V8)
+ (instancetype)v8_URLWithString:(NSString*)s;
@end
@implementation NSURL(V8)
+ (void)load{
    Method a=class_getClassMethod(self,@selector(URLWithString:));
    Method b=class_getClassMethod(self,@selector(v8_URLWithString:));
    if(a&&b)method_exchangeImplementations(a,b);
}
+ (instancetype)v8_URLWithString:(NSString*)s{
    NSString *x=s.lowercaseString;
    if([x containsString:@"webrtc://"]||[x containsString:@".m3u8"]||[x containsString:@".flv"]||
       [x hasPrefix:@"rtmp://"]||[x hasPrefix:@"rtmps://"])
        L(@"[MEDIA] %@",Redact(s));
    return [self v8_URLWithString:s];
}
@end

static BOOL RelevantClass(NSString *n){
    return [n hasPrefix:@"HWLLS"] || [n hasPrefix:@"IJKFFMoviePlayer"] ||
           [n isEqualToString:@"IJKMediaUrlOpenData"];
}
static void Install(void){
    int total=objc_getClassList(NULL,0);
    __unsafe_unretained Class *cs=(__unsafe_unretained Class*)calloc((size_t)total,sizeof(Class));
    objc_getClassList(cs,total);
    L(@"========== V8 FALLBACK SCOUT INSTALL ==========");
    for(int i=0;i<total;i++){
        Class c=cs[i]; NSString *cn=NSStringFromClass(c); if(!RelevantClass(cn))continue;

        /* Playback entry / scheduler */
        SafeHook(c,"prepareStartPlay:","v1o","ENTRY");
        SafeHook(c,"startPlay:startPlayOptions:","v2o","ENTRY");
        SafeHook(c,"setStreamUrl:","v1o","ENTRY");
        SafeHook(c,"getDomainWithStreamUrl:","o1","ENTRY");

        /* Signaling objects/results; full SDP is not deliberately hooked here. */
        SafeHook(c,"playSignalingRequest","v0","SIGNAL");
        SafeHook(c,"playRequestWithDnsResult:","v1o","SIGNAL");
        SafeHook(c,"sendSignalingWithDnsResult:isStop:","v2o","SIGNAL");
        SafeHook(c,"playRequestResultDoingWithSdpResp:","v1o","SIGNAL");
        SafeHook(c,"pcDataPopulateDataWithDnsResult:sdpResp:","v2o","SIGNAL");

        /* Error / downgrade decision */
        SafeHook(c,"isNeedDowngrade","b0","FALLBACK");
        SafeHook(c,"setIsNeedDowngrade:","v1q","FALLBACK");
        SafeHook(c,"playNeedReplayWithErrorCode:","v1q","FALLBACK");
        SafeHook(c,"dealErrorCode:","v1q","FALLBACK");

        /* IJK fallback */
        SafeHook(c,"initWithContentURL:","o1","IJK");
        SafeHook(c,"initWithContentURL:withOptions:","o2","IJK");
        SafeHook(c,"initWithContentURLString:","o1","IJK");
        SafeHook(c,"initWithContentURLString:withOptions:","o2","IJK");
        SafeHook(c,"prepareToPlay","v0","IJK");
        SafeHook(c,"setUrl:","v1o","IJK");
    }
    free(cs);
    L(@"========== V8 READY ==========");
}

__attribute__((constructor))
static void Init(void){
 @autoreleasepool{
    gLogQ=dispatch_queue_create("PlayURLLoggerV8.log",DISPATCH_QUEUE_SERIAL);
    gOrig=[NSMutableDictionary dictionary];
    NSString *d=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    gLogPath=[d stringByAppendingPathComponent:@"PlayURLLoggerV8_Fallback.txt"];
    L(@"######## PLAYURLLOGGER V8 FALLBACK SCOUT ACTIVE ########");
    L(@"[SELF] bundle=%@ pid=%d",[NSBundle mainBundle].bundleIdentifier,getpid());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{Install();});
 }
}
