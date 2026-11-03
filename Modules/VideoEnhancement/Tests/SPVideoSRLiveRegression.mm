#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import "SPAppleVideoSR.h"
static CVPixelBufferRef source(int i){
 NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};CVPixelBufferRef b=NULL;
 if(CVPixelBufferCreate(NULL,480,270,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&b)!=kCVReturnSuccess)return NULL;
 CVPixelBufferLockBaseAddress(b,0);uint8_t *base=(uint8_t *)CVPixelBufferGetBaseAddress(b);size_t pitch=CVPixelBufferGetBytesPerRow(b);
 for(int y=0;y<270;y++)for(int x=0;x<480;x++){uint8_t *p=base+y*pitch+x*4;bool white=x>=60+i*8&&x<120+i*8&&y>=60&&y<120;p[0]=p[1]=p[2]=white?240:16;p[3]=255;}
 CVPixelBufferUnlockBaseAddress(b,0);return b;
}
int main(){@autoreleasepool{
 NSError *error=nil;SPAppleVideoSR *sr=[SPAppleVideoSR new];BOOL ready=[sr prepareWidth:480 height:270 scale:4 error:&error];NSMutableArray *frames=[NSMutableArray array];
 VTPixelTransferSessionRef transfer=NULL;VTPixelTransferSessionCreate(NULL,&transfer);
 for(int i=0;i<4&&ready;i++){
  CVPixelBufferRef input=source(i);dispatch_semaphore_t done=dispatch_semaphore_create(0);__block CVPixelBufferRef output=NULL;__block NSError *failure=nil;__block uint64_t returned=0;
  BOOL accepted=[sr submitSource:input pts:CMTimeMake(i,30) discontinuity:i==2 token:i+1 completion:^(uint64_t token,CVPixelBufferRef image,double seconds,NSError *local){(void)seconds;returned=token;output=image;failure=local;dispatch_semaphore_signal(done);}];
  if(accepted)dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);CVPixelBufferRelease(input);
  CVPixelBufferRef rgb=NULL;NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};if(output)CVPixelBufferCreate(NULL,1920,1080,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&rgb);
  OSStatus converted=rgb?VTPixelTransferSessionTransferImage(transfer,output,rgb):-1;double sum=0;long count=0;
  if(converted==noErr){CVPixelBufferLockBaseAddress(rgb,kCVPixelBufferLock_ReadOnly);uint8_t *base=(uint8_t *)CVPixelBufferGetBaseAddress(rgb);size_t pitch=CVPixelBufferGetBytesPerRow(rgb);for(int y=200;y<560;y+=2)for(int x=0;x<1920;x+=2){uint8_t *p=base+y*pitch+x*4;if(p[0]>180&&p[1]>180&&p[2]>180){sum+=x;count++;}}CVPixelBufferUnlockBaseAddress(rgb,kCVPixelBufferLock_ReadOnly);}
  double center=count?sum/count:-1;BOOL ok=accepted&&!failure&&returned==(uint64_t)i+1&&output&&CVPixelBufferGetWidth(output)==1920&&CVPixelBufferGetHeight(output)==1080&&converted==noErr&&count>1000&&fabs(center-(90+i*8)*4)<16;
  [frames addObject:@{@"index":@(i),@"ok":@(ok),@"discontinuity":@(i==2),@"center":@(center),@"error":failure.localizedDescription?:@""}];if(rgb)CVPixelBufferRelease(rgb);if(output)CVPixelBufferRelease(output);if(!ok)break;
 }
 [sr invalidate];CVPixelBufferRef input=source(0);BOOL rejected=![sr submitSource:input pts:CMTimeMake(0,30) discontinuity:NO token:9 completion:^(uint64_t t,CVPixelBufferRef o,double s,NSError *e){(void)t;(void)s;(void)e;if(o)CVPixelBufferRelease(o);}];CVPixelBufferRelease(input);if(transfer)CFRelease(transfer);
 BOOL ok=ready&&frames.count==4&&rejected;for(NSDictionary *entry in frames)ok=ok&&[entry[@"ok"] boolValue];
 NSDictionary *report=@{@"ok":@(ok),@"prepared":@(ready),@"error":error.localizedDescription?:@"",@"frames":frames,@"invalidatedRejects":@(rejected),@"note":@"Synthetic temporal component only; no application integration, real source, output quality or performance acceptance."};NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];fwrite(data.bytes,1,data.length,stdout);return ok?0:1;
}}
