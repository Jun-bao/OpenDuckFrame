#import "SPAnime4K.h"
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>
#include <libplacebo/vulkan.h>
#include <libplacebo/gpu.h>
#include <libplacebo/renderer.h>
#include <libplacebo/shaders/custom.h>
#include <libplacebo/colorspace.h>

static NSError *SPAnimeError(NSInteger code, NSString *message) { return [NSError errorWithDomain:@"app.openduckframe.anime4k" code:code userInfo:@{NSLocalizedDescriptionKey:message}]; }
struct SPAnimeAPI {
    void *library=nullptr;
    decltype(&pl_vulkan_create) vulkanCreate=nullptr; decltype(&pl_vulkan_destroy) vulkanDestroy=nullptr;
    decltype(&pl_find_named_fmt) findFormat=nullptr; decltype(&pl_mpv_user_shader_parse) shaderParse=nullptr; decltype(&pl_mpv_user_shader_destroy) shaderDestroy=nullptr;
    decltype(&pl_renderer_create) rendererCreate=nullptr; decltype(&pl_renderer_destroy) rendererDestroy=nullptr;
    decltype(&pl_renderer_get_errors) rendererErrors=nullptr; decltype(&pl_render_image) render=nullptr;
    decltype(&pl_tex_create) textureCreate=nullptr; decltype(&pl_tex_destroy) textureDestroy=nullptr; decltype(&pl_gpu_finish) finish=nullptr;
    const struct pl_color_repr *repr=nullptr; const struct pl_color_space *colorspace=nullptr; const struct pl_render_params *defaults=nullptr;
    bool open(NSString *path) {
        library=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL); if(!library)return false;
#define LOAD(field, symbol) field=reinterpret_cast<decltype(field)>(dlsym(library, symbol)); if(!field)return false
        LOAD(vulkanCreate,"pl_vulkan_create"); LOAD(vulkanDestroy,"pl_vulkan_destroy"); LOAD(findFormat,"pl_find_named_fmt");
        LOAD(shaderParse,"pl_mpv_user_shader_parse"); LOAD(shaderDestroy,"pl_mpv_user_shader_destroy");
        LOAD(rendererCreate,"pl_renderer_create"); LOAD(rendererDestroy,"pl_renderer_destroy"); LOAD(rendererErrors,"pl_renderer_get_errors");
        LOAD(render,"pl_render_image"); LOAD(textureCreate,"pl_tex_create"); LOAD(textureDestroy,"pl_tex_destroy"); LOAD(finish,"pl_gpu_finish");
        LOAD(repr,"pl_color_repr_rgb"); LOAD(colorspace,"pl_color_space_bt709"); LOAD(defaults,"pl_render_default_params");
#undef LOAD
        return true;
    }
    void close(){if(library)dlclose(library);library=nullptr;}
};
@implementation SPAnime4K {
    dispatch_queue_t _queue;
    NSBundle *_resourceBundle;
    SPAnimeAPI _api;
    pl_vulkan _vulkan;
    pl_renderer _renderer;
    const struct pl_hook *_hook;
    pl_fmt _format;
    int _width,_height;
    uint64_t _epoch;
    BOOL _running,_inflight;
}
- (instancetype)init { return [self initWithResourceBundle:NSBundle.mainBundle]; }
- (instancetype)initWithResourceBundle:(NSBundle *)bundle {if(!(self=[super init]))return nil;_resourceBundle=bundle;_queue=dispatch_queue_create("app.openduckframe.anime4k",DISPATCH_QUEUE_SERIAL);return self;}
+ (BOOL)isPackagedForThisSystem { return [self isPackagedInBundle:NSBundle.mainBundle]; }
+ (BOOL)isPackagedInBundle:(NSBundle *)bundle {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27) return NO;
    NSString *frameworks=bundle.privateFrameworksPath;
    for (NSString *name in @[@"libplacebo.360.dylib",@"libshaderc_shared.1.dylib",@"liblcms2.2.dylib",@"libMoltenVK.dylib"]) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:[frameworks stringByAppendingPathComponent:name]]) return NO;
    }
    return [bundle URLForResource:@"Anime4K_Upscale_CNN_x2_S" withExtension:@"glsl"]!=nil;
}
- (void)closeOnQueue {
    if(_vulkan && _api.finish)_api.finish(_vulkan->gpu);
    if(_renderer && _api.rendererDestroy)_api.rendererDestroy(&_renderer);
    if(_hook && _api.shaderDestroy)_api.shaderDestroy(&_hook);
    if(_vulkan && _api.vulkanDestroy)_api.vulkanDestroy(&_vulkan);
    _format=nullptr;_api.close();
}
- (BOOL)prepareWidth:(int)width height:(int)height error:(NSError **)error {
    if(width<2 || height<2 || (int64_t)width*2>3840 || (int64_t)height*2>2160){if(error)*error=SPAnimeError(1,@"Anime4K 的 2× 输出超出当前尺寸预算。");return NO;}
    if(![self.class isPackagedInBundle:_resourceBundle]){if(error)*error=SPAnimeError(2,@"当前安装包的 Anime4K 运行库需要 macOS 27；其他画质技术仍可使用。");return NO;}
    __block BOOL ok=NO;__block NSString *reason=@"Anime4K 运行库准备失败。";
    dispatch_sync(_queue, ^{
        @synchronized(self){if(self->_running || self->_inflight)return;}
        NSString *path=[self->_resourceBundle.privateFrameworksPath stringByAppendingPathComponent:@"libplacebo.360.dylib"];
        if(!self->_api.open(path)){[self closeOnQueue];return;}
        self->_vulkan=self->_api.vulkanCreate(nullptr,nullptr); if(!self->_vulkan){[self closeOnQueue];return;}
        pl_gpu gpu=self->_vulkan->gpu;
        if(!(gpu->import_caps.tex & PL_HANDLE_IOSURFACE)){reason=@"当前设备无法为 Anime4K 导入画面。";[self closeOnQueue];return;}
        self->_format=self->_api.findFormat(gpu,"bgra8");
        NSData *shader=[NSData dataWithContentsOfURL:[self->_resourceBundle URLForResource:@"Anime4K_Upscale_CNN_x2_S" withExtension:@"glsl"]];
        if(self->_format && shader)self->_hook=self->_api.shaderParse(gpu,(const char *)shader.bytes,shader.length);
        self->_renderer=self->_hook?self->_api.rendererCreate(nullptr,gpu):nullptr;
        if(!self->_renderer){reason=@"Anime4K 画面处理配置不可用。";[self closeOnQueue];return;}
        self->_width=width;self->_height=height;@synchronized(self){self->_running=YES;self->_epoch++;}ok=YES;
    });
    if(!ok&&error)*error=SPAnimeError(3,reason);return ok;
}
- (BOOL)submitSource:(CVPixelBufferRef)source pts:(CMTime)pts token:(uint64_t)token completion:(SPFRCEngineCompletion)completion {
    if(!source||!completion||!CMTIME_IS_NUMERIC(pts)||CVPixelBufferGetPixelFormatType(source)!=kCVPixelFormatType_32BGRA||!CVPixelBufferGetIOSurface(source))return NO;
    __block uint64_t epoch;@synchronized(self){if(!_running||_inflight||CVPixelBufferGetWidth(source)!=(size_t)_width||CVPixelBufferGetHeight(source)!=(size_t)_height)return NO;_inflight=YES;epoch=_epoch;}
    CVPixelBufferRetain(source);
    dispatch_async(_queue, ^{
        CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();BOOL stale;@synchronized(self){stale=epoch!=self->_epoch;}
        CVPixelBufferRef output=NULL;NSError *failure=nil;
        if(!stale){
            NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
            CVReturn rc=CVPixelBufferCreate(NULL,self->_width*2,self->_height*2,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&output);
            if(rc!=kCVReturnSuccess||!output)failure=SPAnimeError(4,@"Anime4K 输出画面分配失败。");
            else {
                CVBufferPropagateAttachments(source,output);pl_gpu gpu=self->_vulkan->gpu;
                struct pl_tex_params in={};in.w=self->_width;in.h=self->_height;in.format=self->_format;in.sampleable=true;in.import_handle=PL_HANDLE_IOSURFACE;in.shared_mem.handle.handle=(void *)CVPixelBufferGetIOSurface(source);
                struct pl_tex_params out={};out.w=self->_width*2;out.h=self->_height*2;out.format=self->_format;out.renderable=true;out.import_handle=PL_HANDLE_IOSURFACE;out.shared_mem.handle.handle=(void *)CVPixelBufferGetIOSurface(output);
                pl_tex a=self->_api.textureCreate(gpu,&in),b=self->_api.textureCreate(gpu,&out);
                bool rendered=false;
                if(a&&b){struct pl_frame f={},g={};f.num_planes=g.num_planes=1;f.planes[0].texture=a;g.planes[0].texture=b;f.planes[0].components=g.planes[0].components=4;for(int i=0;i<4;i++)f.planes[0].component_mapping[i]=g.planes[0].component_mapping[i]=i;f.repr=g.repr=*self->_api.repr;f.color=g.color=*self->_api.colorspace;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    struct pl_render_params opts=*self->_api.defaults;
#pragma clang diagnostic pop
                    opts.hooks=&self->_hook;opts.num_hooks=1;rendered=self->_api.render(self->_renderer,&f,&g,&opts);self->_api.finish(gpu);struct pl_render_errors errors=self->_api.rendererErrors(self->_renderer);rendered=rendered&&!(errors.errors&PL_RENDER_ERR_HOOKS)&&errors.num_disabled_hooks==0;}
                if(a)self->_api.textureDestroy(gpu,&a);if(b)self->_api.textureDestroy(gpu,&b);
                if(!rendered){CVPixelBufferRelease(output);output=NULL;failure=SPAnimeError(5,@"Anime4K 处理当前画面失败。");}
            }
        }
        @synchronized(self){stale=epoch!=self->_epoch;self->_inflight=NO;}
        if(stale){if(output)CVPixelBufferRelease(output);output=NULL;failure=SPAnimeError(6,@"Anime4K 结果属于已结束的会话。");[self closeOnQueue];}
        CVPixelBufferRelease(source);completion(token,output,MAX(0,CFAbsoluteTimeGetCurrent()-start),failure);
    });return YES;
}
- (void)invalidate {BOOL active;@synchronized(self){_epoch++;_running=NO;active=_inflight;}if(!active)dispatch_async(_queue,^{[self closeOnQueue];});}
- (void)dealloc {if(_vulkan||_api.library)[self closeOnQueue];}
@end
