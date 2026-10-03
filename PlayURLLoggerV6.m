#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

static NSString *P(void){ NSString*d=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject; return [d stringByAppendingPathComponent:@"PlayURLLoggerV6.txt"]; }
static void L(NSString*s){ if(!s.length)return; NSString*x=[NSString stringWithFormat:@"[%@] %@\n",[NSDate date],s]; NSData*d=[x dataUsingEncoding:NSUTF8StringEncoding]; @synchronized([NSFileHandle class]){ if(![[NSFileManager defaultManager]fileExistsAtPath:P()]){[d writeToFile:P() atomically:YES];return;} NSFileHandle*h=[NSFileHandle fileHandleForWritingAtPath:P()];[h seekToEndOfFile];[h writeData:d];[h closeFile];} }
static NSString *R(NSString*s){ if(!s)return @"<nil>"; NSMutableString*m=[s mutableCopy]; NSArray*k=@[@"txSecret",@"token",@"access_token",@"authorization",@"cookie",@"password",@"secret",@"credential"]; for(NSString*q in k){NSRegularExpression*r=[NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"(?i)(%@\\s*[=:]\\s*)([^&\\s,;\\\"}]+)",[NSRegularExpression escapedPatternForString:q]] options:0 error:nil];[r replaceMatchesInString:m options:0 range:NSMakeRange(0,m.length) withTemplate:@"$1<redacted>"];}return m;}

@interface NSURL(PULV6) @end
@implementation NSURL(PULV6)
+(void)load{Method a=class_getClassMethod(self,@selector(URLWithString:)),b=class_getClassMethod(self,@selector(p6_URLWithString:));if(a&&b)method_exchangeImplementations(a,b);}
+(instancetype)p6_URLWithString:(NSString*)s{if(s.length)L([NSString stringWithFormat:@"[URL] %@",R(s)]);return[self p6_URLWithString:s];}
@end

static BOOL interesting(NSString*s){NSString*x=s.lowercaseString; NSArray*k=@[@"webrtc",@"peerconnection",@"rtcpeer",@"hwlls",@"llsplayer",@"signaling",@"signal",@"candidate",@"sdp",@"ice",@"stream",@"player",@"ijk",@"ffmpeg",@"trtc"];for(NSString*q in k)if([x containsString:q])return YES;return NO;}
static NSMutableSet *seenClasses,*seenImages;
static void DumpMethods(Class c){unsigned int n=0;Method*m=class_copyMethodList(c,&n);for(unsigned int i=0;i<n;i++){NSString*s=NSStringFromSelector(method_getName(m[i]));if(interesting(s))L([NSString stringWithFormat:@"[METHOD] %@ -%@",NSStringFromClass(c),s]);}free(m);Class meta=object_getClass(c);m=class_copyMethodList(meta,&n);for(unsigned int i=0;i<n;i++){NSString*s=NSStringFromSelector(method_getName(m[i]));if(interesting(s))L([NSString stringWithFormat:@"[METHOD] %@ +%@",NSStringFromClass(c),s]);}free(m);}
static void ScanClasses(void){int n=objc_getClassList(NULL,0);if(n<=0)return;Class*cs=(Class*)malloc(sizeof(Class)*n);n=objc_getClassList(cs,n);for(int i=0;i<n;i++){Class c=cs[i];NSString*name=NSStringFromClass(c);if(!interesting(name))continue;if([seenClasses containsObject:name])continue;[seenClasses addObject:name];L([NSString stringWithFormat:@"[RUNTIME CLASS] %@ image=%s",name,class_getImageName(c)?:"?"]);DumpMethods(c);}free(cs);}
static void ScanImages(void){uint32_t n=_dyld_image_count();for(uint32_t i=0;i<n;i++){const char*p=_dyld_get_image_name(i);if(!p)continue;NSString*s=[NSString stringWithUTF8String:p];if(!interesting(s))continue;if([seenImages containsObject:s])continue;[seenImages addObject:s];L([NSString stringWithFormat:@"[IMAGE LOADED] %@",s]);}}
static void ImageAdded(const struct mach_header*m,intptr_t slide){(void)m;(void)slide;dispatch_async(dispatch_get_main_queue(),^{ScanImages();ScanClasses();});}
static void Snapshot(NSString*why){L([NSString stringWithFormat:@"[SCAN] %@",why]);ScanImages();ScanClasses();}
__attribute__((constructor))static void Init(void){seenClasses=[NSMutableSet set];seenImages=[NSMutableSet set];L(@"========== PlayURLLoggerV6 RUNTIME SCOUT ==========");L(@"[INIT] V6 loaded; runtime class/image reconnaissance; credentials redacted");_dyld_register_func_for_add_image(ImageAdded);Snapshot(@"startup");for(int i=1;i<=60;i++){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)i*NSEC_PER_SEC),dispatch_get_main_queue(),^{Snapshot([NSString stringWithFormat:@"t+%ds",i]);});}}
