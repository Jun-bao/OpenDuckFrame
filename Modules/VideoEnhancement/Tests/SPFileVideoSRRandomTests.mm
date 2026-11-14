#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "SPFileAppleVideoSRScaler.h"
#include <initializer_list>
#include <cmath>
static CVPixelBufferRef source(int frame,int color,BOOL full){
 NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};CVPixelBufferRef b=NULL;OSType format=full?kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
 if(CVPixelBufferCreate(NULL,480,270,format,(__bridge CFDictionaryRef)attrs,&b)!=kCVReturnSuccess)return NULL;
 CVBufferSetAttachment(b,kCVImageBufferYCbCrMatrixKey,color?kCVImageBufferYCbCrMatrix_ITU_R_601_4:kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
 CVBufferSetAttachment(b,kCVImageBufferColorPrimariesKey,color==2?kCVImageBufferColorPrimaries_EBU_3213:(color==1?kCVImageBufferColorPrimaries_SMPTE_C:kCVImageBufferColorPrimaries_ITU_R_709_2),kCVAttachmentMode_ShouldPropagate);
 CVBufferSetAttachment(b,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
 CVPixelBufferLockBaseAddress(b,0);size_t sy=CVPixelBufferGetBytesPerRowOfPlane(b,0),su=CVPixelBufferGetBytesPerRowOfPlane(b,1);auto y=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(b,0),u=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(b,1);memset(y,120,sy*270);for(int r=0;r<135;r++)for(int c=0;c<480;c+=2){u[r*su+c]=85;u[r*su+c+1]=200;}if(frame)for(int yy=60;yy<120;yy++)for(int xx=60+frame*8;xx<120+frame*8;xx++)y[yy*sy+xx]=220;CVPixelBufferUnlockBaseAddress(b,0);return b;
}
static BOOL boundedOutputPool() {
 NSError *error=nil; SPFileAppleVideoSRScaler *scaler=[[SPFileAppleVideoSRScaler alloc] initWithSourceWidth:480 sourceHeight:270 outputWidth:1920 outputHeight:1080 error:&error];
 if(!scaler)return NO;
 CVPixelBufferRef held[4]={}; BOOL ok=YES;
 for(int i=0;i<6;i++){
  if(i==5&&held[0]){CVPixelBufferRelease(held[0]);held[0]=NULL;}
  CVPixelBufferRef input=source(i%3,0,NO); dispatch_semaphore_t done=dispatch_semaphore_create(0);
  __block CVPixelBufferRef output=NULL; __block NSError *failure=nil;
  BOOL accepted=[scaler submit:input ptsUs:1000000+i*33333 completion:^(CVPixelBufferRef b,NSError *e){output=b;failure=e;dispatch_semaphore_signal(done);}];
  BOOL finished=accepted&&dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC))==0;
  CVPixelBufferRelease(input);
  if(i<4){ok &=finished&&output&&!failure;held[i]=output;}
  else {ok &=finished&&(i==4 ? (!output&&failure!=nil) : (output&&!failure));if(output)CVPixelBufferRelease(output);}
 }
 for(auto b:held)if(b)CVPixelBufferRelease(b);
 return ok;
}
static BOOL recycledAttachments() {
 NSError *error=nil; SPFileAppleVideoSRScaler *scaler=[[SPFileAppleVideoSRScaler alloc] initWithSourceWidth:480 sourceHeight:270 outputWidth:1920 outputHeight:1080 error:&error];
 if(!scaler)return NO;
 BOOL ok=YES; CFStringRef key=CFSTR("OpenDuckFrame.test.stale-attachment");
 for(int i=0;i<6;i++){
  CVPixelBufferRef input=source(i%3,i%2,NO); if(i==0)CVBufferSetAttachment(input,key,CFSTR("first"),kCVAttachmentMode_ShouldPropagate);
  dispatch_semaphore_t done=dispatch_semaphore_create(0); __block CVPixelBufferRef output=NULL; __block NSError *failure=nil;
  BOOL accepted=[scaler submit:input ptsUs:1000000+i*33333 completion:^(CVPixelBufferRef b,NSError *e){output=b;failure=e;dispatch_semaphore_signal(done);}];
  BOOL finished=accepted&&dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC))==0;
  CFTypeRef matrix=output?CVBufferCopyAttachment(output,kCVImageBufferYCbCrMatrixKey,NULL):NULL;
  CFTypeRef extra=output?CVBufferCopyAttachment(output,key,NULL):NULL;
  ok &=finished&&output&&!failure&&matrix&&CFEqual(matrix,i%2?kCVImageBufferYCbCrMatrix_ITU_R_601_4:kCVImageBufferYCbCrMatrix_ITU_R_709_2)&&(i==0?extra!=NULL:extra==NULL);
  if(matrix)CFRelease(matrix);if(extra)CFRelease(extra);if(output)CVPixelBufferRelease(output);CVPixelBufferRelease(input);
 }
 return ok;
}
int main(){@autoreleasepool{
 BOOL all=YES;
 for(int color=0;color<3;color++)for(int full=0;full<2;full++){
  NSError *error=nil;SPFileAppleVideoSRScaler *scaler=[[SPFileAppleVideoSRScaler alloc] initWithSourceWidth:480 sourceHeight:270 outputWidth:1920 outputHeight:1080 error:&error];if(!scaler){fprintf(stderr,"prepare %s\n",error.localizedDescription.UTF8String);return 2;}
  BOOL valid=YES;int yuv[3]={-1,-1,-1};
  for(int i=0;i<3;i++){
   CVPixelBufferRef input=source(i,color,full);dispatch_semaphore_t done=dispatch_semaphore_create(0);__block CVPixelBufferRef output=NULL;__block NSError *failure=nil;
   int64_t pts=1000000+i*33333;BOOL accepted=[scaler submit:input ptsUs:pts completion:^(CVPixelBufferRef b,NSError *e){output=b;failure=e;dispatch_semaphore_signal(done);}];BOOL finished=accepted&&dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC))==0&&!failure&&output;
   BOOL frameOK=finished&&CVPixelBufferGetWidth(output)==1920&&CVPixelBufferGetHeight(output)==1080&&CVPixelBufferGetPixelFormatType(output)==CVPixelBufferGetPixelFormatType(input);
   for(CFStringRef key:{kCVImageBufferYCbCrMatrixKey,kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey}){CFTypeRef a=CVBufferCopyAttachment(input,key,NULL),b=output?CVBufferCopyAttachment(output,key,NULL):NULL;frameOK &=a&&b&&CFEqual(a,b);if(a)CFRelease(a);if(b)CFRelease(b);}
   if(output&&i==0){CVPixelBufferLockBaseAddress(output,kCVPixelBufferLock_ReadOnly);auto y=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(output,0),u=(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(output,1);yuv[0]=y[540*CVPixelBufferGetBytesPerRowOfPlane(output,0)+960];u+=270*CVPixelBufferGetBytesPerRowOfPlane(output,1)+960;yuv[1]=u[0];yuv[2]=u[1];CVPixelBufferUnlockBaseAddress(output,kCVPixelBufferLock_ReadOnly);}
   if(output)CVPixelBufferRelease(output);CVPixelBufferRelease(input);valid &=frameOK;
  }
  CVPixelBufferRef invalid=source(0,color,full);dispatch_semaphore_t rejected=dispatch_semaphore_create(0);__block BOOL badPTS=NO;
  [scaler submit:invalid ptsUs:INT64_MIN completion:^(CVPixelBufferRef b,NSError *e){badPTS=!b&&e;if(b)CVPixelBufferRelease(b);dispatch_semaphore_signal(rejected);}];
  badPTS &=dispatch_semaphore_wait(rejected,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0;
  CVBufferSetAttachment(invalid,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_2020,kCVAttachmentMode_ShouldPropagate);dispatch_semaphore_t rejectedColor=dispatch_semaphore_create(0);__block BOOL badColor=NO;
  [scaler submit:invalid ptsUs:2000000 completion:^(CVPixelBufferRef b,NSError *e){badColor=!b&&e;if(b)CVPixelBufferRelease(b);dispatch_semaphore_signal(rejectedColor);}];
  badColor &=dispatch_semaphore_wait(rejectedColor,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0;CVPixelBufferRelease(invalid);
  NSDictionary *d=scaler.submissionDiagnostics;BOOL randomOnly=[d[@"random"] unsignedIntegerValue]==3&&[d[@"sequential"] unsignedIntegerValue]==0&&[d[@"history"] unsignedIntegerValue]==0&&![d[@"temporal"] boolValue]&&![d[@"previous"] boolValue]&&![d[@"previousOutput"] boolValue]&&[d[@"mode"] isEqualToString:@"Random"];
  BOOL colorOK=abs(yuv[0]-120)<=8&&abs(yuv[1]-85)<=8&&abs(yuv[2]-200)<=8;BOOL ok=valid&&randomOnly&&colorOK&&badPTS&&badColor;all &=ok;
  printf("{\"ok\":%s,\"matrix\":\"%s\",\"range\":\"%s\",\"frames\":3,\"colorYUV\":[%d,%d,%d],\"random\":%lu,\"sequential\":%lu,\"history\":%lu,\"temporal\":false,\"badPTSRejected\":%s,\"badColorRejected\":%s,\"scope\":\"actual VT Random scaler source and synthetic patterns; no file GUI/drawable/AV\"}\n",ok?"true":"false",color==2?"601-ebu":(color==1?"601":"709"),full?"full":"video",yuv[0],yuv[1],yuv[2],(unsigned long)[d[@"random"] unsignedIntegerValue],(unsigned long)[d[@"sequential"] unsignedIntegerValue],(unsigned long)[d[@"history"] unsignedIntegerValue],badPTS?"true":"false",badColor?"true":"false");
 }
 BOOL bounded=boundedOutputPool(), attachments=recycledAttachments();printf("{\"boundedOutputPool\":%s,\"recycledAttachments\":%s}\n",bounded?"true":"false",attachments?"true":"false");
 return all&&bounded&&attachments?0:1;
}}
