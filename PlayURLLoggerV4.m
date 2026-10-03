#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *LogPath(void) {
    NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    return [docs stringByAppendingPathComponent:@"PlayURLLoggerV4.txt"];
}
static void Log(NSString *s) {
    if(!s.length) return;
    NSString *line=[NSString stringWithFormat:@"[%@] %@\n",[NSDate date],s];
    NSData *d=[line dataUsingEncoding:NSUTF8StringEncoding];
    @synchronized([NSFileHandle class]) {
        NSString *p=LogPath();
        if(![[NSFileManager defaultManager] fileExistsAtPath:p]) { [d writeToFile:p atomically:YES]; return; }
        NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:p];
        [h seekToEndOfFile]; [h writeData:d]; [h closeFile];
    }
}
static NSString *Desc(id x) {
    if(!x) return @"<nil>";
    @try { return [x description] ?: @"<no description>"; }
    @catch(...) { return @"<description threw>"; }
}
static void Stack(NSString *tag) {
    NSArray *a=[NSThread callStackSymbols];
    NSUInteger n=MIN((NSUInteger)12,a.count);
    for(NSUInteger i=0;i<n;i++) Log([NSString stringWithFormat:@"[%@ STACK %02lu] %@",tag,(unsigned long)i,a[i]]);
}

// Keep V3's Foundation observation, but V4 logs all NSURL strings so API/signaling URLs are not filtered out.
@interface NSURL (PULV4) @end
@implementation NSURL (PULV4)
+ (void)load {
    Method a=class_getClassMethod(self,@selector(URLWithString:));
    Method b=class_getClassMethod(self,@selector(pul4_URLWithString:));
    if(a&&b) method_exchangeImplementations(a,b);
}
+ (instancetype)pul4_URLWithString:(NSString *)s {
    if(s.length) Log([NSString stringWithFormat:@"[NSURL URLWithString] %@",s]);
    return [self pul4_URLWithString:s];
}
@end

static IMP origHWSetStreamURL = NULL;
static void hookHWSetStreamURL(id self, SEL _cmd, id value) {
    Log([NSString stringWithFormat:@"[HWLLS setStreamUrl:] %@",Desc(value)]);
    Stack(@"HWLLS");
    if(origHWSetStreamURL) ((void(*)(id,SEL,id))origHWSetStreamURL)(self,_cmd,value);
}

static IMP origIJKInitString = NULL;
static id hookIJKInitString(id self, SEL _cmd, id value) {
    Log([NSString stringWithFormat:@"[IJK initWithContentURLString:] %@",Desc(value)]);
    Stack(@"IJK");
    return origIJKInitString ? ((id(*)(id,SEL,id))origIJKInitString)(self,_cmd,value) : self;
}
static IMP origIJKInitStringOptions = NULL;
static id hookIJKInitStringOptions(id self, SEL _cmd, id value, id options) {
    Log([NSString stringWithFormat:@"[IJK initWithContentURLString:withOptions:] URL=%@ OPTIONS=%@",Desc(value),Desc(options)]);
    Stack(@"IJK");
    return origIJKInitStringOptions ? ((id(*)(id,SEL,id,id))origIJKInitStringOptions)(self,_cmd,value,options) : self;
}
static IMP origIJKInitURL = NULL;
static id hookIJKInitURL(id self, SEL _cmd, id value) {
    Log([NSString stringWithFormat:@"[IJK initWithContentURL:] %@",Desc(value)]);
    Stack(@"IJK");
    return origIJKInitURL ? ((id(*)(id,SEL,id))origIJKInitURL)(self,_cmd,value) : self;
}
static IMP origIJKInitURLOptions = NULL;
static id hookIJKInitURLOptions(id self, SEL _cmd, id value, id options) {
    Log([NSString stringWithFormat:@"[IJK initWithContentURL:withOptions:] URL=%@ OPTIONS=%@",Desc(value),Desc(options)]);
    Stack(@"IJK");
    return origIJKInitURLOptions ? ((id(*)(id,SEL,id,id))origIJKInitURLOptions)(self,_cmd,value,options) : self;
}

static BOOL HookInstanceMethod(Class c, SEL s, IMP replacement, IMP *old, NSString *label) {
    if(!c) return NO;
    Method m=class_getInstanceMethod(c,s);
    if(!m) return NO;
    IMP now=method_getImplementation(m);
    if(now==replacement) return YES;
    if(old && !*old) *old=now;
    method_setImplementation(m,replacement);
    Log([NSString stringWithFormat:@"[HOOKED] %@ %@",NSStringFromClass(c),label]);
    return YES;
}

static void InstallHooks(void) {
    Class hw=objc_getClass("HWLLSPlayer");
    if(hw) HookInstanceMethod(hw,NSSelectorFromString(@"setStreamUrl:"),(IMP)hookHWSetStreamURL,&origHWSetStreamURL,@"setStreamUrl:");

    Class ijk=objc_getClass("IJKFFMoviePlayerController");
    if(ijk) {
        HookInstanceMethod(ijk,NSSelectorFromString(@"initWithContentURLString:"),(IMP)hookIJKInitString,&origIJKInitString,@"initWithContentURLString:");
        HookInstanceMethod(ijk,NSSelectorFromString(@"initWithContentURLString:withOptions:"),(IMP)hookIJKInitStringOptions,&origIJKInitStringOptions,@"initWithContentURLString:withOptions:");
        HookInstanceMethod(ijk,NSSelectorFromString(@"initWithContentURL:"),(IMP)hookIJKInitURL,&origIJKInitURL,@"initWithContentURL:");
        HookInstanceMethod(ijk,NSSelectorFromString(@"initWithContentURL:withOptions:"),(IMP)hookIJKInitURLOptions,&origIJKInitURLOptions,@"initWithContentURL:withOptions:");
    }
}

__attribute__((constructor)) static void Init(void) {
    Log(@"[INIT] PlayURLLoggerV4 loaded");
    InstallHooks();
    // Retry because some embedded frameworks/classes may register after this dylib constructor runs.
    for(int i=1;i<=12;i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(i*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ InstallHooks(); });
    }
}
