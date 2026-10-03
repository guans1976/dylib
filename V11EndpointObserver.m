#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>

static NSString *gJSON;
static dispatch_queue_t gQ;

static BOOL IsRecordable(NSString *s) {
    NSString *x=s.lowercaseString;
    return [x hasPrefix:@"rtmp://"] || [x hasPrefix:@"rtmps://"] ||
           [x containsString:@".m3u8"] || [x containsString:@".flv"];
}
static NSString *Proto(NSString *s) {
    NSString *x=s.lowercaseString;
    if([x containsString:@".m3u8"]) return @"hls";
    if([x containsString:@".flv"]) return @"http-flv";
    if([x hasPrefix:@"rtmp://"]||[x hasPrefix:@"rtmps://"]) return @"rtmp";
    return @"unknown";
}
static void WriteInfo(NSString *status, NSString *url, NSString *source) {
    if(!gJSON) return;
    dispatch_async(gQ, ^{
        NSMutableDictionary *d=[NSMutableDictionary dictionary];
        d[@"status"]=status ?: @"unknown";
        d[@"updated_at_ms"]=@((long long)(NSDate.date.timeIntervalSince1970*1000.0));
        if(source) d[@"source"]=source;
        if(url) {
            d[@"protocol"]=Proto(url);
            d[@"url"]=url; // local file only: may contain temporary authorization
        }
        NSData *j=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil];
        if(j) [j writeToFile:gJSON atomically:YES];
    });
}
static void LogLine(NSString *s){
    NSString *doc=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *p=[doc stringByAppendingPathComponent:@"V11_EndpointObserver.log"];
    NSData *b=[[NSString stringWithFormat:@"[%@] %@\n",NSDate.date,s] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle*h=[NSFileHandle fileHandleForWritingAtPath:p];
    if(!h){[b writeToFile:p atomically:YES];return;} [h seekToEndOfFile];[h writeData:b];[h closeFile];
}

@interface NSURL(V11)
+ (instancetype)v11_URLWithString:(NSString *)s;
@end
@implementation NSURL(V11)
+ (void)load {
    Method a=class_getClassMethod(self,@selector(URLWithString:));
    Method b=class_getClassMethod(self,@selector(v11_URLWithString:));
    if(a&&b) method_exchangeImplementations(a,b);
}
+ (instancetype)v11_URLWithString:(NSString *)s {
    if(IsRecordable(s)) {
        LogLine([NSString stringWithFormat:@"recordable endpoint observed via NSURL (%@)",Proto(s)]);
        WriteInfo(@"playing",s,@"NSURL");
    }
    return [self v11_URLWithString:s];
}
@end

static IMP oldSetURL;
static void HookSetURL(id self, SEL _cmd, id value) {
    NSString *s=[value isKindOfClass:NSString.class]?value:[value description];
    if(IsRecordable(s)) {
        LogLine([NSString stringWithFormat:@"recordable endpoint observed via IJK (%@)",Proto(s)]);
        WriteInfo(@"playing",s,@"IJKMediaUrlOpenData");
    }
    ((void(*)(id,SEL,id))oldSetURL)(self,_cmd,value);
}
static IMP oldPrepare;
static void HookPrepare(id self, SEL _cmd) {
    LogLine(@"IJK prepareToPlay");
    ((void(*)(id,SEL))oldPrepare)(self,_cmd);
}

static void InstallIJK(void){
    Class c=objc_getClass("IJKMediaUrlOpenData");
    Method m=c?class_getInstanceMethod(c,@selector(setUrl:)):NULL;
    if(m){oldSetURL=method_getImplementation(m);method_setImplementation(m,(IMP)HookSetURL);}
    Class p=objc_getClass("IJKFFMoviePlayerController");
    Method q=p?class_getInstanceMethod(p,@selector(prepareToPlay)):NULL;
    if(q){oldPrepare=method_getImplementation(q);method_setImplementation(q,(IMP)HookPrepare);}
    LogLine(@"V11 ready");
}
__attribute__((constructor)) static void InitV11(void){ @autoreleasepool {
    gQ=dispatch_queue_create("v11.endpoint.json",DISPATCH_QUEUE_SERIAL);
    NSString *doc=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    gJSON=[doc stringByAppendingPathComponent:@"playback_info.json"];
    WriteInfo(@"waiting",nil,@"V11");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,6*NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{InstallIJK();});
}}
