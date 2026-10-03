#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *LP(void){
    NSString *d=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    return [d stringByAppendingPathComponent:@"V12_HWLLS_DowngradeInspector.log"];
}
static void L(NSString *s){
    NSData *b=[[NSString stringWithFormat:@"[%@] %@\n",NSDate.date,s] dataUsingEncoding:NSUTF8StringEncoding];
    NSString *p=LP(); NSFileHandle*h=[NSFileHandle fileHandleForWritingAtPath:p];
    if(!h){[b writeToFile:p atomically:YES];return;} [h seekToEndOfFile];[h writeData:b];[h closeFile];
}
static NSString *Safe(id v){
    if(!v) return @"<nil>";
    NSString *s=[v description]?:@"";
    // Never log complete URLs/query strings or network credentials.
    if([s containsString:@"://"] || [s containsString:@"txSecret"] || [s containsString:@"txTime"] ||
       [s containsString:@"password"] || [s containsString:@"token"] || [s containsString:@"signature"])
        return @"<redacted-url-or-secret>";
    return s.length>300 ? [[s substringToIndex:300] stringByAppendingString:@"…"] : s;
}
static void Inspect(id o, NSString *tag){
    if(!o){L([NSString stringWithFormat:@"%@ <nil>",tag]);return;}
    L([NSString stringWithFormat:@"%@ class=%@",tag,NSStringFromClass([o class])]);
    unsigned n=0; objc_property_t *ps=class_copyPropertyList([o class],&n);
    for(unsigned i=0;i<n;i++){
        NSString *k=@(property_getName(ps[i]));
        NSString *lk=k.lowercaseString;
        if([lk containsString:@"url"]||[lk containsString:@"downgrade"]||[lk containsString:@"policy"]||
           [lk containsString:@"domain"]||[lk containsString:@"stream"]||[lk containsString:@"auto"]){
            @try { id v=[o valueForKey:k]; L([NSString stringWithFormat:@"  %@=%@",k,Safe(v)]); } @catch(...) {}
        }
    } free(ps);
}
static IMP oldStartClient, oldStartProxy, oldPrepare;
static int StartClient(id self,SEL _cmd,id url,id opt){
    L(@"HWLLSClient startPlay"); Inspect(opt,@"StartPlayOptions");
    int r=((int(*)(id,SEL,id,id))oldStartClient)(self,_cmd,url,opt);
    L([NSString stringWithFormat:@"HWLLSClient startPlay => %d",r]); return r;
}
static int StartProxy(id self,SEL _cmd,id url,id opt){
    L(@"HWLLSClientProxy startPlay"); Inspect(opt,@"Proxy StartPlayOptions");
    int r=((int(*)(id,SEL,id,id))oldStartProxy)(self,_cmd,url,opt);
    Inspect(self,@"Proxy after start"); L([NSString stringWithFormat:@"HWLLSClientProxy startPlay => %d",r]); return r;
}
static void Prepare(id self,SEL _cmd,id x){
    L(@"HWLLSClientProxy prepareStartPlay"); Inspect(self,@"Proxy before prepare");
    ((void(*)(id,SEL,id))oldPrepare)(self,_cmd,x);
    Inspect(self,@"Proxy after prepare");
}
static void Hook(Class c, SEL s, IMP imp, IMP *old){
    Method m=c?class_getInstanceMethod(c,s):NULL;
    if(!m){L([NSString stringWithFormat:@"MISS %@ %@",NSStringFromClass(c),NSStringFromSelector(s)]);return;}
    *old=method_getImplementation(m); method_setImplementation(m,imp);
    L([NSString stringWithFormat:@"HOOK %@ %@ type=%s",NSStringFromClass(c),NSStringFromSelector(s),method_getTypeEncoding(m)]);
}
static void EnumerateInteresting(Class c){
    if(!c)return; unsigned n=0; Method *ms=class_copyMethodList(c,&n);
    L([NSString stringWithFormat:@"METHODS %@ count=%u",NSStringFromClass(c),n]);
    for(unsigned i=0;i<n;i++){
        NSString *s=NSStringFromSelector(method_getName(ms[i])); NSString *x=s.lowercaseString;
        if([x containsString:@"downgrade"]||[x containsString:@"url"]||[x containsString:@"policy"]||
           [x containsString:@"domain"]||[x containsString:@"play"]||[x containsString:@"stream"])
            L([NSString stringWithFormat:@"  %@  %s",s,method_getTypeEncoding(ms[i])]);
    } free(ms);
}
__attribute__((constructor)) static void Init(void){ @autoreleasepool {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),
      dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        L(@"V12 ready");
        Class a=objc_getClass("HWLLSClient"), b=objc_getClass("HWLLSClientProxy");
        EnumerateInteresting(a); EnumerateInteresting(b);
        Hook(a,@selector(startPlay:startPlayOptions:),(IMP)StartClient,&oldStartClient);
        Hook(b,@selector(startPlay:startPlayOptions:),(IMP)StartProxy,&oldStartProxy);
        Hook(b,@selector(prepareStartPlay:),(IMP)Prepare,&oldPrepare);
      });
}}
