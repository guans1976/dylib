#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>

static dispatch_queue_t Q;
static NSString *P;
static NSMutableDictionary<NSString*,NSValue*> *ORIG;

static void L(NSString *f,...){
    va_list a; va_start(a,f); NSString *s=[[NSString alloc]initWithFormat:f arguments:a]; va_end(a);
    dispatch_async(Q?:dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSDateFormatter *d=[NSDateFormatter new]; d.dateFormat=@"HH:mm:ss.SSS";
        NSString *x=[NSString stringWithFormat:@"[%@] %@\n",[d stringFromDate:[NSDate date]],s];
        NSData *b=[x dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:P];
        if(!h){[b writeToFile:P atomically:YES];return;}
        [h seekToEndOfFile]; [h writeData:b]; [h closeFile];
    });
}
static NSString *Redact(NSString *s){
    if(!s)return @"(nil)";
    NSMutableString *m=[s mutableCopy];
    NSArray *ps=@[
      @"(?i)(txSecret=)[^&\\s>]+",@"(?i)(token=)[^&\\s>]+",
      @"(?i)(access_token=)[^&\\s>]+",@"(?i)(ice-pwd:)[^\\r\\n]+",
      @"(?i)(ice-ufrag:)[^\\r\\n]+",@"(?i)(fingerprint:)[^\\r\\n]+"
    ];
    for(NSString *p in ps){
      NSRegularExpression *r=[NSRegularExpression regularExpressionWithPattern:p options:0 error:nil];
      [r replaceMatchesInString:m options:0 range:NSMakeRange(0,m.length) withTemplate:@"$1<redacted>"];
    }
    return m;
}
static BOOL Sensitive(NSString *n){
    NSString *x=n.lowercaseString;
    for(NSString *k in @[@"sdp",@"token",@"secret",@"password",@"pwd",@"credential",@"authorization",
                         @"cookie",@"fingerprint",@"candidate",@"ip",@"address",@"host"])
        if([x containsString:k])return YES;
    return NO;
}
static NSString *K(Class c,SEL s){return [NSString stringWithFormat:@"%@|%@",NSStringFromClass(c),NSStringFromSelector(s)];}
static IMP O(id x,SEL s){return (IMP)[ORIG[K([x class],s)] pointerValue];}

static NSString *Scalar(id obj, SEL getter, const char *ret){
    @try{
      if(!strcmp(ret,"B")||!strcmp(ret,"c")) return ((BOOL(*)(id,SEL))objc_msgSend)(obj,getter)?@"YES":@"NO";
      if(strchr("qQiIlLsSC",ret[0])) return [NSString stringWithFormat:@"%lld",(long long)((int64_t(*)(id,SEL))objc_msgSend)(obj,getter)];
      if(ret[0]=='f') return [NSString stringWithFormat:@"%g",((float(*)(id,SEL))objc_msgSend)(obj,getter)];
      if(ret[0]=='d') return [NSString stringWithFormat:@"%g",((double(*)(id,SEL))objc_msgSend)(obj,getter)];
    }@catch(...){}
    return nil;
}
static void Inspect(id obj, NSString *tag){
    if(!obj){L(@"[%@] (nil)",tag);return;}
    Class c=[obj class]; L(@"[%@] class=%@",tag,NSStringFromClass(c));
    unsigned n=0; objc_property_t *ps=class_copyPropertyList(c,&n);
    for(unsigned i=0;i<n;i++){
        NSString *name=@(property_getName(ps[i]));
        if(Sensitive(name)){L(@"[%@] %@=<redacted/omitted>",tag,name);continue;}
        SEL g=NSSelectorFromString(name); if(![obj respondsToSelector:g])continue;
        Method m=class_getInstanceMethod(c,g); if(!m)continue;
        char rt[128]={0}; method_getReturnType(m,rt,sizeof(rt));
        @try{
          if(rt[0]=='@'){
            id v=((id(*)(id,SEL))objc_msgSend)(obj,g);
            if(!v){L(@"[%@] %@=(nil)",tag,name);}
            else if([v isKindOfClass:NSString.class]||[v isKindOfClass:NSNumber.class])
                L(@"[%@] %@=%@",tag,name,Redact([v description]));
            else
                L(@"[%@] %@=<%@>",tag,name,NSStringFromClass([v class]));
          }else{
            NSString *v=Scalar(obj,g,rt); if(v)L(@"[%@] %@=%@",tag,name,v);
          }
        }@catch(NSException *e){L(@"[%@] %@=<getter exception>",tag,name);}
    }
    free(ps);
}
static int HStart(id x,SEL s,id url,id opt){
    L(@"[ENTRY] %@ -%@ url=%@",NSStringFromClass([x class]),NSStringFromSelector(s),Redact([url description]));
    Inspect(opt,@"PLAY-OPTIONS");
    int(*f)(id,SEL,id,id)=(void*)O(x,s); int r=f?f(x,s,url,opt):-999;
    L(@"[ENTRY-RET] %d",r); return r;
}
static id HDNS(id x,SEL s,id dns){
    Inspect(dns,@"DNS-RESULT");
    id(*f)(id,SEL,id)=(void*)O(x,s); id r=f?f(x,s,dns):nil;
    Inspect(r,@"SIGNAL-RESP"); return r;
}
static id HSend(id x,SEL s,id dns,BOOL stop){
    L(@"[SIGNAL] stop=%@",stop?@"YES":@"NO"); Inspect(dns,@"DNS-RESULT");
    id(*f)(id,SEL,id,BOOL)=(void*)O(x,s); id r=f?f(x,s,dns,stop):nil;
    Inspect(r,@"SIGNAL-RESP"); return r;
}
static void Hook(Class c,const char*n,IMP h,const char*type){
    if(!c)return; SEL s=sel_registerName(n); Method m=class_getInstanceMethod(c,s); if(!m)return;
    const char*t=method_getTypeEncoding(m);
    if(strcmp(t,type)){L(@"[ABI-SKIP] %@ -%s actual=%s",NSStringFromClass(c),n,t);return;}
    ORIG[K(c,s)]=[NSValue valueWithPointer:method_getImplementation(m)];
    method_setImplementation(m,h); L(@"[HOOK] %@ -%s type=%s",NSStringFromClass(c),n,t);
}
static void Install(void){
    L(@"========== V10 OBJECT INSPECTOR INSTALL ==========");
    Class a=objc_getClass("HWLLSClient"), p=objc_getClass("HWLLSClientProxy");
    Hook(a,"startPlay:startPlayOptions:",(IMP)HStart,"i32@0:8@16@24");
    Hook(p,"startPlay:startPlayOptions:",(IMP)HStart,"i32@0:8@16@24");
    Hook(p,"playRequestWithDnsResult:",(IMP)HDNS,"@24@0:8@16");
    Hook(p,"sendSignalingWithDnsResult:isStop:",(IMP)HSend,"@28@0:8@16B24");
    L(@"========== V10 READY ==========");
}
__attribute__((constructor))static void Init(void){@autoreleasepool{
    Q=dispatch_queue_create("v10.object.inspector",DISPATCH_QUEUE_SERIAL);
    ORIG=[NSMutableDictionary dictionary];
    NSString*d=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    P=[d stringByAppendingPathComponent:@"PlayURLLoggerV10_Objects.txt"];
    L(@"######## V10 OBJECT INSPECTOR ACTIVE ########");
    L(@"[SELF] bundle=%@ pid=%d",[NSBundle mainBundle].bundleIdentifier,getpid());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{Install();});
}}
