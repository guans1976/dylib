#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>

static dispatch_queue_t Q;
static NSString *LOG,*JSON;
static NSMutableDictionary<NSString*,NSValue*> *ORIG;
static BOOL installed=NO;

static void Log(NSString *s){
    dispatch_async(Q,^{
        NSString *x=[NSString stringWithFormat:@"[%@] %@\n",NSDate.date,s?:@""];
        NSData *d=[x dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:LOG];
        if(h){[h seekToEndOfFile];[h writeData:d];[h closeFile];}else[d writeToFile:LOG atomically:YES];
    });
}
static NSString *SHA(NSString *s){
    if(!s.length)return @"";
    NSData*d=[s dataUsingEncoding:NSUTF8StringEncoding]; unsigned char o[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes,(CC_LONG)d.length,o); NSMutableString*m=[NSMutableString string];
    for(int i=0;i<8;i++)[m appendFormat:@"%02x",o[i]]; return m;
}
static BOOL Sensitive(NSString*k){
    NSString*x=k.lowercaseString;
    NSArray*a=@[@"cookie",@"authorization",@"token",@"secret",@"sign",@"credential",@"session",@"device",@"fingerprint"];
    for(NSString*y in a)if([x containsString:y])return YES; return NO;
}
static NSString *SafeHeader(NSString*k,NSString*v){
    if(Sensitive(k))return [NSString stringWithFormat:@"<present len=%lu sha256_8=%@>",(unsigned long)v.length,SHA(v)];
    if(v.length>500)return [NSString stringWithFormat:@"<len=%lu sha256_8=%@>",(unsigned long)v.length,SHA(v)];
    return v?:@"";
}
static NSString *SafeURL(NSString*s){
    NSURLComponents*c=[NSURLComponents componentsWithString:s]; if(!c)return @"<invalid>";
    NSString*p=c.path?:@""; NSString*pl=p.lowercaseString;
    if([pl containsString:@"/preview/"]){
        NSString*ext=p.pathExtension.length?[@"." stringByAppendingString:p.pathExtension]:@"";
        p=[@"/preview/<redacted>/<redacted>" stringByAppendingString:ext];
    }
    return [NSString stringWithFormat:@"%@://%@%@",c.scheme?:@"",c.host?:@"",p];
}
static BOOL Preview(NSString*s){
    NSURLComponents*c=[NSURLComponents componentsWithString:s];
    return c && [c.host.lowercaseString isEqualToString:@"api.qituoc.com"] &&
      [c.path.lowercaseString containsString:@"/preview/"];
}
static NSDictionary *HeaderProfile(NSDictionary*h){
    NSMutableDictionary*m=[NSMutableDictionary dictionary];
    [h enumerateKeysAndObjectsUsingBlock:^(id k,id v,BOOL*stop){
        NSString*ks=[k description],*vs=[v description];
        m[ks]=SafeHeader(ks,vs);
    }]; return m;
}
static void SaveEvent(NSString*kind,NSString*url,NSDictionary*headers,NSString*method,NSInteger status,NSString*extra){
    dispatch_async(Q,^{
        NSMutableDictionary *doc=[NSMutableDictionary dictionaryWithDictionary:@{
          @"schema":@"paid-preview-v2-trace",@"status":@"ready",@"page_type":@"preview",
          @"playback_type":@"http_flv",@"updated_at_ms":@((long long)(NSDate.date.timeIntervalSince1970*1000))
        }];
        NSData*old=[NSData dataWithContentsOfFile:JSON];
        if(old){id o=[NSJSONSerialization JSONObjectWithData:old options:0 error:nil];if([o isKindOfClass:NSDictionary.class])[doc addEntriesFromDictionary:o];}
        NSMutableArray*ev=[NSMutableArray arrayWithArray:doc[@"events"]?:@[]];
        [ev addObject:@{@"kind":kind?:@"",@"url":SafeURL(url?:@""),@"method":method?:@"",
                        @"status":@(status),@"headers":HeaderProfile(headers?:@{}),@"extra":extra?:@""}];
        if(ev.count>200)[ev removeObjectsInRange:NSMakeRange(0,ev.count-200)];
        doc[@"events"]=ev;
        if(url.length)doc[@"media_url_redacted"]=SafeURL(url);
        NSData*d=[NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted error:nil];
        [d writeToFile:JSON atomically:YES];
    });
}
static NSString*K(Class c,SEL s){return [NSString stringWithFormat:@"%@|%@",NSStringFromClass(c),NSStringFromSelector(s)];}
static IMP O(id self,SEL s){return (IMP)[ORIG[K([self class],s)] pointerValue];}
static NSString*US(id x){if([x isKindOfClass:NSURL.class])return[x absoluteString];if([x isKindOfClass:NSString.class])return x;return@"";}

static id I1(id self,SEL cmd,id a){NSString*u=US(a);if(Preview(u)){Log([NSString stringWithFormat:@"IJK %@ %@",NSStringFromSelector(cmd),SafeURL(u)]);SaveEvent(@"ijk_init",u,nil,@"",0,@"");} id(*f)(id,SEL,id)=(void*)O(self,cmd);return f?f(self,cmd,a):nil;}
static id I2(id self,SEL cmd,id a,id b){NSString*u=US(a);if(Preview(u)){Log([NSString stringWithFormat:@"IJK %@ %@",NSStringFromSelector(cmd),SafeURL(u)]);SaveEvent(@"ijk_init",u,nil,@"",0,[b description]);} id(*f)(id,SEL,id,id)=(void*)O(self,cmd);return f?f(self,cmd,a,b):nil;}
static void V1(id self,SEL cmd,id a){NSString*u=US(a);if(Preview(u)){Log([NSString stringWithFormat:@"IJK %@ %@",NSStringFromSelector(cmd),SafeURL(u)]);SaveEvent(@"ijk_open",u,nil,@"",0,@"");} void(*f)(id,SEL,id)=(void*)O(self,cmd);if(f)f(self,cmd,a);}

static id Req1(id self,SEL cmd,id req){
    if([req isKindOfClass:NSURLRequest.class]){
        NSURLRequest*r=req; NSString*u=r.URL.absoluteString;
        if(Preview(u)){Log([NSString stringWithFormat:@"NSURLSession request %@ %@",r.HTTPMethod,SafeURL(u)]);
            SaveEvent(@"urlsession_request",u,r.allHTTPHeaderFields,r.HTTPMethod,0,
                      [NSString stringWithFormat:@"bodyLen=%lu",(unsigned long)r.HTTPBody.length]);}
    }
    id(*f)(id,SEL,id)=(void*)O(self,cmd);return f?f(self,cmd,req):nil;
}
static id Req2(id self,SEL cmd,id req,id block){
    if([req isKindOfClass:NSURLRequest.class]){
        NSURLRequest*r=req; NSString*u=r.URL.absoluteString;
        if(Preview(u)){Log([NSString stringWithFormat:@"NSURLSession request+completion %@ %@",r.HTTPMethod,SafeURL(u)]);
            SaveEvent(@"urlsession_request",u,r.allHTTPHeaderFields,r.HTTPMethod,0,
                      [NSString stringWithFormat:@"bodyLen=%lu",(unsigned long)r.HTTPBody.length]);}
    }
    id(*f)(id,SEL,id,id)=(void*)O(self,cmd);return f?f(self,cmd,req,block):nil;
}
static id MReq(id self,SEL cmd,id req){
    if([req isKindOfClass:NSURLRequest.class]){
        NSURLRequest*r=req;NSString*u=r.URL.absoluteString;if(Preview(u))
            SaveEvent(@"connection_request",u,r.allHTTPHeaderFields,r.HTTPMethod,0,@"");
    }
    id(*f)(id,SEL,id)=(void*)O(self,cmd);return f?f(self,cmd,req):nil;
}

static BOOL Hook(const char*cname,const char*sname,IMP imp){
    Class c=objc_getClass(cname);if(!c)return NO;SEL s=sel_registerName(sname);Method m=class_getInstanceMethod(c,s);if(!m)return NO;
    NSString*k=K(c,s);if(ORIG[k])return YES;ORIG[k]=[NSValue valueWithPointer:method_getImplementation(m)];method_setImplementation(m,imp);
    Log([NSString stringWithFormat:@"HOOK %s -%s",cname,sname]);return YES;
}
static void Install(unsigned n){
    if(installed)return;int c=0;
    c+=Hook("IJKFFMoviePlayerController","initWithContentURL:",(IMP)I1);
    c+=Hook("IJKFFMoviePlayerController","initWithContentURL:withOptions:",(IMP)I2);
    c+=Hook("IJKFFMoviePlayerController","initWithContentURLString:",(IMP)I1);
    c+=Hook("IJKFFMoviePlayerController","initWithContentURLString:withOptions:",(IMP)I2);
    c+=Hook("IJKMediaUrlOpenData","setUrl:",(IMP)V1);
    c+=Hook("__NSCFURLSession","dataTaskWithRequest:",(IMP)Req1);
    c+=Hook("__NSCFURLSession","dataTaskWithRequest:completionHandler:",(IMP)Req2);
    c+=Hook("NSURLConnection","initWithRequest:delegate:",(IMP)MReq);
    if(c>=2){installed=YES;Log([NSString stringWithFormat:@"V2 TRACE READY hooks=%d",c]);}
    else if(n<30)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{Install(n+1);});
    else Log(@"V2 TRACE hook install incomplete");
}
__attribute__((constructor))static void Init(){@autoreleasepool{
 Q=dispatch_queue_create("paid.preview.v2.trace",DISPATCH_QUEUE_SERIAL);ORIG=[NSMutableDictionary dictionary];
 NSString*d=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
 LOG=[d stringByAppendingPathComponent:@"PaidPreviewV2Trace.log"];JSON=[d stringByAppendingPathComponent:@"preview_trace.json"];
 NSData*x=[NSJSONSerialization dataWithJSONObject:@{@"schema":@"paid-preview-v2-trace",@"status":@"waiting",@"events":@[]} options:NSJSONWritingPrettyPrinted error:nil];[x writeToFile:JSON atomically:YES];
 Log(@"PaidPreviewV2Trace active");dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{Install(0);});
}}