#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <unistd.h>

static dispatch_queue_t gLogQ, gScanQ;
static NSMutableSet *gSeenClasses, *gSeenImages;
static NSString *LogPath(void){
    NSString *d=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    return [d stringByAppendingPathComponent:@"PlayURLLoggerV6_Runtime.txt"];
}
static NSString *TS(void){
    static NSDateFormatter *f; static dispatch_once_t once;
    dispatch_once(&once, ^{ f=[NSDateFormatter new]; f.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.dateFormat=@"yyyy-MM-dd HH:mm:ss.SSS Z"; });
    return [f stringFromDate:[NSDate date]];
}
static void Log(NSString *s){
    if(!s.length) return;
    NSString *line=[NSString stringWithFormat:@"[%@] %@\n",TS(),s];
    dispatch_async(gLogQ ?: dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSData *d=[line dataUsingEncoding:NSUTF8StringEncoding]; NSString *p=LogPath();
        if(![[NSFileManager defaultManager] fileExistsAtPath:p]){ [d writeToFile:p atomically:YES]; return; }
        NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:p]; if(!h)return;
        @try { [h seekToEndOfFile]; [h writeData:d]; } @catch(__unused NSException *e) {} [h closeFile];
    });
}
static NSString *Redact(NSString *s){
    if(!s) return @"<nil>"; NSMutableString *m=[s mutableCopy];
    NSArray *keys=@[@"txSecret",@"token",@"access_token",@"authorization",@"cookie",@"password",@"secret",@"credential",@"signature"];
    for(NSString *k in keys){
        NSString *pat=[NSString stringWithFormat:@"(?i)(%@\\s*[=:]\\s*)([^&\\s,;\\\"}]+)",[NSRegularExpression escapedPatternForString:k]];
        NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
        [re replaceMatchesInString:m options:0 range:NSMakeRange(0,m.length) withTemplate:@"$1<redacted>"];
    }
    return m;
}

@interface NSURL(PULV61) @end
@implementation NSURL(PULV61)
+ (void)load {
    Method a=class_getClassMethod(self,@selector(URLWithString:));
    Method b=class_getClassMethod(self,@selector(p61_URLWithString:));
    if(a&&b) method_exchangeImplementations(a,b);
}
+ (instancetype)p61_URLWithString:(NSString*)s {
    if(s.length) Log([NSString stringWithFormat:@"[URL] %@",Redact(s)]);
    return [self p61_URLWithString:s];
}
@end

static BOOL Interesting(NSString *s){
    NSString *x=s.lowercaseString;
    NSArray *k=@[@"webrtc",@"peerconnection",@"rtcpeer",@"hwlls",@"llsplayer",@"signaling",@"candidate",@"sdp",@"ice",@"stream",@"ijk",@"ffmpeg",@"trtc"];
    for(NSString *q in k) if([x containsString:q]) return YES;
    return NO;
}
static void DumpMethods(Class c){
    unsigned int n=0; Method *ms=class_copyMethodList(c,&n);
    for(unsigned int i=0;i<n;i++){
        NSString *s=NSStringFromSelector(method_getName(ms[i]));
        if(Interesting(s)) Log([NSString stringWithFormat:@"[METHOD] %@ -%@ type=%s",NSStringFromClass(c),s,method_getTypeEncoding(ms[i])?:"?"]);
    }
    free(ms); n=0; Class meta=object_getClass(c); ms=class_copyMethodList(meta,&n);
    for(unsigned int i=0;i<n;i++){
        NSString *s=NSStringFromSelector(method_getName(ms[i]));
        if(Interesting(s)) Log([NSString stringWithFormat:@"[METHOD] %@ +%@ type=%s",NSStringFromClass(c),s,method_getTypeEncoding(ms[i])?:"?"]);
    }
    free(ms);
}
static void ScanImages(void){
    uint32_t n=_dyld_image_count();
    for(uint32_t i=0;i<n;i++){
        const char *p=_dyld_get_image_name(i); if(!p)continue;
        NSString *s=[NSString stringWithUTF8String:p]; if(!Interesting(s)||[gSeenImages containsObject:s])continue;
        [gSeenImages addObject:s]; Log([NSString stringWithFormat:@"[IMAGE] %@",s]);
    }
}
static void ScanClasses(void){
    int total=objc_getClassList(NULL,0); if(total<=0)return;
    __unsafe_unretained Class *cs =
        (__unsafe_unretained Class *)calloc((size_t)total, sizeof(Class)); if(!cs)return;
    int got=objc_getClassList(cs,total); Log([NSString stringWithFormat:@"[CLASS COUNT] %d",got]);
    for(int i=0;i<got;i++){
        @autoreleasepool {
            Class c=cs[i]; NSString *name=NSStringFromClass(c);
            if(!Interesting(name)||[gSeenClasses containsObject:name])continue;
            [gSeenClasses addObject:name]; const char *img=class_getImageName(c);
            Log([NSString stringWithFormat:@"[CLASS] %@ image=%s",name,img?:"?"]); DumpMethods(c);
        }
        if((i % 250)==249) usleep(2000); // yield briefly; scanner never runs on main queue
    }
    free(cs);
}
static void RunScan(NSString *reason){
    dispatch_async(gScanQ, ^{ @autoreleasepool { Log([NSString stringWithFormat:@"[SCAN BEGIN] %@",reason]); ScanImages(); ScanClasses(); Log([NSString stringWithFormat:@"[SCAN END] %@",reason]); } });
}
static void ImageAdded(const struct mach_header *mh, intptr_t slide){
    (void)mh; (void)slide;
    // dyld callback must stay tiny. Do not enumerate runtime here.
    static int pending=0;
    if(__sync_bool_compare_and_swap(&pending,0,1)){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),gScanQ,^{ pending=0; @autoreleasepool { ScanImages(); ScanClasses(); } });
    }
}
__attribute__((constructor)) static void InitV61(void){
    gLogQ=dispatch_queue_create("pul.v61.log",DISPATCH_QUEUE_SERIAL);
    gScanQ=dispatch_queue_create("pul.v61.scan",DISPATCH_QUEUE_SERIAL);
    gSeenClasses=[NSMutableSet set]; gSeenImages=[NSMutableSet set];
    Log(@"######## PLAYURLLOGGER V6.1 ACTIVE ########");
    Dl_info info={0}; if(dladdr((const void *)&InitV61,&info)&&info.dli_fname) Log([NSString stringWithFormat:@"[SELF] dylib=%s",info.dli_fname]);
    Log([NSString stringWithFormat:@"[SELF] bundle=%@ pid=%d",NSBundle.mainBundle.bundleIdentifier ?: @"?",getpid()]);
    _dyld_register_func_for_add_image(ImageAdded);
    // No runtime enumeration during startup. First scan after 8 seconds, off-main-thread.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),gScanQ,^{ @autoreleasepool { Log(@"[SCAN BEGIN] t+8s"); ScanImages(); ScanClasses(); Log(@"[SCAN END] t+8s"); } });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),gScanQ,^{ @autoreleasepool { Log(@"[SCAN BEGIN] t+20s"); ScanImages(); ScanClasses(); Log(@"[SCAN END] t+20s"); } });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,40*NSEC_PER_SEC),gScanQ,^{ @autoreleasepool { Log(@"[SCAN BEGIN] t+40s"); ScanImages(); ScanClasses(); Log(@"[SCAN END] t+40s"); } });
}
