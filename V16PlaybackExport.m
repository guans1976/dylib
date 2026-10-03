#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>

static dispatch_queue_t exportQ;
static NSString *exportPath,*logPath;
static IMP originalSend;
static BOOL installed;
static void Log(NSString *text) {
    dispatch_async(exportQ, ^{
        NSData *data=[[NSString stringWithFormat:@"[%@] %@\n",NSDate.date,text] dataUsingEncoding:NSUTF8StringEncoding];
        @try {
            NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:logPath];
            if(h) {[h seekToEndOfFile];[h writeData:data];[h closeFile];}
            else [data writeToFile:logPath atomically:YES];
        } @catch(NSException *exception) { (void)exception; }
    });
}
static void Save(NSDictionary *record) {
    dispatch_async(exportQ, ^{
        NSError *error=nil;
        NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:&error];
        BOOL ok=data && [data writeToFile:exportPath options:NSDataWritingAtomic error:&error];
        NSLog(@"[V16] export %@",ok?@"saved":@"failed");
    });
}
static char Type(const char *s) {if(!s)return 0;while(*s && strchr("rnNoORV",*s))s++;return *s;}
static BOOL Getter(id object,NSString *name,char expected) {
    SEL sel=NSSelectorFromString(name);Method m=class_getInstanceMethod(object_getClass(object),sel);
    if(!m || method_getNumberOfArguments(m)!=2)return NO;
    char *t=method_copyReturnType(m);BOOL ok=Type(t)==expected;free(t);return ok;
}
static NSString *StringValue(id object,NSString *name) {
    if(!Getter(object,name,'@'))return @"";
    id value=((id(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name));
    return [value isKindOfClass:NSString.class]?value:@"";
}
static int IntValue(id object,NSString *name) {
    if(!Getter(object,name,'i'))return -1;
    return ((int(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name));
}
static BOOL BoolValue(id object,NSString *name) {
    if(!Getter(object,name,'B'))return NO;
    return ((BOOL(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name));
}
static void ExportParam(id param) {
    if(BoolValue(param,@"isStop")){Log(@"STOP ignored; retaining playback export");return;}
    NSString *stream=StringValue(param,@"streamUrl"),*offer=StringValue(param,@"localSdp");
    NSString *domain=StringValue(param,@"domain"),*hostIp=StringValue(param,@"hostIp");
    int transport=IntValue(param,@"signalingType");
    Log([NSString stringWithFormat:@"SEND transport=%d streamLength=%lu offerLength=%lu domainLength=%lu",transport,(unsigned long)stream.length,(unsigned long)offer.length,(unsigned long)domain.length]);
    if(!stream.length || ![offer hasPrefix:@"v=0"] || ![offer containsString:@"m="]) {
        Save(@{@"schema":@"hwlls-playback-v16",@"status":@"incomplete",@"reason":@"SDK parameter missing streamUrl or localSdp"});return;
    }
    NSURLComponents *streamParts=[NSURLComponents componentsWithString:stream];
    NSString *server=domain.length?domain:streamParts.host;
    if(!server.length)server=hostIp;
    if(!server.length){Save(@{@"schema":@"hwlls-playback-v16",@"status":@"incomplete",@"reason":@"SDK parameter missing signaling host"});return;}
    // Verified C++ HTTP signaling uses ports 80 / 443, not the UDP signaling port.
    NSURLComponents *url=[NSURLComponents new];url.scheme=transport==0?@"http":@"https";
    url.host=(transport==0 && hostIp.length)?hostIp:server;url.port=transport==0?@80:@443;url.path=@"/webrtc/v1/pullstream";
    if(!url.URL){Save(@{@"schema":@"hwlls-playback-v16",@"status":@"incomplete",@"reason":@"Invalid signaling host"});return;}
    NSMutableDictionary *headers=[@{@"Content-Type":@"application/json;charset=utf-8"} mutableCopy];
    if(transport==0 && domain.length)headers[@"Host"]=domain;
    NSDictionary *body=@{@"streamurl":stream,@"localsdp":@{@"type":@"offer",@"sdp":offer}};
    NSMutableDictionary *record=[@{@"schema":@"hwlls-playback-v16",@"status":@"ready",@"updated_at_ms":@((long long)(NSDate.date.timeIntervalSince1970*1000)),@"request_origin":@"verified-sdk-http-format",@"requires_http_transport_test":@(transport==2),@"native_signaling_type":@(transport),@"native_signaling_port":@(IntValue(param,@"port")),@"stream_url":stream,@"signaling_domain":server,@"signaling_host_ip":hostIp,@"request":@{@"url":url.URL.absoluteString,@"method":@"POST",@"headers":headers,@"body":body}} mutableCopy];
    Save(record);Log(transport==2?@"EXPORT ready; native UDP, desktop HTTPS endpoint requires testing":@"EXPORT ready; native HTTP/HTTPS");
}
static id Send(id self,SEL sel,id param) {
    @try { ExportParam(param); } @catch(NSException *exception) {Log([@"EXPORT exception " stringByAppendingString:exception.name]);}
    id response=((id(*)(id,SEL,id))originalSend)(self,sel,param);
    Log([NSString stringWithFormat:@"SDK_RESPONSE httpCode=%d errCode=%d remoteSdpLength=%lu",IntValue(response,@"httpCode"),IntValue(response,@"errCode"),(unsigned long)StringValue(response,@"remoteSdp").length]);
    return response;
}
static void Install(unsigned attempt) {
    if(installed)return;
    Class c=objc_getClass("RTCSignalingSender");Class meta=c?object_getClass(c):Nil;
    SEL sel=NSSelectorFromString(@"sendSignaling:");Method m=meta?class_getInstanceMethod(meta,sel):NULL;
    if(!m) {
        if(attempt<30)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{Install(attempt+1);});
        else {Log(@"HOOK_MISSING RTCSignalingSender sendSignaling:");Save(@{@"schema":@"hwlls-playback-v16",@"status":@"hook_missing"});}
        return;
    }
    char *ret=method_copyReturnType(m),*arg=method_copyArgumentType(m,2);
    BOOL valid=method_getNumberOfArguments(m)==3 && Type(ret)=='@' && Type(arg)=='@';free(ret);free(arg);
    if(!valid){Log(@"ABI_SKIP sendSignaling:");Save(@{@"schema":@"hwlls-playback-v16",@"status":@"abi_mismatch"});return;}
    originalSend=method_getImplementation(m);
    if(!class_addMethod(meta,sel,(IMP)Send,method_getTypeEncoding(m)))method_setImplementation(m,(IMP)Send);
    installed=YES;Log(@"HOOK RTCSignalingSender +sendSignaling:");
}
__attribute__((constructor)) static void Initialize(void) { @autoreleasepool {
    exportQ=dispatch_queue_create("v16.playback.export",DISPATCH_QUEUE_SERIAL);
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    exportPath=[documents stringByAppendingPathComponent:@"playback_info.json"];
    logPath=[documents stringByAppendingPathComponent:@"V16_PlaybackExport.log"];
    Save(@{@"schema":@"hwlls-playback-v16",@"status":@"waiting"});
    dispatch_async(dispatch_get_main_queue(),^{Install(0);});
}}
