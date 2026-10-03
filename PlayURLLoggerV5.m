#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *P(void){ NSString *d=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject; return [d stringByAppendingPathComponent:@"PlayURLLoggerV5.txt"]; }
static void L(NSString *s){ if(!s.length)return; NSString *x=[NSString stringWithFormat:@"[%@] %@\n",[NSDate date],s]; NSData *d=[x dataUsingEncoding:NSUTF8StringEncoding]; @synchronized([NSFileHandle class]){ if(![[NSFileManager defaultManager] fileExistsAtPath:P()]){[d writeToFile:P() atomically:YES];return;} NSFileHandle*h=[NSFileHandle fileHandleForWritingAtPath:P()];[h seekToEndOfFile];[h writeData:d];[h closeFile]; } }
static NSString *D(id x){ if(!x)return @"<nil>"; @try{return [x description]?:@"<no description>";}@catch(...){return @"<description threw>";} }
static NSString *Redact(NSString *s){ if(!s)return @"<nil>"; NSMutableString*m=[s mutableCopy]; NSArray*keys=@[@"txSecret",@"token",@"access_token",@"authorization",@"cookie",@"password",@"passwd",@"secret",@"credential"];
 for(NSString*k in keys){ NSRegularExpression*r=[NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"(?i)(%@\\s*[=:]\\s*)([^&\\s,;\\\"}]+)",[NSRegularExpression escapedPatternForString:k]] options:0 error:nil]; [r replaceMatchesInString:m options:0 range:NSMakeRange(0,m.length) withTemplate:@"$1<redacted>"]; } return m; }
static void Candidate(NSString*s){ NSString*l=s.lowercaseString; if([l containsString:@".m3u8"]||[l containsString:@".flv"]||[l hasPrefix:@"rtmp://"]||[l hasPrefix:@"rtmps://"]) L([NSString stringWithFormat:@"[PC-CANDIDATE] %@",Redact(s)]); }
static void Stack(NSString*t){ NSArray*a=[NSThread callStackSymbols]; for(NSUInteger i=0;i<MIN((NSUInteger)8,a.count);i++)L([NSString stringWithFormat:@"[%@ STACK %02lu] %@",t,(unsigned long)i,a[i]]); }

@interface NSURL(PULV5) @end
@implementation NSURL(PULV5)
+(void)load{ Method a=class_getClassMethod(self,@selector(URLWithString:)),b=class_getClassMethod(self,@selector(p5_URLWithString:)); if(a&&b)method_exchangeImplementations(a,b); }
+(instancetype)p5_URLWithString:(NSString*)s{ if(s.length){L([NSString stringWithFormat:@"[URL] %@",Redact(s)]);Candidate(s);} return [self p5_URLWithString:s]; }
@end

static BOOL H(Class c,SEL s,IMP n,IMP*o,NSString*lab){ if(!c)return NO; Method m=class_getInstanceMethod(c,s);if(!m)return NO;IMP cur=method_getImplementation(m);if(cur==n)return YES;if(o&&!*o)*o=cur;method_setImplementation(m,n);L([NSString stringWithFormat:@"[HOOKED] %@ %@",NSStringFromClass(c),lab]);return YES; }

static IMP oHW=NULL; static void hHW(id self,SEL c,id v){NSString*s=Redact(D(v));L([NSString stringWithFormat:@"[HWLLS streamUrl] %@",s]);Candidate(s);Stack(@"HWLLS");if(oHW)((void(*)(id,SEL,id))oHW)(self,c,v);}
static IMP oI1=NULL; static id hI1(id s,SEL c,id v){NSString*x=Redact(D(v));L([NSString stringWithFormat:@"[IJK URLString] %@",x]);Candidate(x);return oI1?((id(*)(id,SEL,id))oI1)(s,c,v):s;}
static IMP oI2=NULL; static id hI2(id s,SEL c,id v,id op){NSString*x=Redact(D(v));L([NSString stringWithFormat:@"[IJK URLString+Options] URL=%@ OPTIONS=%@",x,Redact(D(op))]);Candidate(x);return oI2?((id(*)(id,SEL,id,id))oI2)(s,c,v,op):s;}
static IMP oI3=NULL; static id hI3(id s,SEL c,id v){NSString*x=Redact(D(v));L([NSString stringWithFormat:@"[IJK URL] %@",x]);Candidate(x);return oI3?((id(*)(id,SEL,id))oI3)(s,c,v):s;}
static IMP oI4=NULL; static id hI4(id s,SEL c,id v,id op){NSString*x=Redact(D(v));L([NSString stringWithFormat:@"[IJK URL+Options] URL=%@ OPTIONS=%@",x,Redact(D(op))]);Candidate(x);return oI4?((id(*)(id,SEL,id,id))oI4)(s,c,v,op):s;}

// WebRTC Objective-C API. We intentionally summarize SDP/candidates and redact credentials.
static NSString *SDPSummary(id sdp){ NSString*x=D(sdp); @try{ id t=[sdp valueForKey:@"type"]; id body=[sdp valueForKey:@"sdp"]; if(body){ NSString*b=D(body); NSMutableArray*lines=[NSMutableArray array]; for(NSString*l in [b componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]){ NSString*q=[l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; if([q hasPrefix:@"m="]||[q hasPrefix:@"a=rtpmap:"]||[q hasPrefix:@"a=fmtp:"]||[q hasPrefix:@"a=group:"]||[q hasPrefix:@"a=mid:"]||[q hasPrefix:@"a=setup:"]) [lines addObject:q]; } return [NSString stringWithFormat:@"type=%@ media={%@}",D(t),[lines componentsJoinedByString:@" | "]]; } }@catch(...){} return Redact(x); }
static NSString *ICESummary(id cand){ @try{ id mid=[cand valueForKey:@"sdpMid"]; id idx=[cand valueForKey:@"sdpMLineIndex"]; id sd=[cand valueForKey:@"sdp"]; NSString*x=D(sd); NSArray*p=[x componentsSeparatedByString:@" "]; NSString*typ=@"?",*proto=@"?"; if(p.count>2)proto=p[2]; NSUInteger i=[p indexOfObject:@"typ"];if(i!=NSNotFound&&i+1<p.count)typ=p[i+1]; return [NSString stringWithFormat:@"mid=%@ mline=%@ protocol=%@ type=%@",D(mid),D(idx),proto,typ]; }@catch(...){return @"<candidate>";} }
static IMP oSR=NULL; static void hSR(id s,SEL c,id d,id cb){L([NSString stringWithFormat:@"[WEBRTC setRemoteDescription] %@",SDPSummary(d)]);if(oSR)((void(*)(id,SEL,id,id))oSR)(s,c,d,cb);}
static IMP oSL=NULL; static void hSL(id s,SEL c,id d,id cb){L([NSString stringWithFormat:@"[WEBRTC setLocalDescription] %@",SDPSummary(d)]);if(oSL)((void(*)(id,SEL,id,id))oSL)(s,c,d,cb);}
static IMP oAI=NULL; static void hAI(id s,SEL c,id d,id cb){L([NSString stringWithFormat:@"[WEBRTC addIceCandidate] %@",ICESummary(d)]);if(oAI)((void(*)(id,SEL,id,id))oAI)(s,c,d,cb);}
static IMP oAIOld=NULL; static void hAIOld(id s,SEL c,id d){L([NSString stringWithFormat:@"[WEBRTC addIceCandidate-old] %@",ICESummary(d)]);if(oAIOld)((void(*)(id,SEL,id))oAIOld)(s,c,d);}
static IMP oCFG=NULL; static BOOL hCFG(id s,SEL c,id cfg){ NSString*x=Redact(D(cfg)); L([NSString stringWithFormat:@"[WEBRTC configuration] %@",x]); return oCFG?((BOOL(*)(id,SEL,id))oCFG)(s,c,cfg):NO; }

static void Install(void){
 Class hw=objc_getClass("HWLLSPlayer"); H(hw,NSSelectorFromString(@"setStreamUrl:"),(IMP)hHW,&oHW,@"setStreamUrl:");
 Class ijk=objc_getClass("IJKFFMoviePlayerController"); H(ijk,NSSelectorFromString(@"initWithContentURLString:"),(IMP)hI1,&oI1,@"initWithContentURLString:"); H(ijk,NSSelectorFromString(@"initWithContentURLString:withOptions:"),(IMP)hI2,&oI2,@"initWithContentURLString:withOptions:"); H(ijk,NSSelectorFromString(@"initWithContentURL:"),(IMP)hI3,&oI3,@"initWithContentURL:"); H(ijk,NSSelectorFromString(@"initWithContentURL:withOptions:"),(IMP)hI4,&oI4,@"initWithContentURL:withOptions:");
 Class pc=objc_getClass("RTCPeerConnection"); H(pc,NSSelectorFromString(@"setRemoteDescription:completionHandler:"),(IMP)hSR,&oSR,@"setRemoteDescription:completionHandler:"); H(pc,NSSelectorFromString(@"setLocalDescription:completionHandler:"),(IMP)hSL,&oSL,@"setLocalDescription:completionHandler:"); H(pc,NSSelectorFromString(@"addIceCandidate:completionHandler:"),(IMP)hAI,&oAI,@"addIceCandidate:completionHandler:"); H(pc,NSSelectorFromString(@"addIceCandidate:"),(IMP)hAIOld,&oAIOld,@"addIceCandidate:"); H(pc,NSSelectorFromString(@"setConfiguration:"),(IMP)hCFG,&oCFG,@"setConfiguration:");
}
__attribute__((constructor)) static void Init(void){L(@"========== PlayURLLoggerV5 SESSION ==========");L(@"[INIT] V5 loaded; sensitive credentials are redacted");Install();for(int i=1;i<=30;i++)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)i*NSEC_PER_SEC),dispatch_get_main_queue(),^{Install();});}
