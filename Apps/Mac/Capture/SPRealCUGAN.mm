#import "SPRealCUGAN.h"
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#include <vector>
#include <new>

static NSError *SPCUGANError(NSInteger code, NSString *message) { return [NSError errorWithDomain:@"app.openduckframe.realcugan" code:code userInfo:@{NSLocalizedDescriptionKey:message}]; }
static NSURL *SPCUGANResource(NSBundle *bundle,NSString *name,NSString *ext) {
    NSURL *url=[bundle URLForResource:name withExtension:ext subdirectory:@"RealCUGAN"];
    return url ?: [bundle URLForResource:name withExtension:ext];
}
static BOOL SPCUGANCheckHash(NSURL *url,NSString *expected) {
    NSData *data=[NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];if(!data)return NO;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hex=[NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hex appendFormat:@"%02x",digest[i]];
    return [hex isEqualToString:expected];
}
struct SPCUGANAPI {
    void *library=nullptr;int (*version)()=nullptr;void *(*create)(const char *,const char *,int *)=nullptr;
    int (*process)(void *,const uint8_t *,int,int,uint8_t *)=nullptr;void (*destroy)(void *)=nullptr;
    bool open(NSString *path){library=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);if(!library)return false;
#define LOAD(field,name) field=reinterpret_cast<decltype(field)>(dlsym(library,name));if(!field)return false
      LOAD(version,"odf_realcugan_abi_version");LOAD(create,"odf_realcugan_create");LOAD(process,"odf_realcugan_process");LOAD(destroy,"odf_realcugan_destroy");
#undef LOAD
      return version()==1;
    }
    void close(){if(library)dlclose(library);library=nullptr;}
};
@implementation SPRealCUGAN {
    NSBundle *_resourceBundle;dispatch_queue_t _queue;SPCUGANAPI _api;void *_model;int _width,_height;uint64_t _epoch;BOOL _running,_inflight;
}
- (instancetype)init {return [self initWithResourceBundle:NSBundle.mainBundle];}
- (instancetype)initWithResourceBundle:(NSBundle *)bundle {if(!(self=[super init]))return nil;_resourceBundle=bundle;_queue=dispatch_queue_create("app.openduckframe.realcugan",DISPATCH_QUEUE_SERIAL);return self;}
+ (BOOL)isPackagedForThisSystem {return [self isPackagedInBundle:NSBundle.mainBundle];}
+ (BOOL)isPackagedInBundle:(NSBundle *)bundle {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27) return NO;
    NSString *frameworks=bundle.privateFrameworksPath;
    for(NSString *name in @[@"libodf_realcugan.dylib",@"libMoltenVK.dylib"])if(![[NSFileManager defaultManager] fileExistsAtPath:[frameworks stringByAppendingPathComponent:name]])return NO;
    return SPCUGANResource(bundle,@"up2x-no-denoise",@"param") && SPCUGANResource(bundle,@"up2x-no-denoise",@"bin");
}
- (void)closeOnQueue {if(_model&&_api.destroy)_api.destroy(_model);_model=nullptr;_api.close();}
- (BOOL)prepareWidth:(int)width height:(int)height variant:(NSString *)variant error:(NSError **)error {
    if(width<2||height<2||width>1920||height>1080){if(error)*error=SPCUGANError(1,@"Real-CUGAN 的 2× 输出超出当前尺寸预算。");return NO;}
    if(![self.class isPackagedInBundle:_resourceBundle]){if(error)*error=SPCUGANError(2,@"当前安装包的 Real-CUGAN 运行库需要 macOS 27，或模型、运行库缺失。");return NO;}
    NSDictionary *variants=@{
        @"none":@[@"up2x-no-denoise",@"c370b70321d45301b9c682121130ad167b3dd1bc8e122c1d77c7ac44f1943708",@"2b6f4db8fdc04336ac68ba954b4cd3b280beb5e7b6b0bcd97f769accc512cf4a"],
        @"light":@[@"up2x-denoise1x",@"4b3b5c5710ad1d00503c8243417aa75f13fe497723e8b4952e8b1abfc08f9b84",@"09373c4fddfd2a57fb4af5e516eba1b4c9caa132fd52ffd01bcaefee543bf7f6"],
        @"medium":@[@"up2x-denoise2x",@"4b3b5c5710ad1d00503c8243417aa75f13fe497723e8b4952e8b1abfc08f9b84",@"47427a52badebfbd7bb6db97196a2844c553f7f2bb93c9527b26347bea0430e7"],
        @"strong":@[@"up2x-denoise3x",@"4b3b5c5710ad1d00503c8243417aa75f13fe497723e8b4952e8b1abfc08f9b84",@"610ebae63f388fe6f39615cc5f4eaeb038d5aa6ba8b299ba3b989f7f7a1a280a"]
    };
    NSArray *entry=variants[variant];
    if(!entry){if(error)*error=SPCUGANError(3,@"Real-CUGAN 降噪档位无效。");return NO;}
    NSURL *param=SPCUGANResource(_resourceBundle,entry[0],@"param"),*weight=SPCUGANResource(_resourceBundle,entry[0],@"bin");
    if(!param||!weight||!SPCUGANCheckHash(param,entry[1])||!SPCUGANCheckHash(weight,entry[2])){if(error)*error=SPCUGANError(3,@"Real-CUGAN 模型缺失或校验失败。");return NO;}
    __block BOOL ok=NO;dispatch_sync(_queue,^{
        @synchronized(self){if(self->_running||self->_inflight)return;}
        NSString *path=[self->_resourceBundle.privateFrameworksPath stringByAppendingPathComponent:@"libodf_realcugan.dylib"];
        if(!self->_api.open(path)){[self closeOnQueue];return;}
        int status=-1;self->_model=self->_api.create(param.fileSystemRepresentation,weight.fileSystemRepresentation,&status);
        if(!self->_model||status!=0){[self closeOnQueue];return;}
        self->_width=width;self->_height=height;@synchronized(self){self->_running=YES;self->_epoch++;}ok=YES;
    });if(!ok&&error)*error=SPCUGANError(4,@"Real-CUGAN 模型或 GPU 会话准备失败。");return ok;
}
- (BOOL)submitSource:(CVPixelBufferRef)source pts:(CMTime)pts token:(uint64_t)token completion:(SPFRCEngineCompletion)completion {
    if(!source||!completion||!CMTIME_IS_NUMERIC(pts)||CVPixelBufferGetPixelFormatType(source)!=kCVPixelFormatType_32BGRA)return NO;
    __block uint64_t seen;@synchronized(self){if(!_running||_inflight||CVPixelBufferGetWidth(source)!=(size_t)_width||CVPixelBufferGetHeight(source)!=(size_t)_height)return NO;_inflight=YES;seen=_epoch;}
    CVPixelBufferRetain(source);dispatch_async(_queue,^{
        CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();CVPixelBufferRef output=NULL;NSError *failure=nil;BOOL stale;@synchronized(self){stale=seen!=self->_epoch;}
        if(!stale){
            try {
                std::vector<uint8_t> rgb((size_t)self->_width*self->_height*3), upscaled((size_t)self->_width*self->_height*12);
                CVPixelBufferLockBaseAddress(source,kCVPixelBufferLock_ReadOnly);const uint8_t *pixels=(const uint8_t *)CVPixelBufferGetBaseAddress(source);size_t pitch=CVPixelBufferGetBytesPerRow(source);
                for(int y=0;y<self->_height;y++)for(int x=0;x<self->_width;x++){const uint8_t *p=pixels+y*pitch+x*4;size_t i=((size_t)y*self->_width+x)*3;rgb[i]=p[2];rgb[i+1]=p[1];rgb[i+2]=p[0];}
                CVPixelBufferUnlockBaseAddress(source,kCVPixelBufferLock_ReadOnly);
                int rc=self->_api.process(self->_model,rgb.data(),self->_width,self->_height,upscaled.data());
                if(rc!=0)failure=SPCUGANError(5,@"Real-CUGAN 推理失败。");
                else {NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
                    if(CVPixelBufferCreate(NULL,self->_width*2,self->_height*2,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&output)!=kCVReturnSuccess||!output)failure=SPCUGANError(6,@"Real-CUGAN 输出画面分配失败。");
                    else {CVBufferPropagateAttachments(source,output);CVPixelBufferLockBaseAddress(output,0);uint8_t *dst=(uint8_t *)CVPixelBufferGetBaseAddress(output);size_t stride=CVPixelBufferGetBytesPerRow(output);int w=self->_width*2,h=self->_height*2;
                        for(int y=0;y<h;y++)for(int x=0;x<w;x++){uint8_t *p=dst+y*stride+x*4;size_t i=((size_t)y*w+x)*3;p[0]=upscaled[i+2];p[1]=upscaled[i+1];p[2]=upscaled[i];p[3]=255;}CVPixelBufferUnlockBaseAddress(output,0);}
                }
            } catch (const std::bad_alloc &) { failure=SPCUGANError(7,@"Real-CUGAN 内存不足。"); }
        }
        @synchronized(self){stale=seen!=self->_epoch;self->_inflight=NO;}
        if(stale){if(output)CVPixelBufferRelease(output);output=NULL;failure=SPCUGANError(8,@"Real-CUGAN 结果属于已结束的会话。");[self closeOnQueue];}
        CVPixelBufferRelease(source);completion(token,output,MAX(0,CFAbsoluteTimeGetCurrent()-start),failure);
    });return YES;
}
- (void)invalidate {BOOL active;@synchronized(self){_epoch++;_running=NO;active=_inflight;}if(!active)dispatch_async(_queue,^{[self closeOnQueue];});}
- (void)dealloc {if(_model||_api.library)[self closeOnQueue];}
@end
