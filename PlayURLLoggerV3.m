#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *LogPath(void) {
    NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    return [docs stringByAppendingPathComponent:@"PlayURLLoggerV3.txt"];
}
static void Log(NSString *s) {
    if(!s.length) return;
    NSString *line=[NSString stringWithFormat:@"[%@] %@\n",[NSDate date],s];
    NSData *d=[line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *p=LogPath();
    if(![[NSFileManager defaultManager] fileExistsAtPath:p]) {[d writeToFile:p atomically:YES]; return;}
    NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:p];
    [h seekToEndOfFile]; [h writeData:d]; [h closeFile];
}
static BOOL IsStream(NSString *s) {
    NSString *x=s.lowercaseString;
    return [x containsString:@"webrtc://"]||[x containsString:@".m3u8"]||
           [x containsString:@".flv"]||[x containsString:@"rtmp://"]||
           [x containsString:@"rtmps://"];
}
static void LogStack(NSString *url) {
    if(!IsStream(url)) return;
    Log([NSString stringWithFormat:@"[STREAM] %@",url]);
    NSArray *syms=[NSThread callStackSymbols];
    NSUInteger n=MIN((NSUInteger)20,syms.count);
    for(NSUInteger i=0;i<n;i++) Log([NSString stringWithFormat:@"[STACK %02lu] %@",(unsigned long)i,syms[i]]);
}
@interface NSURL (PULV3) @end
@implementation NSURL (PULV3)
+ (void)load {
    Method a=class_getClassMethod(self,@selector(URLWithString:));
    Method b=class_getClassMethod(self,@selector(pul3_URLWithString:));
    if(a&&b) method_exchangeImplementations(a,b);
}
+ (instancetype)pul3_URLWithString:(NSString *)s {
    LogStack(s);
    return [self pul3_URLWithString:s];
}
@end

__attribute__((constructor))
static void Init(void) {
    Log(@"[INIT] PlayURLLoggerV3 loaded");
}
