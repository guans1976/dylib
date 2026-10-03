#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// V14: only allowlisted events, numeric codes, class names and protocol labels.
static dispatch_queue_t logQueue;
static NSString *logPath;
static atomic_uint eventCount;
static IMP oldPlay, oldInit, oldIJK, oldAppError, oldClientError, oldResult, oldRetry, oldDown;
static BOOL installed[8];
static void Log(NSString *s) {
    if (atomic_fetch_add(&eventCount, 1) >= 2000) return;
    dispatch_async(logQueue, ^{
        @try {
            NSString *line = [NSString stringWithFormat:@"[%@] %@\n", NSDate.date, s];
            NSData *bytes = [line dataUsingEncoding:NSUTF8StringEncoding];
            NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:logPath];
            if (!h) { [bytes writeToFile:logPath atomically:YES]; return; }
            [h seekToEndOfFile]; [h writeData:bytes]; [h closeFile];
        } @catch (NSException *e) { /* Do not log exception payloads. */ }
    });
}
static NSString *Protocol(id value) {
    NSString *s = nil;
    if ([value isKindOfClass:NSString.class]) s = value;
    else if ([value isKindOfClass:NSURL.class]) s = [value absoluteString];
    if (!s.length) return @"empty";
    NSURLComponents *c = [NSURLComponents componentsWithString:s];
    NSString *scheme = c.scheme.lowercaseString;
    NSString *ext = c.path.pathExtension.lowercaseString;
    if ([scheme isEqualToString:@"webrtc"]) return @"webrtc";
    if ([scheme isEqualToString:@"rtmp"] || [scheme isEqualToString:@"rtmps"]) return @"rtmp";
    if ([ext isEqualToString:@"m3u8"]) return @"hls";
    if ([ext isEqualToString:@"flv"]) return @"http-flv";
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) return @"http(s)";
    return @"other";
}
static const char *BaseType(const char *t) {
    while (*t && strchr("rnNoORV", *t)) t++;
    return t;
}
// Validate ABI before replacing any implementation. Preserve inherited methods.
static BOOL Hook(const char *className, const char *selName, IMP replacement, IMP *original,
                 char returnType, const char *args) {
    Class c = objc_getClass(className);
    if (!c) return NO;
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NO;
    BOOL valid = method_getNumberOfArguments(m) == strlen(args) + 2;
    char *rt = method_copyReturnType(m);
    const char actual = *BaseType(rt);
    valid = valid && (actual == returnType || (returnType == 'B' && actual == 'c'));
    free(rt);
    for (unsigned i = 0; valid && i < strlen(args); i++) {
        char *at = method_copyArgumentType(m, i + 2);
        valid = *BaseType(at) == args[i] || (args[i] == 'B' && *BaseType(at) == 'c');
        free(at);
    }
    if (!valid) { Log([NSString stringWithFormat:@"ABI_SKIP %s %s", className, selName]); return YES; }
    *original = method_getImplementation(m);
    if (!class_addMethod(c, sel, replacement, method_getTypeEncoding(m)))
        method_setImplementation(class_getInstanceMethod(c, sel), replacement);
    Log([NSString stringWithFormat:@"HOOK %s %s", className, selName]);
    return YES;
}
static int Play(id self, SEL cmd, id url) {
    Log([NSString stringWithFormat:@"HUAWEI_START protocol=%@", Protocol(url)]);
    int result = ((int (*)(id, SEL, id))oldPlay)(self, cmd, url);
    Log([NSString stringWithFormat:@"HUAWEI_START_RETURN code=%d", result]);
    return result;
}
static void InitPlayer(id self, SEL cmd, id view, id delegate) {
    Log([NSString stringWithFormat:@"HUAWEI_INIT delegateClass=%@", delegate ? NSStringFromClass([delegate class]) : @"nil"]);
    ((void (*)(id, SEL, id, id))oldInit)(self, cmd, view, delegate);
}
static void IJKPrepare(id self, SEL cmd) {
    id url = nil;
    SEL getter = sel_registerName("contentURL");
    if ([self respondsToSelector:getter]) {
        Method m = class_getInstanceMethod([self class], getter);
        char *type = method_copyReturnType(m);
        if (*BaseType(type) == '@') url = ((id (*)(id, SEL))objc_msgSend)(self, getter);
        free(type);
    }
    Log([NSString stringWithFormat:@"IJK_PREPARE protocol=%@", Protocol(url)]);
    ((void (*)(id, SEL))oldIJK)(self, cmd);
    Log(@"IJK_PREPARE_RETURN");
}
static void AppError(id self, SEL cmd, id client, NSInteger code, id message) {
    Log([NSString stringWithFormat:@"APP_ERROR code=%ld businessDowngrade=%@", (long)code, code == 500000021 ? @"YES" : @"NO"]);
    ((void (*)(id, SEL, id, NSInteger, id))oldAppError)(self, cmd, client, code, message);
    Log(@"APP_ERROR_RETURN");
}
static void ClientError(id self, SEL cmd, id proxy, NSInteger code, id message) {
    Log([NSString stringWithFormat:@"SDK_ERROR code=%ld", (long)code]);
    ((void (*)(id, SEL, id, NSInteger, id))oldClientError)(self, cmd, proxy, code, message);
}
static void Result(id self, SEL cmd, id response) {
    if ([response respondsToSelector:sel_registerName("errCode")]) {
        // int return ABI confirmed by the supplied ARM64 binary.
        int code = ((int (*)(id, SEL))objc_msgSend)(response, sel_registerName("errCode"));
        Log([NSString stringWithFormat:@"SIGNAL_RESULT serverCode=%d businessDowngrade=%@", code, code == 601 ? @"YES" : @"NO"]);
    } else Log(@"SIGNAL_RESULT code=unavailable");
    ((void (*)(id, SEL, id))oldResult)(self, cmd, response);
}
static BOOL Retry(id self, SEL cmd, NSInteger code) {
    BOOL result = ((BOOL (*)(id, SEL, NSInteger))oldRetry)(self, cmd, code);
    Log([NSString stringWithFormat:@"ERROR_BRANCH code=%ld reportError=%@", (long)code, result ? @"YES" : @"NO"]);
    return result;
}
static void Down(id self, SEL cmd, BOOL enabled) {
    Log([NSString stringWithFormat:@"DNS_FALLBACK_FLAG enabled=%@", enabled ? @"YES" : @"NO"]);
    ((void (*)(id, SEL, BOOL))oldDown)(self, cmd, enabled);
}
static void Install(unsigned attempt) {
    const char *classes[] = {"HLLLManager", "HLLLManager", "IJKFFMoviePlayerController",
        "_TtC13Live_Audience19StreamPlayerManager", "HWLLSClient", "HWLLSClientProxy", "HWLLSClientProxy", "HWLLSClientProxy"};
    const char *selectors[] = {"playStream:", "iniPlayer:delegate:", "prepareToPlay",
        "onError:errorCode:errorMsg:", "onError:errorCode:errorMsg:", "playRequestResultDoingWithSdpResp:",
        "playNeedReplayWithErrorCode:", "setIsNeedDowngrade:"};
    IMP replacements[] = {(IMP)Play, (IMP)InitPlayer, (IMP)IJKPrepare, (IMP)AppError,
        (IMP)ClientError, (IMP)Result, (IMP)Retry, (IMP)Down};
    IMP *originals[] = {&oldPlay, &oldInit, &oldIJK, &oldAppError, &oldClientError, &oldResult, &oldRetry, &oldDown};
    const char returns[] = {'i','v','v','v','v','v','B','v'};
    const char *args[] = {"@", "@@", "", "@q@", "@q@", "@", "q", "B"};
    BOOL complete = YES;
    for (unsigned i = 0; i < 8; i++) {
        if (!installed[i]) installed[i] = Hook(classes[i], selectors[i], replacements[i], originals[i], returns[i], args[i]);
        if (!installed[i]) complete = NO;
    }
    if (!complete && attempt < 20) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Install(attempt + 1); });
    } else {
        for (unsigned i = 0; i < 8; i++) if (!installed[i]) Log([NSString stringWithFormat:@"MISS %s %s", classes[i], selectors[i]]);
        Log(@"V14 installation complete; observer only");
    }
}
__attribute__((constructor)) static void InitV14(void) {
    @autoreleasepool {
        logQueue = dispatch_queue_create("v14.player-route", DISPATCH_QUEUE_SERIAL);
        NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        logPath = [dir stringByAppendingPathComponent:@"V14_PlayerRouteTrace.log"];
        Log(@"V14 ready; protocol labels and numeric codes only");
        dispatch_async(dispatch_get_main_queue(), ^{ Install(0); });
    }
}
