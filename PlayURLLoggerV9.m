#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>

static dispatch_queue_t Q;
static NSString *P;
static NSMutableDictionary<NSString*,NSValue*> *IMPS;

static NSString *clean(NSString *s){
    if(!s)return @"(null)";
    NSMutableString *m=[s mutableCopy];
    NSArray *patterns=@[
      @"(?i)(txSecret=)[^&\\s>]+",
      @"(?i)(access_token=)[^&\\s>]+",
      @"(?i)(token=)[^&\\s>]+",
      @"(?i)(authorization\\s*[:=]\\s*)[^\\r\\n]+",
      @"(?i)(cookie\\s*[:=]\\s*)[^\\r\\n]+",
      @"(?i)(ice-pwd:)[^\\r\\n]+",
      @"(?i)(ice-ufrag:)[^\\r\\n]+"
    ];
    for(NSString *p in patterns){
        NSRegularExpression *r=[NSRegularExpression regularExpressionWithPattern:p options:0 error:nil];
        [r replaceMatchesInString:m options:0 range:NSMakeRange(0,m.length) withTemplate:@"$1<redacted>"];
    }
    return m;
}
static NSString *desc(id x){ @try{return x?clean([x description]):@"(nil)";}@catch(...){return @"<desc failed>";} }
static void logx(NSString *f,...){
    va_list a;va_start(a,f);NSString *s=[[NSString alloc]initWithFormat:f arguments:a];va_end(a);
    dispatch_async(Q?:dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSDateFormatter *d=[NSDateFormatter new];d.dateFormat=@"HH:mm:ss.SSS";
        NSString *l=[NSString stringWithFormat:@"[%@] %@\n",[d stringFromDate:[NSDate date]],s];
        NSData *b=[l dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:P];
        if(!h){[b writeToFile:P atomically:YES];return;}
        [h seekToEndOfFile];[h writeData:b];[h closeFile];
    });
}
static NSString *key(Class c,SEL s){return [NSString stringWithFormat:@"%@|%@",NSStringFromClass(c),NSStringFromSelector(s)];}
static IMP old(id x,SEL s){return (IMP)[IMPS[key([x class],s)] pointerValue];}
static void save(Class c,SEL s,IMP p){IMPS[key(c,s)]=[NSValue valueWithPointer:p];}

/* exact ABIs learned from V8 */
static int H_start(id x,SEL s,id url,id opt){
    logx(@"[ENTRY] %@ -%@ url=%@ options=%@",NSStringFromClass([x class]),NSStringFromSelector(s),desc(url),desc(opt));
    int(*f)(id,SEL,id,id)=(void*)old(x,s); int r=f?f(x,s,url,opt):-999;
    logx(@"[ENTRY-RET] %@ -%@ => %d",NSStringFromClass([x class]),NSStringFromSelector(s),r); return r;
}
static id H_obj0(id x,SEL s){
    logx(@"[SIGNAL] %@ -%@",NSStringFromClass([x class]),NSStringFromSelector(s));
    id(*f)(id,SEL)=(void*)old(x,s);id r=f?f(x,s):nil;
    logx(@"[SIGNAL-RET] %@ -%@ => %@",NSStringFromClass([x class]),NSStringFromSelector(s),desc(r));return r;
}
static id H_obj1(id x,SEL s,id a){
    logx(@"[SIGNAL] %@ -%@ arg=%@",NSStringFromClass([x class]),NSStringFromSelector(s),desc(a));
    id(*f)(id,SEL,id)=(void*)old(x,s);id r=f?f(x,s,a):nil;
    logx(@"[SIGNAL-RET] %@ -%@ => %@",NSStringFromClass([x class]),NSStringFromSelector(s),desc(r));return r;
}
static id H_obj_bool(id x,SEL s,id a,BOOL b){
    logx(@"[SIGNAL] %@ -%@ dns=%@ stop=%@",NSStringFromClass([x class]),NSStringFromSelector(s),desc(a),b?@"YES":@"NO");
    id(*f)(id,SEL,id,BOOL)=(void*)old(x,s);id r=f?f(x,s,a,b):nil;
    logx(@"[SIGNAL-RET] %@ -%@ => %@",NSStringFromClass([x class]),NSStringFromSelector(s),desc(r));return r;
}
static BOOL H_replay(id x,SEL s,int64_t e){
    BOOL(*f)(id,SEL,int64_t)=(void*)old(x,s);BOOL r=f?f(x,s,e):NO;
    logx(@"[DECISION] %@ -%@ error=%lld => replay=%@",NSStringFromClass([x class]),NSStringFromSelector(s),(long long)e,r?@"YES":@"NO");return r;
}
static void H_error_obj(id x,SEL s,id e){
    logx(@"[ERROR] %@ -%@ error=%@",NSStringFromClass([x class]),NSStringFromSelector(s),desc(e));
    void(*f)(id,SEL,id)=(void*)old(x,s);if(f)f(x,s,e);
}
static BOOL H_down(id x,SEL s){
    BOOL(*f)(id,SEL)=(void*)old(x,s);BOOL r=f?f(x,s):NO;
    logx(@"[DECISION] %@ -%@ => downgrade=%@",NSStringFromClass([x class]),NSStringFromSelector(s),r?@"YES":@"NO");return r;
}
static void H_setdown(id x,SEL s,BOOL b){
    logx(@"[DECISION] %@ -%@ %@",NSStringFromClass([x class]),NSStringFromSelector(s),b?@"YES":@"NO");
    void(*f)(id,SEL,BOOL)=(void*)old(x,s);if(f)f(x,s,b);
}
static id H_ijk2(id x,SEL s,id u,id o){
    logx(@"[FALLBACK-IJK] %@ -%@ url=%@ options=%@",NSStringFromClass([x class]),NSStringFromSelector(s),desc(u),desc(o));
    id(*f)(id,SEL,id,id)=(void*)old(x,s);return f?f(x,s,u,o):nil;
}
static void H_v0(id x,SEL s){logx(@"[FALLBACK-IJK] %@ -%@",NSStringFromClass([x class]),NSStringFromSelector(s));void(*f)(id,SEL)=(void*)old(x,s);if(f)f(x,s);}
static void H_v1(id x,SEL s,id a){logx(@"[FALLBACK-IJK] %@ -%@ %@",NSStringFromClass([x class]),NSStringFromSelector(s),desc(a));void(*f)(id,SEL,id)=(void*)old(x,s);if(f)f(x,s,a);}

static void hook(Class c,const char *n,IMP h,const char *expected){
    if(!c)return;SEL s=sel_registerName(n);Method m=class_getInstanceMethod(c,s);if(!m)return;
    const char *t=method_getTypeEncoding(m);
    if(expected && strcmp(t,expected)){logx(@"[ABI-SKIP] %@ -%s actual=%s expected=%s",NSStringFromClass(c),n,t,expected);return;}
    save(c,s,method_getImplementation(m));method_setImplementation(m,h);
    logx(@"[HOOK] %@ -%s type=%s",NSStringFromClass(c),n,t);
}
@interface NSURL(V9)
+(instancetype)v9_URLWithString:(NSString*)s;
@end
@implementation NSURL(V9)
+(void)load{Method a=class_getClassMethod(self,@selector(URLWithString:)),b=class_getClassMethod(self,@selector(v9_URLWithString:));if(a&&b)method_exchangeImplementations(a,b);}
+(instancetype)v9_URLWithString:(NSString*)s{
 NSString *l=s.lowercaseString;
 if([l containsString:@"webrtc://"]||[l containsString:@".m3u8"]||[l containsString:@".flv"]||[l hasPrefix:@"rtmp://"]||[l hasPrefix:@"rtmps://"])logx(@"[MEDIA] %@",clean(s));
 return [self v9_URLWithString:s];
}
@end

static void install(void){
 logx(@"========== V9 INSTALL ==========");
 Class a=objc_getClass("HWLLSClient"),p=objc_getClass("HWLLSClientProxy");
 hook(a,"startPlay:startPlayOptions:",(IMP)H_start,"i32@0:8@16@24");
 hook(p,"startPlay:startPlayOptions:",(IMP)H_start,"i32@0:8@16@24");
 hook(p,"playSignalingRequest",(IMP)H_obj0,"@16@0:8");
 hook(p,"playRequestWithDnsResult:",(IMP)H_obj1,"@24@0:8@16");
 hook(p,"sendSignalingWithDnsResult:isStop:",(IMP)H_obj_bool,"@28@0:8@16B24");
 hook(p,"playNeedReplayWithErrorCode:",(IMP)H_replay,"B24@0:8q16");
 hook(p,"dealErrorCode:",(IMP)H_error_obj,"v24@0:8@16");
 hook(p,"isNeedDowngrade",(IMP)H_down,"B16@0:8");
 hook(p,"setIsNeedDowngrade:",(IMP)H_setdown,"v20@0:8B16");

 Class ijk=objc_getClass("IJKFFMoviePlayerController"),ud=objc_getClass("IJKMediaUrlOpenData");
 hook(ijk,"initWithContentURL:withOptions:",(IMP)H_ijk2,"@32@0:8@16@24");
 hook(ijk,"initWithContentURLString:withOptions:",(IMP)H_ijk2,"@32@0:8@16@24");
 hook(ijk,"prepareToPlay",(IMP)H_v0,"v16@0:8");
 hook(ud,"setUrl:",(IMP)H_v1,"v24@0:8@16");
 logx(@"========== V9 READY ==========");
}
__attribute__((constructor))static void initv9(void){@autoreleasepool{
 Q=dispatch_queue_create("v9.playback.decision.log",DISPATCH_QUEUE_SERIAL);
 IMPS=[NSMutableDictionary dictionary];
 NSString *d=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
 P=[d stringByAppendingPathComponent:@"PlayURLLoggerV9_Decision.txt"];
 logx(@"######## V9 PLAYBACK DECISION TRACE ACTIVE ########");
 logx(@"[SELF] bundle=%@ pid=%d",[NSBundle mainBundle].bundleIdentifier,getpid());
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{install();});
}}
