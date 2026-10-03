#import <Foundation/Foundation.h>
#import <objc/runtime.h>
static dispatch_queue_t exportQ;
static NSString *exportPath;
static IMP oldData,oldUpload;
static BOOL HasSDP(id o) {
    if([o isKindOfClass:NSString.class]) return [o hasPrefix:@"v=0"] && [o containsString:@"m="];
    if([o isKindOfClass:NSDictionary.class]) {for(id k in o) if(HasSDP(o[k])) return YES;}
    if([o isKindOfClass:NSArray.class]) {for(id v in o) if(HasSDP(v)) return YES;}
    return NO;
}
static void Capture(NSURLRequest *r, NSData *body) {
    if(!body || body.length>2*1024*1024) return;
    id obj=[NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
    if(!obj || !HasSDP(obj)) return;
    NSDictionary *record=@{@"schema":@"hwlls-playback-v15",@"status":@"ready",@"updated_at_ms":@((long long)(NSDate.date.timeIntervalSince1970*1000)),@"request":@{@"url":r.URL.absoluteString?:@"",@"method":r.HTTPMethod?:@"POST",@"headers":r.allHTTPHeaderFields?:@{},@"body":obj}};
    dispatch_async(exportQ, ^{NSData *out=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:NULL]; if(out) [out writeToFile:exportPath atomically:YES];});
}
static NSURLSessionDataTask *DataTask(id self,SEL sel,NSURLRequest *r,void (^cb)(NSData *,NSURLResponse *,NSError *)) {
    Capture(r,r.HTTPBody);
    return ((NSURLSessionDataTask *(*)(id,SEL,NSURLRequest *,id))oldData)(self,sel,r,cb);
}
static NSURLSessionUploadTask *UploadTask(id self,SEL sel,NSURLRequest *r,NSData *b,void (^cb)(NSData *,NSURLResponse *,NSError *)) {
    Capture(r,b);
    return ((NSURLSessionUploadTask *(*)(id,SEL,NSURLRequest *,NSData *,id))oldUpload)(self,sel,r,b,cb);
}
static void Install(Class c,SEL s,IMP replacement,IMP *original) {
    Method m=class_getInstanceMethod(c,s); if(!m) return;
    *original=method_getImplementation(m);
    if(!class_addMethod(c,s,replacement,method_getTypeEncoding(m))) method_setImplementation(m,replacement);
}
__attribute__((constructor)) static void Init(void) { @autoreleasepool {
    exportQ=dispatch_queue_create("v15.export",DISPATCH_QUEUE_SERIAL);
    exportPath=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"playback_info.json"];
    [@"{\"schema\":\"hwlls-playback-v15\",\"status\":\"waiting\"}" writeToFile:exportPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    Install(NSURLSession.class,@selector(dataTaskWithRequest:completionHandler:),(IMP)DataTask,&oldData);
    Install(NSURLSession.class,@selector(uploadTaskWithRequest:fromData:completionHandler:),(IMP)UploadTask,&oldUpload);
}}
