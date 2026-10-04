#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static dispatch_queue_t gQ;
static NSString *gJSONPath, *gLogPath;
static NSMutableDictionary<NSString*,NSValue*> *gOrig;
static BOOL gInstalled = NO;

static void Log(NSString *s) {
    dispatch_async(gQ, ^{
        NSString *line=[NSString stringWithFormat:@"[%@] %@\n", NSDate.date, s ?: @""];
        NSData *d=[line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if(h){[h seekToEndOfFile];[h writeData:d];[h closeFile];}
        else [d writeToFile:gLogPath atomically:YES];
    });
}
static NSString *Key(Class c, SEL s) {
    return [NSString stringWithFormat:@"%@|%@",NSStringFromClass(c),NSStringFromSelector(s)];
}
static IMP Original(id self, SEL s) {
    return (IMP)[gOrig[Key([self class],s)] pointerValue];
}
static NSString *URLString(id obj) {
    if([obj isKindOfClass:NSURL.class]) return [(NSURL*)obj absoluteString] ?: @"";
    if([obj isKindOfClass:NSString.class]) return (NSString*)obj;
    return @"";
}
static BOOL IsPreviewFLV(NSString *s) {
    if(!s.length) return NO;
    NSURLComponents *c=[NSURLComponents componentsWithString:s];
    NSString *host=c.host.lowercaseString ?: @"";
    NSString *path=c.path.lowercaseString ?: @"";
    return ([c.scheme.lowercaseString isEqualToString:@"http"] ||
            [c.scheme.lowercaseString isEqualToString:@"https"]) &&
           [host isEqualToString:@"api.qituoc.com"] &&
           [path containsString:@"/preview/"] &&
           [path hasSuffix:@".flv"];
}
static NSString *RedactedShape(NSString *s) {
    NSURLComponents *c=[NSURLComponents componentsWithString:s];
    if(!c) return @"<invalid-url>";
    return [NSString stringWithFormat:@"%@://%@/preview/<redacted>/<redacted>.flv",
            c.scheme ?: @"https", c.host ?: @"<host>"];
}
static void ExportPreview(NSString *url, NSString *source) {
    if(!IsPreviewFLV(url)) return;
    NSDictionary *r=@{
        @"schema":@"paid-preview-v1",
        @"status":@"ready",
        @"page_type":@"preview",
        @"source":source ?: @"ijk",
        @"playback_type":@"http_flv",
        @"media_url":url,
        @"updated_at_ms":@((long long)(NSDate.date.timeIntervalSince1970*1000))
    };
    dispatch_async(gQ, ^{
        NSError *e=nil;
        NSData *d=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:&e];
        BOOL ok=d && [d writeToFile:gJSONPath options:NSDataWritingAtomic error:&e];
        Log([NSString stringWithFormat:@"EXPORT %@ source=%@ url=%@",
             ok?@"ready":@"failed",source,RedactedShape(url)]);
    });
}

static id HookObj1(id self, SEL cmd, id a) {
    NSString *u=URLString(a);
    if(IsPreviewFLV(u)) ExportPreview(u,NSStringFromSelector(cmd));
    id(*f)(id,SEL,id)=(void*)Original(self,cmd);
    return f?f(self,cmd,a):nil;
}
static id HookObj2(id self, SEL cmd, id a, id b) {
    NSString *u=URLString(a);
    if(IsPreviewFLV(u)) ExportPreview(u,NSStringFromSelector(cmd));
    id(*f)(id,SEL,id,id)=(void*)Original(self,cmd);
    return f?f(self,cmd,a,b):nil;
}
static void HookVoid1(id self, SEL cmd, id a) {
    NSString *u=URLString(a);
    if(IsPreviewFLV(u)) ExportPreview(u,NSStringFromSelector(cmd));
    void(*f)(id,SEL,id)=(void*)Original(self,cmd);
    if(f) f(self,cmd,a);
}
static BOOL Hook(const char *cn,const char *sn,IMP replacement) {
    Class c=objc_getClass(cn); if(!c) return NO;
    SEL s=sel_registerName(sn);
    Method m=class_getInstanceMethod(c,s); if(!m) return NO;
    NSString *k=Key(c,s);
    if(gOrig[k]) return YES;
    gOrig[k]=[NSValue valueWithPointer:method_getImplementation(m)];
    method_setImplementation(m,replacement);
    Log([NSString stringWithFormat:@"HOOK %s -%s",cn,sn]);
    return YES;
}
static void Install(unsigned attempt) {
    if(gInstalled) return;
    int n=0;
    n += Hook("IJKFFMoviePlayerController","initWithContentURL:",(IMP)HookObj1);
    n += Hook("IJKFFMoviePlayerController","initWithContentURL:withOptions:",(IMP)HookObj2);
    n += Hook("IJKFFMoviePlayerController","initWithContentURLString:",(IMP)HookObj1);
    n += Hook("IJKFFMoviePlayerController","initWithContentURLString:withOptions:",(IMP)HookObj2);
    n += Hook("IJKMediaUrlOpenData","setUrl:",(IMP)HookVoid1);
    if(n>0){gInstalled=YES;Log([NSString stringWithFormat:@"READY hooks=%d",n]);return;}
    if(attempt<30) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),
        dispatch_get_main_queue(),^{Install(attempt+1);});
    else Log(@"HOOK_MISSING IJK classes/methods");
}
__attribute__((constructor))
static void Init(void) {@autoreleasepool{
    gQ=dispatch_queue_create("paid.preview.v1",DISPATCH_QUEUE_SERIAL);
    gOrig=[NSMutableDictionary dictionary];
    NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    gJSONPath=[docs stringByAppendingPathComponent:@"preview_playback.json"];
    gLogPath=[docs stringByAppendingPathComponent:@"PaidPreviewV1.log"];
    NSData *d=[NSJSONSerialization dataWithJSONObject:@{
        @"schema":@"paid-preview-v1",@"status":@"waiting",
        @"page_type":@"preview",@"playback_type":@"http_flv"
    } options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToFile:gJSONPath atomically:YES];
    Log(@"PaidPreviewV1 active");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),
                   dispatch_get_main_queue(),^{Install(0);});
}}
