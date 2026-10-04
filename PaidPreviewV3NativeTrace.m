#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static dispatch_queue_t Q; static NSString *LOG,*JSON;
static NSMutableDictionary *ORIG; static BOOL INST=NO;

static void Log(NSString*s){dispatch_async(Q,^{NSString*x=[NSString stringWithFormat:@"[%@] %@\n",NSDate.date,s?:@""];
NSData*d=[x dataUsingEncoding:NSUTF8StringEncoding];NSFileHandle*h=[NSFileHandle fileHandleForWritingAtPath:LOG];
if(h){[h seekToEndOfFile];[h writeData:d];[h closeFile];}else[d writeToFile:LOG atomically:YES];});}
static BOOL sens(NSString*k){k=k.lowercaseString;for(NSString*x in @[@"cookie",@"authorization",@"token",@"secret",@"sign",@"credential",@"session",@"device",@"fingerprint",@"password"])if([k containsString:x])return YES;return NO;}
static NSString*safev(NSString*k,id v){NSString*s=[v description]?:@"";if(sens(k))return[NSString stringWithFormat:@"<present len=%lu>",(unsigned long)s.length];if(s.length>800)return[NSString stringWithFormat:@"<len=%lu>",(unsigned long)s.length];return s;}
static NSString*safeurl(NSString*s){NSURLComponents*c=[NSURLComponents componentsWithString:s];if(!c)return@"<invalid>";NSString*p=c.path?:@"";if([p.lowercaseString containsString:@"/preview/"]){NSString*e=p.pathExtension.length?[@"." stringByAppendingString:p.pathExtension]:@"";p=[@"/preview/<redacted>/<redacted>" stringByAppendingString:e];}return[NSString stringWithFormat:@"%@://%@%@",c.scheme?:@"",c.host?:@"",p];}
static BOOL preview(NSString*s){NSURLComponents*c=[NSURLComponents componentsWithString:s];return c&&[c.path.lowercaseString containsString:@"/preview/"];}
static NSString*us(id x){if([x isKindOfClass:NSURL.class])return[x absoluteString];if([x isKindOfClass:NSString.class])return x;return@"";}

static NSDictionary*inspect(id o){
 if(!o)return @{};
 NSMutableDictionary*r=[NSMutableDictionary dictionary];Class c=[o class];
 r[@"class"]=NSStringFromClass(c)?:@"";
 unsigned n=0;objc_property_t*p=class_copyPropertyList(c,&n);
 for(unsigned i=0;i<n&&i<100;i++){const char*nm=property_getName(p[i]);if(!nm)continue;NSString*k=@(nm);
   @try{id v=[o valueForKey:k];if(v)r[k]=safev(k,v);}@catch(__unused id e){}}
 free(p);
 // Selected common IJK option selectors; zero-arg getters only.
 for(NSString*k in @[@"playerOptions",@"formatOptions",@"codecOptions",@"swsOptions",@"swrOptions",@"options",@"url",@"headers",@"userAgent",@"referer"]){
   SEL s=NSSelectorFromString(k);Method mm=class_getInstanceMethod(c,s);if(mm&&method_getNumberOfArguments(mm)==2){
     char rt[8]={0};method_getReturnType(mm,rt,sizeof(rt));if(rt[0]=='@'){@try{id v=((id(*)(id,SEL))objc_msgSend)(o,s);if(v)r[k]=safev(k,v);}@catch(__unused id e){}}
   }}
 return r;
}
static void save(NSString*kind,NSString*u,id obj){
 dispatch_async(Q,^{
   NSMutableDictionary*d=[@{@"schema":@"paid-preview-v3-native-trace",@"status":@"ready",@"page_type":@"preview",@"playback_type":@"http_flv",@"updated_at_ms":@((long long)(NSDate.date.timeIntervalSince1970*1000))} mutableCopy];
   NSData*old=[NSData dataWithContentsOfFile:JSON];if(old){id x=[NSJSONSerialization JSONObjectWithData:old options:0 error:nil];if([x isKindOfClass:NSDictionary.class])[d addEntriesFromDictionary:x];}
   d[@"status"]=@"ready"; d[@"updated_at_ms"]=@((long long)(NSDate.date.timeIntervalSince1970*1000));
   NSMutableArray*e=[NSMutableArray arrayWithArray:d[@"events"]?:@[]];
   [e addObject:@{@"kind":kind?:@"",@"url":safeurl(u?:@""),@"object":inspect(obj)}];if(e.count>200)[e removeObjectsInRange:NSMakeRange(0,e.count-200)];d[@"events"]=e;
   NSData*j=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil];[j writeToFile:JSON atomically:YES];
 });
}
static NSString*K(Class c,SEL s){return[NSString stringWithFormat:@"%@|%@",NSStringFromClass(c),NSStringFromSelector(s)];}
static IMP O(id self,SEL s){return(IMP)[ORIG[K([self class],s)] pointerValue];}
static id H1(id self,SEL cmd,id a){NSString*u=us(a);if(preview(u)){Log([NSString stringWithFormat:@"IJK %@ %@",NSStringFromSelector(cmd),safeurl(u)]);save(@"ijk_init",u,nil);}id(*f)(id,SEL,id)=(void*)O(self,cmd);return f?f(self,cmd,a):nil;}
static id H2(id self,SEL cmd,id a,id b){NSString*u=us(a);if(preview(u)){Log([NSString stringWithFormat:@"IJK %@ options=%@",NSStringFromSelector(cmd),NSStringFromClass([b class])]);save(@"ijk_init_options",u,b);}id(*f)(id,SEL,id,id)=(void*)O(self,cmd);return f?f(self,cmd,a,b):nil;}
static void HV(id self,SEL cmd,id a){NSString*u=us(a);if(preview(u)){save(@"ijk_url_open",u,self);Log([NSString stringWithFormat:@"IJK OPEN %@",safeurl(u)]);}void(*f)(id,SEL,id)=(void*)O(self,cmd);if(f)f(self,cmd,a);}
static BOOL Hook(const char*cn,const char*sn,IMP h){Class c=objc_getClass(cn);if(!c)return NO;SEL s=sel_registerName(sn);Method m=class_getInstanceMethod(c,s);if(!m)return NO;NSString*k=K(c,s);if(ORIG[k])return YES;ORIG[k]=[NSValue valueWithPointer:method_getImplementation(m)];method_setImplementation(m,h);Log([NSString stringWithFormat:@"HOOK %s -%s types=%s",cn,sn,method_getTypeEncoding(m)]);return YES;}

static void Inventory(void){
 int total=objc_getClassList(NULL,0);Class*cs=malloc(sizeof(Class)*total);objc_getClassList(cs,total);
 for(int i=0;i<total;i++){NSString*n=NSStringFromClass(cs[i]);NSString*l=n.lowercaseString;
   if(!([l containsString:@"ijk"]||[l containsString:@"ffmpeg"]||[l containsString:@"ffio"]||[l containsString:@"urlopen"]))continue;
   unsigned mc=0;Method*ms=class_copyMethodList(cs[i],&mc);NSMutableArray*a=[NSMutableArray array];
   for(unsigned j=0;j<mc&&j<200;j++){NSString*s=NSStringFromSelector(method_getName(ms[j]));NSString*sl=s.lowercaseString;
     if([sl containsString:@"url"]||[sl containsString:@"option"]||[sl containsString:@"header"]||[sl containsString:@"open"]||[sl containsString:@"http"]||[sl containsString:@"format"])
       [a addObject:[NSString stringWithFormat:@"%@ [%s]",s,method_getTypeEncoding(ms[j])]];
   }free(ms);if(a.count)Log([NSString stringWithFormat:@"CLASS %@ METHODS %@",n,[a componentsJoinedByString:@" | "]]);
 }free(cs);
}
static void Install(unsigned n){if(INST)return;int c=0;
 c+=Hook("IJKFFMoviePlayerController","initWithContentURL:",(IMP)H1);
 c+=Hook("IJKFFMoviePlayerController","initWithContentURL:withOptions:",(IMP)H2);
 c+=Hook("IJKFFMoviePlayerController","initWithContentURLString:",(IMP)H1);
 c+=Hook("IJKFFMoviePlayerController","initWithContentURLString:withOptions:",(IMP)H2);
 c+=Hook("IJKMediaUrlOpenData","setUrl:",(IMP)HV);
 if(c){INST=YES;Log([NSString stringWithFormat:@"V3 READY hooks=%d",c]);dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{Inventory();});}
 else if(n<30)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{Install(n+1);});
}
__attribute__((constructor))static void Init(){@autoreleasepool{
 Q=dispatch_queue_create("preview.v3",DISPATCH_QUEUE_SERIAL);ORIG=[NSMutableDictionary dictionary];
 NSString*d=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
 LOG=[d stringByAppendingPathComponent:@"PaidPreviewV3NativeTrace.log"];JSON=[d stringByAppendingPathComponent:@"preview_v3_trace.json"];
 NSData*j=[NSJSONSerialization dataWithJSONObject:@{@"schema":@"paid-preview-v3-native-trace",@"status":@"waiting",@"events":@[]} options:NSJSONWritingPrettyPrinted error:nil];[j writeToFile:JSON atomically:YES];
 Log(@"PaidPreviewV3 Native Trace active");dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{Install(0);});
}}