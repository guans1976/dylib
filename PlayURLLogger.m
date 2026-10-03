#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *LogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"PlayURLLogger.txt"];
}

static void LogURL(NSString *s) {
    if (!s.length) return;
    NSString *x = s.lowercaseString;
    NSArray *keys = @[@"http://", @"https://", @".m3u8", @".flv",
                      @"rtmp://", @"rtmps://", @"webrtc://"];
    BOOL matched = NO;
    for (NSString *k in keys) {
        if ([x containsString:k]) { matched = YES; break; }
    }
    if (!matched) return;

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], s];
    NSLog(@"[PlayURLLogger] %@", s);

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = LogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    [h seekToEndOfFile];
    [h writeData:data];
    [h closeFile];
}

@interface NSURL (PlayURLLogger)
@end

@implementation NSURL (PlayURLLogger)

+ (void)load {
    Method original = class_getClassMethod(self, @selector(URLWithString:));
    Method replacement = class_getClassMethod(self, @selector(pl_URLWithString:));
    if (original && replacement) method_exchangeImplementations(original, replacement);
}

+ (instancetype)pl_URLWithString:(NSString *)string {
    LogURL(string);
    return [self pl_URLWithString:string];
}
@end

__attribute__((constructor))
static void PlayURLLoggerInit(void) {
    NSLog(@"[PlayURLLogger] loaded");
}
