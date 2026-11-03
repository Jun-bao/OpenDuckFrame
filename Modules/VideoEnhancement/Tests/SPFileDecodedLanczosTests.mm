#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import "SPFileLanczosScaler.h"

int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=2) return 2;
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]] options:nil];
    AVAssetTrack *video=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *audio=[asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if(!video || !audio) { fprintf(stderr,"fixture must contain video and audio\n"); return 3; }
    NSError *error=nil;AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:asset error:&error];
    NSDictionary *videoSettings=@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    AVAssetReaderTrackOutput *videoOut=[[AVAssetReaderTrackOutput alloc] initWithTrack:video outputSettings:videoSettings];
    AVAssetReaderTrackOutput *audioOut=[[AVAssetReaderTrackOutput alloc] initWithTrack:audio outputSettings:@{AVFormatIDKey:@(kAudioFormatLinearPCM)}];
    if(![reader canAddOutput:videoOut] || ![reader canAddOutput:audioOut]) return 4;
    [reader addOutput:videoOut];[reader addOutput:audioOut];if(![reader startReading]) return 5;
    SPFileLanczosScaler *scaler=[[SPFileLanczosScaler alloc] initWithDevice:MTLCreateSystemDefaultDevice() width:640 height:384 error:&error];
    if(!scaler) return 6;
    CMTime previous=kCMTimeInvalid; int frames=0; bool monotonic=true,dimensions=true,format=true;
    while(frames<6) {
        CMSampleBufferRef sample=[videoOut copyNextSampleBuffer];if(!sample) break;
        CMTime pts=CMSampleBufferGetPresentationTimeStamp(sample);
        if(CMTIME_IS_VALID(previous) && CMTimeCompare(pts,previous)<=0) monotonic=false;
        previous=pts;CVPixelBufferRef input=CMSampleBufferGetImageBuffer(sample);if(!input){CFRelease(sample);break;}
        OSType sourceFormat=CVPixelBufferGetPixelFormatType(input);
        dispatch_semaphore_t done=dispatch_semaphore_create(0);__block CVPixelBufferRef result=NULL;__block NSError *failure=nil;
        if(![scaler submit:input completion:^(CVPixelBufferRef buffer,NSError *e){result=buffer;failure=e;dispatch_semaphore_signal(done);}]) { CFRelease(sample);break; }
        if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC))!=0) { CFRelease(sample);return 7; }
        if(!result) { fprintf(stderr,"scale failed: %s\n",failure.localizedDescription.UTF8String);CFRelease(sample);return 8; }
        dimensions &= CVPixelBufferGetWidth(result)==640 && CVPixelBufferGetHeight(result)==384;
        format &= CVPixelBufferGetPixelFormatType(result)==sourceFormat;
        CVPixelBufferRelease(result);CFRelease(sample);frames++;
    }
    CMSampleBufferRef sound=[audioOut copyNextSampleBuffer];bool audioPresent=sound!=NULL;
    double audioPTS=sound?CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sound)):-1;
    if(sound)CFRelease(sound);[reader cancelReading];
    bool ok=frames==6 && monotonic && dimensions && format && audioPresent;
    printf("{\"ok\":%s,\"decodedVideoFrames\":%d,\"monotonicPTS\":%s,\"size640x384\":%s,\"sameNV12Range\":%s,\"audioTrackDecoded\":%s,\"audioFirstPTS\":%.6f,\"scope\":\"headless real-file decode and GPU scaling; no player, drawable presentation, audible playback or A/V sync measurement\"}\n",ok?"true":"false",frames,monotonic?"true":"false",dimensions?"true":"false",format?"true":"false",audioPresent?"true":"false",audioPTS);
    return ok?0:9;
}}
