#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *LogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"PlayURLLoggerV2.txt"];
}
static BOOL Interesting(NSString *s) {
    if (!s.length) return NO;
    NSString *x=s.lowercaseString;
    NSArray *keys=@[@"webrtc://",@"http://",@"https://",@".m3u8",@".flv",@"rtmp://",@"rtmps://",
                    @"sdp",@"candidate",@"ice",@"stun:",@"turn:",@"pullstream",@"playurl",@"stream_url"];
    for (NSString *k in keys) if ([x containsString:k]) return YES;
    return NO;
}
static void LogLine(NSString *tag, NSString *s) {
    if (!Interesting(s)) return;
    NSString *line=[NSString stringWithFormat:@"[%@] [%@] %@\n",[NSDate date],tag?:@"LOG",s];
    NSData *data=[line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path=LogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {[data writeToFile:path atomically:YES]; return;}
    NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:path];
    [h seekToEndOfFile]; [h writeData:data]; [h closeFile];
}
@interface NSURL (PULV2) @end
@implementation NSURL (PULV2)
+ (void)load {
    Method a=class_getClassMethod(self,@selector(URLWithString:));
    Method b=class_getClassMethod(self,@selector(pul_URLWithString:));
    if(a&&b) method_exchangeImplementations(a,b);
}
+ (instancetype)pul_URLWithString:(NSString *)s {
    LogLine(@"NSURL",s); return [self pul_URLWithString:s];
}
@end
@interface NSMutableURLRequest (PULV2) @end
@implementation NSMutableURLRequest (PULV2)
+ (void)load {
    Method a=class_getInstanceMethod(self,@selector(setURL:));
    Method b=class_getInstanceMethod(self,@selector(pul_setURL:));
    if(a&&b) method_exchangeImplementations(a,b);
}
- (void)pul_setURL:(NSURL *)u {
    LogLine(@"REQUEST",u.absoluteString); [self pul_setURL:u];
}
@end
__attribute__((constructor)) static void Init(void) { NSLog(@"[PlayURLLoggerV2] loaded"); }
