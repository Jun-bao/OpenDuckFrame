#import "SPLiveProcessor.h"

#import "SPFRCEngine.h"
#import "SPFrameBudgetMetal.h"
#import "SPLowLatencyEngine.h"
#import "SPAppleLowLatencySR.h"
#import "SPAppleVideoSR.h"
#import "SPAnime4K.h"
#import "SPRealCUGAN.h"
#import "SPDistilDRBA.h"
#import "SPRifeBridge.h"
#import "SPRateSchedule.hpp"
#import "SPFPSMeter.hpp"
#import "SPPresentationOrder.hpp"
#import "SPPresentationGeometry.hpp"
#import "SPOutputGeometry.hpp"

#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>

#include <cstring>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <deque>
#include <mutex>
#include <memory>
#include <unordered_map>
#include <vector>

extern "C" int spRunRateScheduleTests(void);

static const void *SPLiveQueueKey = &SPLiveQueueKey;

static int64_t SPHostNow(void) { return (int64_t)mach_absolute_time(); }

static int64_t SPHostToNs(int64_t host) {
    static mach_timebase_info_data_t info;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&info); });
    return host * (int64_t)info.numer / (int64_t)info.denom;
}

static const uint64_t SPQueueByteBudget = 160ull << 20;
static const double SPInteractiveCapSec = 0.090;
static const double SPQualityCapSec = 0.250;

static void SPPushSample(std::vector<int64_t> &samples, int64_t value) {
    samples.push_back(value);
    if (samples.size() > 40000) samples.erase(samples.begin(), samples.begin() + 8000);
}

static double SPPercentileMs(std::vector<int64_t> samples) {
    if (samples.empty()) return -1;
    std::sort(samples.begin(), samples.end());
    size_t index = (samples.size() - 1) * 95 / 100;
    return (double)samples[index] / 1e6;
}

static void SPWaitUntilHost(int64_t deadline) {
    for (;;) {
        int64_t now = SPHostNow();
        if (now >= deadline) return;
        int64_t ns = SPHostToNs(deadline - now);
        if (ns > 2500000) usleep((useconds_t)((ns - 1200000) / 1000));
        else {
            while (SPHostNow() < deadline) {}
            return;
        }
    }
}

static NSError *SPLiveError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"app.khuaplayer.live" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
}

static void SPForceSDRAttachments(CVPixelBufferRef buffer) {
    if (!buffer) return;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    if (space) {
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, kCVAttachmentMode_ShouldPropagate);
        CFRelease(space);
    }
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);
    }
    CVBufferRemoveAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey);
    CVBufferRemoveAttachment(buffer, kCVImageBufferContentLightLevelInfoKey);
    CVBufferRemoveAttachment(buffer, kCVImageBufferAmbientViewingEnvironmentKey);
}

static BOOL SPBufferIsHDR(CVPixelBufferRef buffer) {
    if (!buffer) return NO;
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    if (format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
        format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
        format == kCVPixelFormatType_64RGBAHalf ||
        format == kCVPixelFormatType_ARGB2101010LEPacked) {
        return YES;
    }
    CFTypeRef transfer = CVBufferGetAttachment(buffer, kCVImageBufferTransferFunctionKey, NULL);
    if (transfer &&
        (CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ||
         CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG))) {
        return YES;
    }
    if (CVBufferGetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, NULL)) return YES;
    return NO;
}

static CVPixelBufferRef SPCreateBuffer(int width, int height, OSType format) {
    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef buffer = NULL;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                          (__bridge CFDictionaryRef)attrs, &buffer);
    if (result != kCVReturnSuccess) return NULL;
    return buffer;
}

static void SPSampleLuma(CVPixelBufferRef buffer, uint8_t *out, int count) {
    memset(out, 0, (size_t)count);
    if (!buffer || count <= 0) return;
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    size_t width = CVPixelBufferGetWidth(buffer);
    size_t height = CVPixelBufferGetHeight(buffer);
    int cols = 8, rows = count / 8;
    if (rows < 1) rows = 1;
    if (format == kCVPixelFormatType_32BGRA) {
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
        size_t stride = CVPixelBufferGetBytesPerRow(buffer);
        int index = 0;
        for (int y = 0; y < rows && index < count; ++y) {
            size_t py = (size_t)((y + 0.5) * height / rows);
            if (py >= height) py = height - 1;
            uint8_t *row = base + py * stride;
            for (int x = 0; x < cols && index < count; ++x) {
                size_t px = (size_t)((x + 0.5) * width / cols);
                if (px >= width) px = width - 1;
                uint8_t *p = row + px * 4;
                out[index++] = (uint8_t)((54 * p[2] + 183 * p[1] + 19 * p[0]) >> 8);
            }
        }
    } else if (CVPixelBufferIsPlanar(buffer) && CVPixelBufferGetPlaneCount(buffer) >= 1) {
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
        size_t pw = CVPixelBufferGetWidthOfPlane(buffer, 0);
        size_t ph = CVPixelBufferGetHeightOfPlane(buffer, 0);
        int index = 0;
        for (int y = 0; y < rows && index < count; ++y) {
            size_t py = (size_t)((y + 0.5) * ph / rows);
            if (py >= ph) py = ph - 1;
            for (int x = 0; x < cols && index < count; ++x) {
                size_t px = (size_t)((x + 0.5) * pw / cols);
                if (px >= pw) px = pw - 1;
                out[index++] = base[py * stride + px];
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
}

static double SPWhiteCenterX(CVPixelBufferRef buffer) {
    if (!buffer || CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA) return -1;
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    size_t width = CVPixelBufferGetWidth(buffer);
    size_t height = CVPixelBufferGetHeight(buffer);
    double sum = 0, weight = 0;
    size_t y0 = height * 28 / 100;
    size_t y1 = height * 46 / 100;
    if (y1 > height) y1 = height;
    for (size_t y = y0; y < y1; y += 2) {
        uint8_t *row = base + y * stride;
        for (size_t x = 0; x < width; x += 4) {
            uint8_t green = row[x * 4 + 1];
            if (green > 180) {
                sum += (double)x * green;
                weight += green;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return weight > 0 ? sum / weight : -1;
}

static int SPTestBGRAFirstByte(CVPixelBufferRef buffer) {
    if (!buffer) return -1;
    OSType format=CVPixelBufferGetPixelFormatType(buffer);
    if (format!=kCVPixelFormatType_32BGRA && format!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format!=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return -1;
    CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
    const uint8_t *base=(const uint8_t *)(format==kCVPixelFormatType_32BGRA ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer,0));
    int value=base ? base[0] : -1;
    if (value>=0 && format==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) value=(int)llround((value-16)*255.0/219.0);
    CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly); return value;
}

// Only bit-identical input is safe to hold; sampling would miss small motion.
static BOOL SPIdenticalSourcePixels(CVPixelBufferRef a, CVPixelBufferRef b) {
    if (!a || !b || CVPixelBufferGetPixelFormatType(a)!=CVPixelBufferGetPixelFormatType(b) ||
        CVPixelBufferGetWidth(a)!=CVPixelBufferGetWidth(b) || CVPixelBufferGetHeight(a)!=CVPixelBufferGetHeight(b)) return NO;
    OSType format=CVPixelBufferGetPixelFormatType(a);
    if (format!=kCVPixelFormatType_32BGRA && format!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format!=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return NO;
    for (CFStringRef key : {kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey,kCVImageBufferYCbCrMatrixKey}) {
        CFTypeRef x=CVBufferGetAttachment(a,key,NULL), y=CVBufferGetAttachment(b,key,NULL);
        if ((x==NULL)!=(y==NULL) || (x&&y&&!CFEqual(x,y))) return NO;
    }
    if (CVPixelBufferLockBaseAddress(a,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(b,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) { CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly); return NO; }
    BOOL equal=YES; size_t planes=CVPixelBufferIsPlanar(a)?CVPixelBufferGetPlaneCount(a):1;
    if (planes!=(CVPixelBufferIsPlanar(b)?CVPixelBufferGetPlaneCount(b):1)) equal=NO;
    for(size_t p=0;equal && p<planes;p++) {
        BOOL planar=CVPixelBufferIsPlanar(a);
        const uint8_t *x=(const uint8_t *)(planar?CVPixelBufferGetBaseAddressOfPlane(a,p):CVPixelBufferGetBaseAddress(a));
        const uint8_t *y=(const uint8_t *)(planar?CVPixelBufferGetBaseAddressOfPlane(b,p):CVPixelBufferGetBaseAddress(b));
        size_t sx=planar?CVPixelBufferGetBytesPerRowOfPlane(a,p):CVPixelBufferGetBytesPerRow(a), sy=planar?CVPixelBufferGetBytesPerRowOfPlane(b,p):CVPixelBufferGetBytesPerRow(b);
        size_t h=planar?CVPixelBufferGetHeightOfPlane(a,p):CVPixelBufferGetHeight(a);
        size_t bytes=planar?CVPixelBufferGetWidthOfPlane(a,p)*(p==1?2:1):CVPixelBufferGetWidth(a)*4;
        if(!x||!y||sx<bytes||sy<bytes) { equal=NO; break; }
        for(size_t row=0;row<h;row++) if(memcmp(x+row*sx,y+row*sy,bytes)!=0){equal=NO;break;}
    }
    CVPixelBufferUnlockBaseAddress(b,kCVPixelBufferLock_ReadOnly);CVPixelBufferUnlockBaseAddress(a,kCVPixelBufferLock_ReadOnly);return equal;
}

static NSDictionary *SPQualityDiff(CVPixelBufferRef lhs, CVPixelBufferRef rhs) {
    if (!lhs || !rhs || CVPixelBufferGetWidth(lhs)!=CVPixelBufferGetWidth(rhs) || CVPixelBufferGetHeight(lhs)!=CVPixelBufferGetHeight(rhs)) return @{};
    CVPixelBufferLockBaseAddress(lhs,kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(rhs,kCVPixelBufferLock_ReadOnly);
    const uint8_t *a=(const uint8_t *)CVPixelBufferGetBaseAddress(lhs), *b=(const uint8_t *)CVPixelBufferGetBaseAddress(rhs);
    size_t sa=CVPixelBufferGetBytesPerRow(lhs), sb=CVPixelBufferGetBytesPerRow(rhs), w=CVPixelBufferGetWidth(lhs), h=CVPixelBufferGetHeight(lhs);
    uint64_t hist[256]={}, n=0; double sum=0, meanA=0,meanB=0,edgeA=0,edgeB=0, channelsA[3]={},channelsB[3]={}; uint64_t edges=0;
    for(size_t y=0;y<h;y+=4) for(size_t x=0;x<w;x+=4) {
        for(size_t c=0;c<3;c++) { int av=a[y*sa+x*4+c], bv=b[y*sb+x*4+c], diff=abs(av-bv); hist[diff]++;sum+=diff;meanA+=av;meanB+=bv;channelsA[c]+=av;channelsB[c]+=bv;n++; }
        if(x+1<w) { edgeA+=abs((int)a[y*sa+x*4+1]-(int)a[y*sa+(x+1)*4+1]); edgeB+=abs((int)b[y*sb+x*4+1]-(int)b[y*sb+(x+1)*4+1]);edges++; }
    }
    uint64_t seen=0;int p95=0;for(;p95<255;p95++){seen+=hist[p95];if(seen*100>=n*95)break;}
    CVPixelBufferUnlockBaseAddress(rhs,kCVPixelBufferLock_ReadOnly);CVPixelBufferUnlockBaseAddress(lhs,kCVPixelBufferLock_ReadOnly);
    return @{ @"mae":@(n?sum/n:0), @"p95Abs":@(p95), @"meanA":@(n?meanA/n:0), @"meanB":@(n?meanB/n:0),
        @"meanBGRAReference":@[@(n?channelsA[0]*3/n:0),@(n?channelsA[1]*3/n:0),@(n?channelsA[2]*3/n:0)],
        @"meanBGRAPhase":@[@(n?channelsB[0]*3/n:0),@(n?channelsB[1]*3/n:0),@(n?channelsB[2]*3/n:0)],
        @"edgeA":@(edges?edgeA/edges:0), @"edgeB":@(edges?edgeB/edges:0), @"samples":@(n) };
}

static CVPixelBufferRef SPQualityNV12(BOOL full,int shift,BOOL glyph=NO) {
    const int w=2560,h=1440; OSType f=full?kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CVPixelBufferRef p=SPCreateBuffer(w,h,f);if(!p)return NULL;SPForceSDRAttachments(p);
    CVPixelBufferLockBaseAddress(p,0);uint8_t *y=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(p,0),*uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(p,1);
    size_t ys=CVPixelBufferGetBytesPerRowOfPlane(p,0),us=CVPixelBufferGetBytesPerRowOfPlane(p,1);
    for(int row=0;row<h;row++)for(int col=0;col<w;col++) { int x=col-shift+24; BOOL bars;
        if(glyph) { int gx=x%24,gy=row%28; bars=(gx>=3&&gx<5&&gy>=3&&gy<23)||(gx>=16&&gx<18&&gy>=3&&gy<23)||(gy>=3&&gy<5&&gx>=3&&gx<18)||(gy>=12&&gy<14&&gx>=3&&gx<18)||(gy>=21&&gy<23&&gx>=3&&gx<18); }
        else bars=((x/3+row/7)&1)!=0;
        y[row*ys+col]=full?(bars?225:30):(bars?209:42); }
    for(int row=0;row<h/2;row++)for(int col=0;col<w;col+=2) { BOOL colored=col>1200&&col<1700&&row>200&&row<500;uv[row*us+col]=colored?100:128;uv[row*us+col+1]=colored?165:128; }
    CVPixelBufferUnlockBaseAddress(p,0);return p;
}

@implementation SPLivePlanRequest
- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    SPLivePlanRequest *copy = [[SPLivePlanRequest alloc] init];
    copy.requestID = self.requestID;
    copy.interpolationEnabled = self.interpolationEnabled;
    copy.quality = self.quality;
    copy.rateKind = self.rateKind;
    copy.fpsNumerator = self.fpsNumerator;
    copy.fpsDenominator = self.fpsDenominator;
    copy.multiplier = self.multiplier;
    copy.scaleEnabled = self.scaleEnabled;
    copy.scaleEngine = self.scaleEngine;
    copy.scaleQualityID = self.scaleQualityID ?: @"none";
    copy.outputWidth = self.outputWidth;
    copy.outputHeight = self.outputHeight;
    copy.viewMode = self.viewMode;
    copy.displayRefreshHz = self.displayRefreshHz;
    copy.captureCapFPS = self.captureCapFPS;
    copy.engineID = self.engineID ?: @"apple.frc";
    copy.modelID = self.modelID ?: @"";
    copy.qualityID = self.qualityID ?: @"";
    return copy;
}
@end

@implementation SPLiveResolvedPlan
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _engineID = @"apple.frc";
    _modelID = @"vt.frc.normal";
    _scaleEngineID = @"";
    _unavailableReason = @"";
    _colorPath = @"sdr.bt709.8bit";
    return self;
}
@end

@interface SPSpatialScaler : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  inputW:(int)inputW
                                  inputH:(int)inputH
                                 outputW:(int)outputW
                                 outputH:(int)outputH
                                  engine:(SPLiveScaleEngine)engine
                                   error:(NSError **)error;
- (nullable CVPixelBufferRef)scaleBuffer:(CVPixelBufferRef)source error:(NSError **)error;
@property (nonatomic, readonly) SPLiveScaleEngine engine;
@end

@implementation SPSpatialScaler {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _horizontal;
    id<MTLComputePipelineState> _vertical;
    id<MTLFXSpatialScaler> _metalFX;
    CVMetalTextureCacheRef _cache;
    int _inputW, _inputH, _outputW, _outputH;
    SPLiveScaleEngine _engine;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                        inputW:(int)inputW
                        inputH:(int)inputH
                       outputW:(int)outputW
                       outputH:(int)outputH
                        engine:(SPLiveScaleEngine)engine
                         error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _device = device;
    _inputW = inputW;
    _inputH = inputH;
    _outputW = outputW;
    _outputH = outputH;
    _engine = engine;
    _queue = [device newCommandQueue];
    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &_cache) != kCVReturnSuccess) {
        if (error) *error = SPLiveError(20, @"纹理缓存创建失败");
        return nil;
    }
    if (engine == SPLiveScaleMetalFX) {
        if (![MTLFXSpatialScalerDescriptor supportsDevice:device]) {
            if (error) *error = SPLiveError(21, @"这台 Mac 不支持 MetalFX 空间缩放");
            return nil;
        }
        MTLFXSpatialScalerDescriptor *descriptor = [[MTLFXSpatialScalerDescriptor alloc] init];
        descriptor.inputWidth = (NSUInteger)inputW;
        descriptor.inputHeight = (NSUInteger)inputH;
        descriptor.outputWidth = (NSUInteger)outputW;
        descriptor.outputHeight = (NSUInteger)outputH;
        descriptor.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        _metalFX = [descriptor newSpatialScalerWithDevice:device];
        if (!_metalFX) {
            if (error) *error = SPLiveError(22, @"MetalFX 空间缩放器创建失败");
            return nil;
        }
        return self;
    }
    id<MTLLibrary> library = [device newDefaultLibrary];
    NSError *functionError = nil;
    id<MTLFunction> horizontal = [library newFunctionWithName:@"spLanczosHorizontal"];
    id<MTLFunction> vertical = [library newFunctionWithName:@"spLanczosVertical"];
    _horizontal = horizontal ? [device newComputePipelineStateWithFunction:horizontal error:&functionError] : nil;
    _vertical = vertical && !functionError ? [device newComputePipelineStateWithFunction:vertical error:&functionError] : nil;
    if (!_horizontal || !_vertical) {
        if (error) *error = functionError ?: SPLiveError(23, @"Lanczos 着色器不可用");
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_cache) CFRelease(_cache);
}

- (SPLiveScaleEngine)engine { return _engine; }

- (CVMetalTextureRef)createTextureForBuffer:(CVPixelBufferRef)buffer {
    CVMetalTextureRef ref = NULL;
    size_t width = CVPixelBufferGetWidth(buffer);
    size_t height = CVPixelBufferGetHeight(buffer);
    CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, _cache, buffer, NULL, MTLPixelFormatBGRA8Unorm, width, height, 0, &ref);
    if (result != kCVReturnSuccess || !ref) return NULL;
    return ref;
}

- (nullable CVPixelBufferRef)scaleBuffer:(CVPixelBufferRef)source error:(NSError **)error {
    if (!source) return NULL;
    if (_inputW == _outputW && _inputH == _outputH) {
        CVPixelBufferRetain(source);
        return source;
    }
    CVPixelBufferRef destination = SPCreateBuffer(_outputW, _outputH, kCVPixelFormatType_32BGRA);
    if (!destination) {
        if (error) *error = SPLiveError(24, @"缩放输出缓冲失败");
        return NULL;
    }
    CVMetalTextureRef inputRef = [self createTextureForBuffer:source];
    CVMetalTextureRef outputRef = [self createTextureForBuffer:destination];
    id<MTLTexture> input = inputRef ? CVMetalTextureGetTexture(inputRef) : nil;
    id<MTLTexture> output = outputRef ? CVMetalTextureGetTexture(outputRef) : nil;
    if (!input || !output) {
        if (inputRef) CFRelease(inputRef);
        if (outputRef) CFRelease(outputRef);
        CVPixelBufferRelease(destination);
        if (error) *error = SPLiveError(25, @"缩放纹理失败");
        return NULL;
    }
    id<MTLCommandBuffer> command = [_queue commandBuffer];
    if (_engine == SPLiveScaleMetalFX) {
        MTLTextureDescriptor *inDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                           width:(NSUInteger)_inputW
                                                                                          height:(NSUInteger)_inputH
                                                                                       mipmapped:NO];
        inDesc.storageMode = MTLStorageModePrivate;
        inDesc.usage = MTLTextureUsageShaderRead | _metalFX.colorTextureUsage;
        MTLTextureDescriptor *outDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                            width:(NSUInteger)_outputW
                                                                                           height:(NSUInteger)_outputH
                                                                                        mipmapped:NO];
        outDesc.storageMode = MTLStorageModePrivate;
        outDesc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead | _metalFX.outputTextureUsage;
        id<MTLTexture> inPrivate = [_device newTextureWithDescriptor:inDesc];
        id<MTLTexture> outPrivate = [_device newTextureWithDescriptor:outDesc];
        id<MTLBlitCommandEncoder> blitIn = [command blitCommandEncoder];
        [blitIn copyFromTexture:input sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake((NSUInteger)_inputW, (NSUInteger)_inputH, 1)
                      toTexture:inPrivate destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blitIn endEncoding];
        _metalFX.colorTexture = inPrivate;
        _metalFX.inputContentWidth = (NSUInteger)_inputW;
        _metalFX.inputContentHeight = (NSUInteger)_inputH;
        _metalFX.outputTexture = outPrivate;
        [_metalFX encodeToCommandBuffer:command];
        id<MTLBlitCommandEncoder> blitOut = [command blitCommandEncoder];
        [blitOut copyFromTexture:outPrivate sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake((NSUInteger)_outputW, (NSUInteger)_outputH, 1)
                       toTexture:output destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blitOut endEncoding];
    } else {
        MTLTextureDescriptor *midDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                            width:(NSUInteger)_outputW
                                                                                           height:(NSUInteger)_inputH
                                                                                        mipmapped:NO];
        midDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        midDesc.storageMode = MTLStorageModePrivate;
        id<MTLTexture> mid = [_device newTextureWithDescriptor:midDesc];
        id<MTLComputeCommandEncoder> horizontal = [command computeCommandEncoder];
        [horizontal setComputePipelineState:_horizontal];
        [horizontal setTexture:input atIndex:0];
        [horizontal setTexture:mid atIndex:1];
        NSUInteger tw = _horizontal.threadExecutionWidth;
        NSUInteger th = MAX((NSUInteger)1, _horizontal.maxTotalThreadsPerThreadgroup / tw);
        [horizontal dispatchThreads:MTLSizeMake((NSUInteger)_outputW, (NSUInteger)_inputH, 1)
              threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
        [horizontal endEncoding];
        id<MTLComputeCommandEncoder> vertical = [command computeCommandEncoder];
        [vertical setComputePipelineState:_vertical];
        [vertical setTexture:mid atIndex:0];
        [vertical setTexture:output atIndex:1];
        [vertical dispatchThreads:MTLSizeMake((NSUInteger)_outputW, (NSUInteger)_outputH, 1)
            threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
        [vertical endEncoding];
        (void)mid;
    }
    [command commit];
    [command waitUntilCompleted];
    CFRelease(inputRef); CFRelease(outputRef);
    if (command.status != MTLCommandBufferStatusCompleted) {
        CVPixelBufferRelease(destination);
        if (error) *error = SPLiveError(26, @"缩放 GPU 失败");
        return NULL;
    }
    SPForceSDRAttachments(destination);
    CVMetalTextureCacheFlush(_cache, 0);
    return destination;
}

@end

@interface SPProbeDrawable : NSObject
@property(nonatomic,strong) id<MTLTexture> texture;
@end
@implementation SPProbeDrawable
@end

@implementation SPLivePreviewView {
    CAMetalLayer *_metalLayer;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    dispatch_queue_t _presentQueue;
    id<MTLRenderPipelineState> _pipeline;
    CVMetalTextureCacheRef _cache;
    std::atomic<uint64_t> _generation;
    std::atomic<bool> _windowVisible;
    std::atomic<bool> _drawableVisible;
    std::atomic<bool> _exposed;
    std::atomic<bool> _followTargetContent;
    std::atomic<uint64_t> _diagnosticConfig;
    std::atomic<uint64_t> _diagnosticEpoch;
    std::atomic<uint64_t> _surfaceToken;
    std::atomic<int> _inflightDraws;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _generation.store(0);
    _windowVisible.store(false);
    _drawableVisible.store(false);
    _exposed.store(false);
    _followTargetContent.store(false);
    _diagnosticConfig.store(0);
    _diagnosticEpoch.store(0);
    _surfaceToken.store(0);
    _inflightDraws.store(0);
    self.wantsLayer = YES;
    _device = MTLCreateSystemDefaultDevice();
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = YES;
    _metalLayer.contentsScale = 2;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    _metalLayer.colorspace = space;
    CGColorSpaceRelease(space);
    self.layer = _metalLayer;
    _commandQueue = [_device newCommandQueue];
    _presentQueue = dispatch_queue_create("app.khuaplayer.live-present",
                                          dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    if (_device) CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_cache);
    id<MTLLibrary> library = [_device newDefaultLibrary];
    id<MTLFunction> vertex = [library newFunctionWithName:@"spPresentVertex"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"spPresentFragment"];
    if (vertex && fragment) {
        MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = vertex;
        desc.fragmentFunction = fragment;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        _pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:NULL];
    }
    return self;
}

- (void)dealloc {
    if (_cache) CFRelease(_cache);
}

- (void)layout {
    [super layout];
    _metalLayer.contentsScale = self.window.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor ?: 2;
    _metalLayer.frame = self.bounds;
    _metalLayer.drawableSize = CGSizeMake(MAX(1, self.bounds.size.width * _metalLayer.contentsScale),
                                          MAX(1, self.bounds.size.height * _metalLayer.contentsScale));
    [self refreshVisibilitySnapshot];
}

- (void)refreshVisibilitySnapshot {
    NSAssert(NSThread.isMainThread, @"AppKit visibility must be read on the main thread");
    NSWindow *window = self.window;
    BOOL visible = window != nil && window.isVisible && !self.isHiddenOrHasHiddenAncestor;
    BOOL drawable = visible && (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    _windowVisible.store(visible);
    _drawableVisible.store(drawable);
    _exposed.store(visible && window.alphaValue >= 0.99);
}

- (BOOL)windowVisibleSnapshot { return _windowVisible.load(); }
- (BOOL)drawableVisibleSnapshot { return _drawableVisible.load(); }
- (BOOL)exposedSnapshot { return _exposed.load(); }

- (void)setGeneration:(uint64_t)generation { _generation = generation; }

- (void)setDiagnosticsConfig:(uint64_t)config epoch:(uint64_t)epoch {
    _diagnosticConfig = config;
    _diagnosticEpoch = epoch;
}

- (void)setSurfaceToken:(uint64_t)token { _surfaceToken.store(token); }
- (void)setFollowTargetContent:(BOOL)follow { _followTargetContent.store(follow); }

- (CVMetalTextureRef)createTexture:(CVPixelBufferRef)buffer {
    if (!buffer || !_cache) return NULL;
    CVMetalTextureRef ref = NULL;
    CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, _cache, buffer, NULL, MTLPixelFormatBGRA8Unorm,
        CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &ref);
    if (result != kCVReturnSuccess || !ref) return NULL;
    return ref;
}

- (void)writeQuad:(float *)v viewportWidth:(float)pw height:(float)ph frameWidth:(float)fw frameHeight:(float)fh fill:(BOOL)fill {
    const auto quad = sp::outputQuad(pw, ph, fw, fh, fill);
    float hw = quad.halfWidth, hh = quad.halfHeight;
    float xyuv[16] = {
        -hw, -hh, 0, 1,
         hw, -hh, 1, 1,
        -hw,  hh, 0, 0,
         hw,  hh, 1, 0,
    };
    memcpy(v, xyuv, sizeof(xyuv));
}

- (void)drawTexture:(id<MTLTexture>)texture
         frameWidth:(float)fw
        frameHeight:(float)fh
           viewport:(MTLViewport)viewport
             buffer:(id<MTLCommandBuffer>)command
           drawable:(id<CAMetalDrawable>)drawable
               fill:(BOOL)fill {
    float quad[16];
    [self writeQuad:quad viewportWidth:(float)viewport.width height:(float)viewport.height frameWidth:fw frameHeight:fh fill:fill];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [command renderCommandEncoderWithDescriptor:pass];
    [enc setViewport:viewport];
    [enc setRenderPipelineState:_pipeline];
    [enc setVertexBytes:quad length:sizeof(quad) atIndex:0];
    [enc setFragmentTexture:texture atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [enc endEncoding];
}

- (NSDictionary *)runOffscreenDrawAndLifetimeProbe {
    MTLTextureDescriptor *outDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:32 mipmapped:NO];
    outDesc.usage=MTLTextureUsageRenderTarget; outDesc.storageMode=MTLStorageModeShared;
    id<MTLTexture> out=[_device newTextureWithDescriptor:outDesc];
    MTLTextureDescriptor *redDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:9 mipmapped:NO];
    redDesc.usage=MTLTextureUsageShaderRead; redDesc.storageMode=MTLStorageModeShared;
    MTLTextureDescriptor *greenDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
    greenDesc.usage=MTLTextureUsageShaderRead; greenDesc.storageMode=MTLStorageModeShared;
    id<MTLTexture> red=[_device newTextureWithDescriptor:redDesc], green=[_device newTextureWithDescriptor:greenDesc];
    if (!out||!red||!green||!_pipeline) return @{ @"ok":@NO, @"reason":@"metal setup" };
    uint8_t r[16*9*4],g[16*16*4];for(int i=0;i<16*9;i++){r[4*i]=0;r[4*i+1]=0;r[4*i+2]=255;r[4*i+3]=255;}
    for(int i=0;i<16*16;i++){g[4*i]=0;g[4*i+1]=255;g[4*i+2]=0;g[4*i+3]=255;}
    [red replaceRegion:MTLRegionMake2D(0,0,16,9) mipmapLevel:0 withBytes:r bytesPerRow:16*4];
    [green replaceRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0 withBytes:g bytesPerRow:16*4];
    SPProbeDrawable *surface=[SPProbeDrawable new];surface.texture=out; id<MTLCommandBuffer> cmd=[_commandQueue commandBuffer];
    MTLRenderPassDescriptor *clear=[MTLRenderPassDescriptor renderPassDescriptor];clear.colorAttachments[0].texture=out;
    clear.colorAttachments[0].loadAction=MTLLoadActionClear;clear.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);clear.colorAttachments[0].storeAction=MTLStoreActionStore;
    [[cmd renderCommandEncoderWithDescriptor:clear] endEncoding];
    MTLViewport left={0,0,32,32,0,1},right={32,0,32,32,0,1};
    [self drawTexture:red frameWidth:16 frameHeight:9 viewport:left buffer:cmd drawable:(id<CAMetalDrawable>)surface fill:NO];
    [self drawTexture:green frameWidth:16 frameHeight:16 viewport:right buffer:cmd drawable:(id<CAMetalDrawable>)surface fill:NO];
    [cmd commit];[cmd waitUntilCompleted];uint8_t pixels[64*32*4];
    [out getBytes:pixels bytesPerRow:64*4 fromRegion:MTLRegionMake2D(0,0,64,32) mipmapLevel:0];
    auto px=[&](int x,int y,int c){return pixels[(y*64+x)*4+c];};
    BOOL independent=cmd.status==MTLCommandBufferStatusCompleted && px(16,1,2)<10 && px(16,16,2)>240 && px(48,1,1)>240;
    NSDictionary *attrs=@{(id)kCVPixelBufferWidthKey:@64,(id)kCVPixelBufferHeightKey:@64,(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferPoolRef pool=NULL; CVPixelBufferPoolCreate(kCFAllocatorDefault,NULL,(__bridge CFDictionaryRef)attrs,&pool);
    NSDictionary *limit=@{(id)kCVPixelBufferPoolAllocationThresholdKey:@1}; CVPixelBufferRef first=NULL, second=NULL;
    CVReturn created=pool?CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,pool,(__bridge CFDictionaryRef)limit,&first):kCVReturnError;
    CVMetalTextureRef ref=first?[self createTexture:first]:NULL; id<MTLTexture> mapped=ref?CVMetalTextureGetTexture(ref):nil;
    id<MTLSharedEvent> event=[_device newSharedEvent]; id<MTLCommandBuffer> pending=[_commandQueue commandBuffer];
    BOOL guarded=NO,released=NO;
    if(created==kCVReturnSuccess && first && ref && mapped && event && pending) {
        [pending encodeWaitForEvent:event value:1]; CVPixelBufferRetain(first);
        [pending addCompletedHandler:^(id<MTLCommandBuffer> finished){ (void)finished; CFRelease(ref); CVPixelBufferRelease(first); }];
        [pending commit];CVPixelBufferRelease(first);first=NULL;
        CVReturn busy=CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,pool,(__bridge CFDictionaryRef)limit,&second);
        guarded=busy==kCVReturnWouldExceedAllocationThreshold; if(second){CVPixelBufferRelease(second);second=NULL;}
        event.signaledValue=1;[pending waitUntilCompleted];CVMetalTextureCacheFlush(_cache,0);
        CVReturn available=CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,pool,(__bridge CFDictionaryRef)limit,&second);
        released=available==kCVReturnSuccess && second!=NULL; if(second)CVPixelBufferRelease(second);
    } else { if(ref)CFRelease(ref);if(first)CVPixelBufferRelease(first); }
    if(pool)CFRelease(pool);
    return @{ @"ok":@(independent&&guarded&&released), @"compareQuadsIndependent":@(independent), @"poolBlockedBeforeGPUCompletion":@(guarded),
        @"poolReusableAfterGPUCompletion":@(released), @"scope":@"actual offscreen preview draw and GPU buffer lifetime; no drawable window or physical display" };
}

- (BOOL)presentEnhanced:(CVPixelBufferRef)enhanced
               original:(CVPixelBufferRef)original
                   mode:(SPLiveViewMode)mode
            captureHost:(int64_t)captureHost
             generation:(uint64_t)generation
                 ptsNum:(int64_t)ptsNum
                 ptsDen:(int64_t)ptsDen
              synthetic:(BOOL)synthetic
                frameID:(uint64_t)frameID
                 counts:(BOOL)counts
                 reason:(NSString **)reason {
    if (generation != _generation) { if (reason) *reason = @"generation"; return NO; }
    if (!_pipeline) { if (reason) *reason = @"pipeline"; return NO; }
    CVPixelBufferRef primary = mode == SPLiveViewOriginal ? (original ?: enhanced) : enhanced;
    CVPixelBufferRef secondary = original ?: enhanced;
    if (!primary) { if (reason) *reason = @"input"; return NO; }
    BOOL windowVisible = _windowVisible.load();
    BOOL occluded = windowVisible && !_drawableVisible.load();
    BOOL exposed = _exposed.load();
    BOOL fillTarget = _followTargetContent.load() && mode != SPLiveViewCompare;
    if (!counts && (!windowVisible || occluded)) return YES;
    int pending = _inflightDraws.load();
    if (pending >= 3) { if (reason) *reason = @"inflight"; return NO; }
    _inflightDraws.fetch_add(1);
    if (enhanced) CVPixelBufferRetain(enhanced);
    if (original) CVPixelBufferRetain(original);
    uint64_t seen = generation;
    // Bind each drawable to the plan that submitted it. The notification can
    // arrive after a new plan has already replaced the view's diagnostics.
    uint64_t seenConfig = _diagnosticConfig.load();
    uint64_t seenEpoch = _diagnosticEpoch.load();
    uint64_t seenSurfaceToken = _surfaceToken.load();
    void (^reportFailure)(NSString *) = ^(NSString *why) {
        if (counts && self.presentationFailure) self.presentationFailure(@{ @"reason": why, @"generation": @(seen),
            @"configVersion": @(seenConfig), @"measurementEpoch": @(seenEpoch), @"frameID": @(frameID) });
    };
    struct SPDrawNote {
        std::atomic<int> ticket;
        std::atomic<long long> gpuHost;
        std::atomic<int> refs;
    };
    auto *note = new SPDrawNote();
    note->ticket.store(0);
    note->gpuHost.store(0);
    note->refs.store(2);
    SPLivePreviewView *view = self;
    void (^releaseTicket)(void) = ^{
        if (note->ticket.exchange(1) == 0) view->_inflightDraws.fetch_sub(1);
    };
    void (^releaseNote)(void) = ^{
        if (note->refs.fetch_sub(1) == 1) delete note;
    };
    void (^abandon)(void) = ^{
        releaseTicket();
        delete note;
    };
    int width = (int)CVPixelBufferGetWidth(primary);
    int height = (int)CVPixelBufferGetHeight(primary);
    int enhancedWidth = enhanced ? (int)CVPixelBufferGetWidth(enhanced) : 0;
    int enhancedHeight = enhanced ? (int)CVPixelBufferGetHeight(enhanced) : 0;
    int originalWidth = original ? (int)CVPixelBufferGetWidth(original) : 0;
    int originalHeight = original ? (int)CVPixelBufferGetHeight(original) : 0;
    dispatch_async(_presentQueue, ^{
        if (seen != self->_generation || seenConfig != self->_diagnosticConfig.load() || seenEpoch != self->_diagnosticEpoch.load()) {
            reportFailure(seen != self->_generation ? @"generation" : (seenConfig != self->_diagnosticConfig.load() ? @"configuration" : @"epoch"));
            abandon();
            if (enhanced) CVPixelBufferRelease(enhanced);
            if (original) CVPixelBufferRelease(original);
            return;
        }
        int64_t drawableWaitStart = SPHostNow();
        id<CAMetalDrawable> drawable = [self->_metalLayer nextDrawable];
        int64_t drawableWaitNs = SPHostToNs(SPHostNow() - drawableWaitStart);
        CVMetalTextureRef aRef = [self createTexture:primary];
        CVMetalTextureRef bRef = mode == SPLiveViewCompare ? [self createTexture:secondary] : NULL;
        id<MTLTexture> a = aRef ? CVMetalTextureGetTexture(aRef) : nil;
        id<MTLTexture> b = bRef ? CVMetalTextureGetTexture(bRef) : nil;
        if (!drawable || !a || !self->_pipeline) {
            reportFailure(!drawable ? @"drawable" : (!a ? @"texture" : @"pipeline"));
            if (aRef) CFRelease(aRef);
            if (bRef) CFRelease(bRef);
            abandon();
            if (enhanced) CVPixelBufferRelease(enhanced);
            if (original) CVPixelBufferRelease(original);
            return;
        }
        id<MTLCommandBuffer> command = [self->_commandQueue commandBuffer];
        if (!command) {
            reportFailure(@"command");
            if (aRef) CFRelease(aRef);
            if (bRef) CFRelease(bRef);
            abandon();
            if (enhanced) CVPixelBufferRelease(enhanced);
            if (original) CVPixelBufferRelease(original);
            return;
        }
        MTLRenderPassDescriptor *clear = [MTLRenderPassDescriptor renderPassDescriptor];
        clear.colorAttachments[0].texture = drawable.texture;
        clear.colorAttachments[0].loadAction = MTLLoadActionClear;
        clear.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        clear.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [command renderCommandEncoderWithDescriptor:clear];
        [enc endEncoding];
        CGSize size = CGSizeMake(drawable.texture.width, drawable.texture.height);
        float fw = (float)CVPixelBufferGetWidth(primary);
        float fh = (float)CVPixelBufferGetHeight(primary);
        if (mode == SPLiveViewCompare && b) {
            MTLViewport left = {0, 0, size.width * 0.5, size.height, 0, 1};
            MTLViewport right = {size.width * 0.5, 0, size.width * 0.5, size.height, 0, 1};
            [self drawTexture:a frameWidth:fw frameHeight:fh viewport:left buffer:command drawable:drawable fill:NO];
            [self drawTexture:b frameWidth:(float)CVPixelBufferGetWidth(secondary)
                  frameHeight:(float)CVPixelBufferGetHeight(secondary)
                     viewport:right buffer:command drawable:drawable fill:NO];
        } else {
            MTLViewport full = {0, 0, size.width, size.height, 0, 1};
            [self drawTexture:a frameWidth:fw frameHeight:fh viewport:full buffer:command drawable:drawable fill:fillTarget];
        }
        [command addCompletedHandler:^(id<MTLCommandBuffer> done) {
            if (done.status != MTLCommandBufferStatusCompleted) reportFailure(@"gpu");
            note->gpuHost.store((long long)SPHostNow());
            if (aRef) CFRelease(aRef);
            if (bRef) CFRelease(bRef);
            if (enhanced) CVPixelBufferRelease(enhanced);
            if (original) CVPixelBufferRelease(original);
            if (seenSurfaceToken && self.surfaceReady) {
                self.surfaceReady(@{ @"generation": @(seen), @"configVersion": @(seenConfig),
                    @"measurementEpoch": @(seenEpoch), @"surfaceToken": @(seenSurfaceToken),
                    @"counts": @(counts), @"windowVisible": @(windowVisible),
                    @"gpuCompleted": @(done.status == MTLCommandBufferStatusCompleted), @"viewMode": @(mode),
                    @"enhancedWidth": @(enhancedWidth), @"enhancedHeight": @(enhancedHeight),
                    @"originalWidth": @(originalWidth), @"originalHeight": @(originalHeight) });
            }
            releaseTicket();
            releaseNote();
        }];
        [drawable addPresentedHandler:^(id<MTLDrawable> presentedDrawable) {
            long long gpuHost = note->gpuHost.load();
            releaseNote();
            if (!self.presented) return;
            self.presented(@{
                @"captureHost": @(captureHost),
                @"presentedHost": @(SPHostNow()),
                @"presentedTime": @(presentedDrawable.presentedTime),
                @"handlerMediaTime": @(CACurrentMediaTime()),
                @"drawableWaitNs": @(drawableWaitNs),
                @"gpuHost": @(gpuHost),
                @"occluded": @(occluded),
                @"windowVisible": @(windowVisible),
                @"exposed": @(exposed),
                @"generation": @(seen),
                @"configVersion": @(seenConfig),
                @"measurementEpoch": @(seenEpoch),
                @"ptsNum": @(ptsNum),
                @"ptsDen": @(ptsDen),
                @"synthetic": @(synthetic),
                @"viewMode": @(mode),
                @"frameID": @(frameID),
                @"counts": @(counts),
                @"width": @(width),
                @"height": @(height),
                @"drawableWidth": @((int)size.width),
                @"drawableHeight": @((int)size.height),
                @"enhancedCenter": @(-1),
                @"originalCenter": @(-1),
            });
        }];
        [command presentDrawable:drawable];
        [command commit];
        if (self->_cache) CVMetalTextureCacheFlush(self->_cache, 0);
    });
    return YES;
}

@end

struct SPLiveHeld {
    CVPixelBufferRef source = nullptr;
    CVPixelBufferRef yuv = nullptr;
    CVPixelBufferRef lowPrescaled = nullptr;
    uint64_t lowPrescaledConfig = 0;
    int64_t host = 0;
    sp::SPRational pts{};
    int pins = 0;
    uint64_t previousIdentity = 0;
};

struct SPLiveInbound {
    CVPixelBufferRef buffer = nullptr;
    int64_t ptsNum = 0;
    int64_t ptsDen = 1;
    int64_t host = 0;
    int64_t readyHost = 0;
    uint64_t generation = 0;
};

struct SPLiveJob {
    uint64_t configVersion = 0;
    uint64_t generation = 0;
    int64_t captureHost = 0;
    sp::SPRational pts[3]{};
    int64_t targetHost[3]{};
    uint64_t clockEpoch = 0;
    int count = 0;
    uint64_t frameA = 0;
    uint64_t frameB = 0;
    uint64_t inflightEpoch = 0;
};

struct SPSRJob {
    CVPixelBufferRef input = nullptr;
    CVPixelBufferRef original = nullptr;
    sp::SPRational pts{};
    int64_t captureHost = 0;
    int64_t targetHost = 0;
    uint64_t clockEpoch = 0;
    uint64_t sourceGeneration = 0;
    uint64_t configVersion = 0;
    uint64_t sequence = 0;
    uint64_t bytes = 0;
    BOOL synthetic = NO;
    BOOL held = NO;
    BOOL discontinuity = NO;
};

static void SPReleaseSRJob(SPSRJob *job) {
    if (!job) return;
    if (job->input) CVPixelBufferRelease(job->input);
    if (job->original) CVPixelBufferRelease(job->original);
    delete job;
}

struct SPPlaySlot {
    sp::SPRational pts{};
    int64_t targetHost = 0;
    int64_t readyHost = 0;
    BOOL synthetic = NO;
    CVPixelBufferRef enhanced = nullptr;
    CVPixelBufferRef original = nullptr;
    uint64_t frameID = 0;
    uint64_t sourceGeneration = 0;
    uint64_t configVersion = 0;
    int64_t captureHost = 0;
    BOOL hasCenter = NO;
    double enhancedCenter = -1;
    double originalCenter = -1;
};

struct SPPendingPhase {
    sp::SPRational pts{};
    int64_t targetHost = 0;
    uint64_t generation = 0;
};

struct SPFrameMark {
    int64_t readyHost = 0;
    int64_t targetHost = 0;
    BOOL hasCenter = NO;
    double enhancedCenter = -1;
    double originalCenter = -1;
    BOOL held = NO;
    uint64_t fpsEpoch = 0;
};

static int64_t SPRationalToHost(sp::SPRational seconds) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    if (seconds.den == 0 || info.numer == 0) return 0;
    __int128 ns = (__int128)seconds.num * 1000000000 / seconds.den;
    __int128 host = ns * info.denom / info.numer;
    if (host > INT64_MAX) return INT64_MAX;
    if (host < INT64_MIN) return INT64_MIN;
    return (int64_t)host;
}

static void SPReleaseSlot(SPPlaySlot &slot) {
    if (slot.enhanced) CVPixelBufferRelease(slot.enhanced);
    if (slot.original) CVPixelBufferRelease(slot.original);
    slot.enhanced = nullptr;
    slot.original = nullptr;
}

@implementation SPLiveProcessor {
    dispatch_queue_t _q;
    SPLivePlanRequest *_request;
    SPLiveResolvedPlan *_resolved;
    SPFRCEngine *_engine;
    SPLowLatencyEngine *_lowLatency;
    SPRifeBridge *_rife;
    SPDistilDRBA *_distil;
    SPAppleLowLatencySR *_appleSR;
    SPAppleVideoSR *_videoSR;
    SPAnime4K *_animeSR;
    SPRealCUGAN *_cuganSR;
    std::deque<SPSRJob *> _srPending;
    uint64_t _srSequence;
    uint64_t _srPendingBytes;
    BOOL _srBusy, _srFailed;
    sp::SPRational _srActivePTS;
    BOOL _videoSRDiscontinuity;
    dispatch_queue_t _prepareQ;
    uint64_t _prepareToken;
    uint64_t _ackRequestID;
    NSString *_ackEngineID, *_ackModelID;
    NSDictionary *_statsSnapshot;
    std::mutex _statsMx;
    SPFrameBudgetMetal *_metal;
    SPSpatialScaler *_scaler;
    SPSpatialScaler *_baselineScaler;
    VTPixelTransferSessionRef _transfer;
    std::vector<SPPlaySlot> _slots;
    std::vector<SPPendingPhase> _pending;
    std::vector<sp::SPScheduleOutput> _rifePending;
    uint64_t _rifePendingGeneration;
    BOOL _rifeSlowMode;
    BOOL _lowPrescaleSlowMode;
    BOOL _testCapturePlayout;
    BOOL _testKeepLowRealtime;
    std::vector<std::pair<sp::SPRational, bool>> _testPlayout;
    NSMutableArray *_testPendingTrace;
    NSMutableArray *_testTimingTrace;
    std::unordered_map<uint64_t, SPFrameMark> _marks;
    dispatch_source_t _clock;
    BOOL _haveAnchor;
    sp::SPRational _anchorPts;
    int64_t _anchorHost;
    uint64_t _clockEpoch, _clockRetiredJobs, _clockRetiredModelOutputs, _clockRetiredPhaseDrops;
    int64_t _delayHost;
    int64_t _intervalHost;
    BOOL _haveInterval;
    double _frcEwmaSec;
    double _scaleEwmaSec;
    BOOL _delayClamped;
    NSUInteger _peakSlots;
    BOOL _haveLastPts;
    sp::SPRational _lastPresentedPts;
    CVPixelBufferRef _lastEnhanced;
    CVPixelBufferRef _lastOriginal;
    BOOL _lastSynthetic;
    sp::SPRational _lastRedrawPts;
    uint64_t _nextFrameID;
    uint64_t _outputSurfaceToken;
    uint64_t _lowPrescaleInputs, _lowSyntheticNoRescale, _testBaselineMatches, _testBaselineMismatches;
    uint64_t _outputWarmGPUCompleted, _outputWarmGPUFailed, _outputWarmRejected;
    uint64_t _outputPresentedZeroTime, _outputPresentedValidTime;
    uint64_t _epochPhysicalSource, _epochPhysicalSynthetic;
    BOOL _physicalHavePts;
    sp::SPRational _physicalLastPts;
    NSInteger _outputWarmMode;
    int _outputWarmEnhancedWidth, _outputWarmEnhancedHeight, _outputWarmOriginalWidth, _outputWarmOriginalHeight;
    uint64_t _inflightEpoch;
    sp::SPRational _previousSourcePts;
    sp::FPSMeter _fpsMeter;
    uint64_t _fpsObservationEpoch;
    uint64_t _previousSourceIdentity;
    BOOL _havePreviousSourcePts;
    sp::SPRateScheduler _scheduler;
    std::mutex _inMx;
    std::deque<SPLiveInbound> _inbound;
    BOOL _pumpQueued;
    std::unordered_map<uint64_t, SPLiveHeld> _held;
    uint64_t _nextIdentity;
    uint64_t _sourceGeneration;
    uint64_t _configVersion;
    BOOL _stopped;
    BOOL _building;
    BOOL _preparing;
    BOOL _asyncPrepareFailed;
    BOOL _sessionReady;
    BOOL _scoreOutput;
    int _inflight;
    int _width;
    int _height;
    int _sourceWidth, _sourceHeight;
    sp::PresentationGeometry _presentationGeometry;
    uint64_t _lastPairB;
    BOOL _havePair;
    uint64_t _captured, _idle, _completeFrames, _interrupted;
    uint64_t _syntheticOK, _syntheticFail, _presentedSource, _presentedSynthetic;
    uint64_t _scheduledSynthetic, _submitted;
    uint64_t _deadlineDrops, _sceneSkips, _queueDrops, _presentedCallbacks, _renderDrops;
    uint64_t _engineUnavailableDrops, _inflightLimitDrops, _engineSubmissionRejectedDrops;
    NSMutableDictionary *_presentationFailuresLifetime, *_presentationFailuresEpoch;
    NSMutableDictionary *_firstPresentationFailureLifetime, *_firstPresentationFailureEpoch, *_ignoredPresentedCallbacks;
    uint64_t _staticHoldPhases, _epochStaticHoldPhases;
    uint64_t _lateReadyDrops, _staleReadyDrops, _dueMergeDrops, _pendingExpiredDrops, _slotEvictionDrops;
    std::vector<int64_t> _captureToModelReadyNs;
    std::vector<int64_t> _captureToOutputReadyNs;
    uint64_t _stoppedDrops, _generationDrops;
    uint64_t _measurementEpoch;
    uint64_t _epochSamples;
    uint64_t _epochDuplicates;
    uint64_t _epochSizeChanges;
    uint64_t _epochScheduled;
    uint64_t _epochPresentedSynthetic;
    uint64_t _epochPresentedSource;
    uint64_t _epochDeadline;
    uint64_t _epochQueueDrops;
    uint64_t _phaseBatchSplits;
    uint32_t _epochHist[201];
    sp::PresentationOrder _presentationOrder;
    BOOL _epochMonotonic;
    BOOL _epochHavePts;
    sp::SPRational _epochLastPts;
    int _epochWidth;
    int _epochHeight;
    BOOL _delayClampNoted;
    std::vector<int64_t> _copyEntryNs;
    std::vector<sp::SPRational> _claimedDrops;
    std::mutex _latencyMx;
    std::vector<int64_t> _latencyNs;
    std::vector<int64_t> _frcNs;
    std::vector<int64_t> _scaleNs;
    std::vector<int64_t> _transferNs;
    std::vector<int64_t> _queueNs;
    std::vector<int64_t> _playheadNs;
    std::vector<int64_t> _drawableWaitNs;
    std::vector<int64_t> _presentGapNs;
    std::vector<int64_t> _presentMediaLagNs;
    std::vector<int64_t> _gpuToDisplayNs;
    std::vector<int64_t> _captureToDisplayNs;
    OSType _sourcePixelFormat;
    BOOL _holdFailureStatus;
    uint64_t _occludedPresents;
    BOOL _phaseRejectNoted;
    uint64_t _measuredScheduled;
    uint64_t _centerSampleNs;
    int _centerSamples;
    BOOL _probeWindowOpen;
    BOOL _probeAggregateOnly;
    BOOL _probeMonotonic;
    BOOL _probeSizeOK;
    BOOL _probeHaveLast;
    sp::SPRational _probeMinPts;
    sp::SPRational _probeLastPts;
    int64_t _windowStart;
    int _windowCallbacks, _windowChanged;
    uint8_t _previousLuma[64];
    BOOL _haveLuma;
    int64_t _lastStatsHost;
    NSMutableArray<NSDictionary *> *_probeOutputs;
    dispatch_semaphore_t _probeGate;
    int _probeSyntheticGoal;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _q = dispatch_queue_create("app.khuaplayer.live",
                               dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    _request = [[SPLivePlanRequest alloc] init];
    _request.rateKind = SPLiveRateMultiplier;
    _request.multiplier = 2;
    _request.fpsNumerator = 60;
    _request.fpsDenominator = 1;
    _request.quality = SPFRCQualityNormal;
    _request.engineID = @"apple.frc";
    _request.modelID = @"vt.frc.normal";
    _request.qualityID = @"normal";
    _request.scaleEngine = SPLiveScaleLanczos;
    _request.outputWidth = 1920;
    _request.outputHeight = 1080;
    _presentationFailuresLifetime = [NSMutableDictionary dictionary];
    _presentationFailuresEpoch = [NSMutableDictionary dictionary];
    _firstPresentationFailureLifetime = [NSMutableDictionary dictionary];
    _firstPresentationFailureEpoch = [NSMutableDictionary dictionary];
    _ignoredPresentedCallbacks = [NSMutableDictionary dictionary];
    _resolved = [[SPLiveResolvedPlan alloc] init];
    _sourceGeneration = 1;
    _configVersion = 1;
    _nextIdentity = 1;
    _windowStart = SPHostNow();
    _frcEwmaSec = 0.030;
    _scaleEwmaSec = 0.004;
    _probeMonotonic = YES;
    _probeSizeOK = YES;
    _prepareQ = dispatch_queue_create("app.khuaplayer.live-prepare",
                                     dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    dispatch_queue_set_specific(_q, SPLiveQueueKey, (__bridge void *)self, NULL);
    _epochMonotonic = YES;
    [self beginMeasurementEpoch];
    VTPixelTransferSessionCreate(kCFAllocatorDefault, &_transfer);
    return self;
}

- (void)dealloc {
    [self stop];
    if (_transfer) CFRelease(_transfer);
}

- (SPLiveResolvedPlan *)resolvedPlan { return _resolved; }

- (NSDictionary *)rememberStats:(NSDictionary *)stats {
    std::lock_guard<std::mutex> lock(_statsMx);
    _statsSnapshot = stats;
    return stats;
}

- (NSDictionary<NSString *, id> *)stats {
    if (dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self) return [self rememberStats:[self currentStats]];
    __block NSDictionary *value = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(_q, ^{
        value = [self rememberStats:[self currentStats]];
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_MSEC)) != 0) {
        std::lock_guard<std::mutex> lock(_statsMx);
        NSMutableDictionary *stale = [(_statsSnapshot ?: @{}) mutableCopy];
        stale[@"snapshotStale"] = @YES;
        return stale;
    }
    return value ?: @{};
}

- (int)inboundCount {
    std::lock_guard<std::mutex> lock(_inMx);
    return (int)_inbound.size();
}

- (NSDictionary *)currentStats {
    std::vector<int64_t> samples = _latencyNs;
    std::sort(samples.begin(), samples.end());
    double p95 = -1;
    if (!samples.empty()) {
        size_t index = (size_t)((samples.size() - 1) * 95 / 100);
        p95 = (double)samples[index] / 1e6;
    }
    NSMutableArray *epochHistogram = [NSMutableArray arrayWithCapacity:201];
    for (int i = 0; i < 201; ++i) [epochHistogram addObject:@(_epochHist[i])];
    double seconds = (double)SPHostToNs(SPHostNow() - _windowStart) / 1e9;
    if (seconds < 0.25) seconds = 0.25;
    double inputFPS = _fpsMeter.inputRate((int64_t)(CACurrentMediaTime() * 1e9));
    double requestedFPS = -1;
    if (_resolved.committed && _resolved.interpolationActive && _request.interpolationEnabled && _request.rateKind == SPLiveRateFixedFPS && _request.fpsDenominator > 0)
        requestedFPS = (double)_request.fpsNumerator / (double)_request.fpsDenominator;
    else if (_resolved.committed && _resolved.interpolationActive && _request.interpolationEnabled && _request.rateKind == SPLiveRateMultiplier && inputFPS > 0)
        requestedFPS = inputFPS * _request.multiplier;
    return @{
        @"captured": @(_captured),
        @"idle": @(_idle),
        @"complete": @(_completeFrames),
        @"interrupted": @(_interrupted),
        @"syntheticOK": @(_syntheticOK),
        @"syntheticFail": @(_syntheticFail),
        @"scheduledSynthetic": @(_scheduledSynthetic),
        @"staticHoldPhases": @(_staticHoldPhases), @"epochStaticHoldPhases": @(_epochStaticHoldPhases),
        @"submitted": @(_submitted),
        @"presentedSource": @(_presentedSource),
        @"presentedSynthetic": @(_presentedSynthetic),
        @"presented": @(_presentedSource + _presentedSynthetic),
        @"presentationEndpoint": _scoreOutput ? @"output" : @"preview",
        @"rateKind": _request.rateKind == SPLiveRateMultiplier ? @"multiplier" : @"fixedFPS",
        @"rateMultiplier": @(_request.multiplier),
        @"fixedFPSNumerator": @(_request.fpsNumerator),
        @"fixedFPSDenominator": @(_request.fpsDenominator),
        @"estimatedRequestedFPS": @(requestedFPS),
        @"requestedFPSIsEstimated": @(_request.rateKind == SPLiveRateMultiplier),
        @"captureCapFPS": @(_request.captureCapFPS),
        @"displayRefreshHz": @(_request.displayRefreshHz),
        @"presentationPolicy": [self requestUsesLatestPresentation:_request] ? @"latest-bounded" : @"deadline",
        @"viewMode": _request.viewMode == SPLiveViewOriginal ? @"original" : (_request.viewMode == SPLiveViewCompare ? @"compare" : @"enhanced"),
        @"outputWarmMode": @(_outputWarmMode),
        @"outputWarmEnhancedSize": @[@(_outputWarmEnhancedWidth), @(_outputWarmEnhancedHeight)],
        @"outputWarmOriginalSize": @[@(_outputWarmOriginalWidth), @(_outputWarmOriginalHeight)],
        @"rifePendingPairs": @(_rifePending.empty() ? 0 : 1),
        @"rifeSlowMode": @(_rifeSlowMode),
        @"lowPrescaleSlowMode": @(_lowPrescaleSlowMode),
        @"outputWarmToken": @(_outputSurfaceToken),
        @"outputWarmGPUCompleted": @(_outputWarmGPUCompleted),
        @"outputWarmGPUFailed": @(_outputWarmGPUFailed),
        @"outputWarmRejected": @(_outputWarmRejected),
        @"outputPresentedZeroTime": @(_outputPresentedZeroTime),
        @"outputPresentedValidTime": @(_outputPresentedValidTime),
        @"epochPhysicalSource": @(_epochPhysicalSource),
        @"epochPhysicalSynthetic": @(_epochPhysicalSynthetic),
        @"deadlineDrops": @(_deadlineDrops),
        @"lateReadyDrops": @(_lateReadyDrops), @"staleReadyDrops": @(_staleReadyDrops),
        @"dueMergeDrops": @(_dueMergeDrops), @"pendingExpiredDrops": @(_pendingExpiredDrops),
        @"slotEvictionDrops": @(_slotEvictionDrops), @"captureToModelReadyP95ms": @(SPPercentileMs(_captureToModelReadyNs)),
        @"captureToOutputReadyP95ms": @(SPPercentileMs(_captureToOutputReadyNs)),
        @"sceneSkips": @(_sceneSkips),
        @"queueDrops": @(_queueDrops),
        @"engineUnavailableDropsLifetime": @(_engineUnavailableDrops), @"inflightLimitDropsLifetime": @(_inflightLimitDrops),
        @"engineSubmissionRejectedDropsLifetime": @(_engineSubmissionRejectedDrops),
        @"stoppedDrops": @(_stoppedDrops),
        @"generationDrops": @(_generationDrops),
        @"clockRetiredJobsLifetime": @(_clockRetiredJobs), @"clockRetiredModelOutputsLifetime": @(_clockRetiredModelOutputs),
        @"clockRetiredPhaseDropsLifetime": @(_clockRetiredPhaseDrops),
        @"renderDrops": @(_renderDrops),
        @"renderDropsScope": @"synchronous scored rejections since last probe reset",
        @"presentationFailuresLifetime": [_presentationFailuresLifetime copy],
        @"presentationFailuresEpoch": [_presentationFailuresEpoch copy],
        @"firstPresentationFailureLifetime": [_firstPresentationFailureLifetime copy],
        @"firstPresentationFailureEpoch": [_firstPresentationFailureEpoch copy],
        @"epochPhysicalCountsMethod": @"callback-order filtered estimate; see presentationOrder for presented-time order",
        @"stopped": @(_stopped),
        @"sourceGeneration": @(_sourceGeneration),
        @"measurementEpoch": @(_measurementEpoch),
        @"epochSamples": @(_epochSamples),
        @"epochP95ms": @(p95),
        @"epochMonotonic": @(_epochMonotonic),
        @"epochCallbackMonotonic": @(_epochMonotonic),
        @"ignoredPresentedCallbacksLifetime": [_ignoredPresentedCallbacks copy],
        @"presentationOrder": [self presentationOrderSummary],
        @"sizeChain": [self sizeChainSnapshot],
        @"epochDuplicates": @(_epochDuplicates),
        @"presentedWidth": @(_epochWidth),
        @"presentedHeight": @(_epochHeight),
        @"presentedSizeChanges": @(_epochSizeChanges),
        @"epochScheduled": @(_epochScheduled),
        @"epochPresentedSynthetic": @(_epochPresentedSynthetic),
        @"epochPresentedSource": @(_epochPresentedSource),
        @"epochDeadline": @(_epochDeadline),
        @"epochQueueDrops": @(_epochQueueDrops),
        @"phaseBatchSplits": @(_phaseBatchSplits),
        @"copyEntryP95ms": @(SPPercentileMs(_copyEntryNs)),
        @"latencyHistogramMs": epochHistogram,
        @"presentedCallbacks": @(_presentedCallbacks),
        @"inflight": @(_inflight),
        @"playoutSlots": @((int)_slots.size()),
        @"peakSlots": @(_peakSlots),
        @"slotCap": @([self slotCap]),
        @"heldFrames": @((int)_held.size()),
        @"queued": @([self inboundCount]),
        @"p95ms": @(p95),
        @"delayMs": @((double)SPHostToNs(_delayHost) / 1e6),
        @"delayClamped": @(_delayClamped),
        @"interactiveCapMs": @(_request.quality == SPFRCQualityHigh ? SPQualityCapSec * 1000.0 : SPInteractiveCapSec * 1000.0),
        @"interactiveTier": _request.quality == SPFRCQualityHigh ? @"quality" : @"normal",
        @"frcP95ms": @(SPPercentileMs(_frcNs)),
        @"scaleP95ms": @(SPPercentileMs(_scaleNs)),
        @"transferP95ms": @(SPPercentileMs(_transferNs)),
        @"queueP95ms": @(SPPercentileMs(_queueNs)),
        @"playheadP95ms": @(SPPercentileMs(_playheadNs)),
        @"drawableWaitP95ms": @(SPPercentileMs(_drawableWaitNs)),
        @"notifyGapP95ms": @(SPPercentileMs(_presentGapNs)),
        @"presentGapP95ms": @(SPPercentileMs(_presentGapNs)),
        @"presentMediaLagP95ms": @(SPPercentileMs(_presentMediaLagNs)),
        @"gpuToDisplayP95ms": @(SPPercentileMs(_gpuToDisplayNs)),
        @"captureToDisplayP95ms": @(SPPercentileMs(_captureToDisplayNs)),
        @"displayTimingNote": @"CAMetalDrawable.presentedTime and CACurrentMediaTime share media time; subtract callback delivery lag from mach host intervals. Existing capture-to-callback metric is unchanged.",
        @"occludedPresents": @(_occludedPresents),
        @"engineID": _resolved.engineID ?: @"",
        @"modelID": _resolved.modelID ?: @"",
        @"qualityID": _request.qualityID ?: @"",
        @"scaleEngineID": _resolved.scaleEngineID ?: @"",
        @"scaleQualityID": _resolved.scaleQualityID ?: @"",
        @"sourcePixelFormat": @(_sourcePixelFormat),
        @"frcEwmaMs": @(_frcEwmaSec * 1000.0),
        @"scaleEwmaMs": @(_scaleEwmaSec * 1000.0),
        @"measuredScheduled": @(_measuredScheduled),
        @"centerSampleMs": @((double)_centerSampleNs / 1e6),
        @"centerSamples": @(_centerSamples),
        @"queueByteBudget": @(SPQueueByteBudget),
        @"sourceWidth": @(_width),
        @"sourceHeight": @(_height),
        @"lowLatencyPreScale": @([self requestUsesLowPrescale:_request width:_width height:_height]),
        @"lowLatencyPrescaledInputs": @(_lowPrescaleInputs), @"lowLatencySyntheticNoRescale": @(_lowSyntheticNoRescale),
        @"processingWidth": @(_resolved.interpolationActive ? (_lowLatency ? _lowLatency.width : _width) : 0),
        @"processingHeight": @(_resolved.interpolationActive ? (_lowLatency ? _lowLatency.height : _height) : 0),
        @"lowLatencyProcessingWidth": @(_lowLatency ? _lowLatency.width : 0),
        @"lowLatencyProcessingHeight": @(_lowLatency ? _lowLatency.height : 0),
        @"lowLatencyProcessingOrder": [self requestUsesLowPrescale:_request width:_width height:_height] ? @"lanczos-before-low-latency" : @"interpolation-before-scale",
        @"estimatedContentFPS": @((double)_windowChanged / seconds),
        @"callbackFPS": @((double)_windowCallbacks / seconds),
        @"overlayInputEstimateFPS": @(_fpsMeter.inputRate((int64_t)(CACurrentMediaTime() * 1e9))),
        @"overlayPresentedFPS": @(_fpsMeter.outputRate((int64_t)(CACurrentMediaTime() * 1e9))),
        @"interpolationActive": @(_resolved.interpolationActive),
        @"scaleActive": @(_resolved.scaleActive),
        @"configVersion": @(_configVersion),
    };
}

- (void)publishStats {
    int64_t now = SPHostNow();
    if (SPHostToNs(now - _lastStatsHost) < 200000000LL) return;
    _lastStatsHost = now;
    NSDictionary *stats = [self currentStats];
    void (^handler)(NSDictionary *) = self.statsHandler;
    if (!handler) return;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(stats); });
}

- (void)publishStatus:(NSString *)status failed:(BOOL)failed {
    void (^handler)(NSString *, BOOL, uint64_t) = self.statusHandler;
    if (!handler) return;
    uint64_t requestID = _ackRequestID;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(status, failed, requestID); });
}

- (BOOL)validateRequest:(SPLivePlanRequest *)request reason:(NSString **)reason {
    if (request.scaleEnabled && request.scaleEngine == SPLiveScaleAppleVideoSR && request.interpolationEnabled) {
        if (reason) *reason = @"Apple 视频超分暂不支持同时插帧，请先关闭帧生成。";
        return NO;
    }
    if (request.interpolationEnabled && request.rateKind == SPLiveRateMultiplier &&
        request.multiplier != 2 && request.multiplier != 3 && request.multiplier != 4) {
        if (reason) *reason = @"倍率只接受 X2、X3、X4";
        return NO;
    }
    if (request.interpolationEnabled && request.rateKind == SPLiveRateFixedFPS &&
        (request.fpsNumerator <= 0 || request.fpsDenominator <= 0)) {
        if (reason) *reason = @"自定义帧率的分子和分母都要大于 0";
        return NO;
    }
    if (request.outputWidth > 3840 || request.outputHeight > 2160) {
        if (reason) *reason = @"输出尺寸超过本轮 3840×2160 预算";
        return NO;
    }
    NSString *engine = request.engineID.length ? request.engineID : @"apple.frc";
    if (request.interpolationEnabled && [engine isEqualToString:@"distildrba.coreml"] &&
        (request.rateKind != SPLiveRateMultiplier || request.multiplier != 2)) {
        if (reason) *reason = @"DistilDRBA 当前支持 720p 来源和 X2。";
        return NO;
    }
    if (request.interpolationEnabled && [engine isEqualToString:@"apple.lowlatency"]) {
        if (![SPLowLatencyEngine isSupported]) {
            if (reason) *reason = @"这台系统没有 Apple 低延迟插帧";
            return NO;
        }
        if (request.rateKind == SPLiveRateMultiplier && request.multiplier == 3) {
            if (reason) *reason = @"低延迟只提供 1/2，或 1/4、1/2、3/4。X3 的 1/3 和 2/3 不会被改写，可改用 Apple 帧率转换。";
            return NO;
        }
        if (request.rateKind == SPLiveRateFixedFPS) {
            if (reason) *reason = @"低延迟不能表达固定帧率里的任意相位。请改用 Apple 帧率转换，或改成 X2 / X4。";
            return NO;
        }
    }
    if (request.interpolationEnabled && [engine isEqualToString:@"rife.metal"]) {
        NSString *model = request.modelID.length ? request.modelID : @"rife-v4.25";
        if (![model isEqualToString:@"rife-v4.25"] && ![model isEqualToString:@"rife-v4.26"]) {
            if (reason) *reason = @"RIFE 只有 4.25 和单独的 4.26 权重";
            return NO;
        }
    }
    return YES;
}

- (void)publishPlanState:(NSInteger)state reason:(NSString *)reason {
    if (state == 0) _holdFailureStatus = YES;
    if (state == 2) _holdFailureStatus = NO;
    void (^handler)(NSInteger, NSString *, NSString *, NSString *, uint64_t) = self.planHandler;
    if (!handler) return;
    NSString *engine = _ackEngineID ?: @"";
    NSString *model = _ackModelID ?: @"";
    NSString *text = reason ?: @"";
    uint64_t requestID = _ackRequestID;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(state, engine, model, text, requestID); });
}

- (void)retireEngines {
    [_engine invalidate];
    _engine = nil;
    [_lowLatency invalidate];
    _lowLatency = nil;
    [_rife invalidate];
    _rife = nil;
    [_distil invalidate];
    _distil = nil;
    _metal = nil;
}

- (BOOL)requestUsesAsyncEngine:(SPLivePlanRequest *)request {
    if (!request.interpolationEnabled) return NO;
    NSString *engine = request.engineID.length ? request.engineID : @"apple.frc";
    return [engine isEqualToString:@"apple.lowlatency"] || [engine isEqualToString:@"rife.metal"] || [engine isEqualToString:@"distildrba.coreml"];
}

- (BOOL)requestUsesAsyncScale:(SPLivePlanRequest *)request {
    return request.scaleEnabled && (request.scaleEngine == SPLiveScaleAppleLowLatencySR || request.scaleEngine == SPLiveScaleAppleVideoSR || request.scaleEngine == SPLiveScaleAnime4K || request.scaleEngine == SPLiveScaleRealCUGAN);
}

- (BOOL)requestUsesLatestScale:(SPLivePlanRequest *)request {
    return request.scaleEnabled && (request.scaleEngine == SPLiveScaleAnime4K || request.scaleEngine == SPLiveScaleRealCUGAN);
}

- (BOOL)requestUsesLowPrescale:(SPLivePlanRequest *)request width:(int)width height:(int)height {
    int w=request.outputWidth, h=request.outputHeight;
    return request.interpolationEnabled && [request.engineID isEqualToString:@"apple.lowlatency"] &&
        request.scaleEnabled && request.scaleEngine==SPLiveScaleLanczos && w>0 && h>0 &&
        !(w&1) && !(h&1) && width>0 && height>0 && w<width && h<height &&
        (int64_t)w*height==(int64_t)h*width;
}

- (BOOL)requestUsesLatestPresentation:(SPLivePlanRequest *)request {
    return [self requestUsesLatestScale:request] || (request.interpolationEnabled &&
        ([request.engineID isEqualToString:@"distildrba.coreml"] ||
         ([request.engineID isEqualToString:@"rife.metal"] && _rifeSlowMode) ||
         ([request.engineID isEqualToString:@"apple.lowlatency"] && _lowPrescaleSlowMode)));
}

- (void)clearPendingRife {
    if (!_rifePending.empty()) {
        for (uint64_t identity : {_rifePending.front().frameA, _rifePending.front().frameB}) {
            auto found = _held.find(identity);
            if (found != _held.end() && found->second.pins > 0) found->second.pins -= 1;
        }
        _rifePending.clear();
    }
    _rifePendingGeneration = 0;
}

- (void)resetAsyncScaleOnQueue {
    ++_srSequence;
    while (!_srPending.empty()) { SPReleaseSRJob(_srPending.front()); _srPending.pop_front(); }
    _srPendingBytes = 0;
    _srBusy = NO;
    _srFailed = NO;
    _videoSRDiscontinuity = YES;
}

- (void)installRequest:(SPLivePlanRequest *)request lowLatency:(SPLowLatencyEngine *)lowLatency rife:(SPRifeBridge *)rife distil:(SPDistilDRBA *)distil appleSR:(SPAppleLowLatencySR *)appleSR videoSR:(SPAppleVideoSR *)videoSR animeSR:(SPAnime4K *)animeSR cuganSR:(SPRealCUGAN *)cuganSR {
    SPFRCEngine *oldEngine = _engine;
    SPLowLatencyEngine *oldLow = _lowLatency;
    SPRifeBridge *oldRife = _rife;
    SPDistilDRBA *oldDistil = _distil;
    SPAppleLowLatencySR *oldSR = _appleSR;
    SPAppleVideoSR *oldVideoSR = _videoSR;
    SPAnime4K *oldAnimeSR = _animeSR;
    SPRealCUGAN *oldCuganSR = _cuganSR;
    SPFrameBudgetMetal *oldMetal = _metal;
    SPSpatialScaler *oldScaler = _scaler;
    SPSpatialScaler *oldBaseline = _baselineScaler;
    SPLivePlanRequest *oldRequest = _request;
    BOOL oldReady = _sessionReady;
    BOOL oldInterpolationActive = _resolved.interpolationActive;
    BOOL oldScaleActive = _resolved.scaleActive;
    BOOL oldCommitted = _resolved.committed;
    _engine = nil;
    _metal = nil;
    _scaler = nil;
    _baselineScaler = nil;
    _lowLatency = lowLatency;
    _rife = rife;
    _distil = distil;
    _appleSR = appleSR;
    _videoSR = videoSR;
    _animeSR = animeSR;
    _cuganSR = cuganSR;
    _request = request;
    _sessionReady = NO;
    NSError *error = nil;
    BOOL ok = [self buildOnQueue:&error];
    if (!ok) {
        [lowLatency invalidate];
        [rife invalidate];
        [distil invalidate];
        [appleSR invalidate];
        [videoSR invalidate];
        [animeSR invalidate];
        [cuganSR invalidate];
        _engine = oldEngine;
        _lowLatency = oldLow;
        _rife = oldRife;
        _distil = oldDistil;
        _appleSR = oldSR;
        _videoSR = oldVideoSR;
        _animeSR = oldAnimeSR;
        _cuganSR = oldCuganSR;
        _metal = oldMetal;
        _scaler = oldScaler;
        _baselineScaler = oldBaseline;
        _request = oldRequest;
        _sessionReady = oldReady;
        NSString *reason = error.localizedDescription ?: @"准备失败，仍使用上一份可用计划";
        [self refreshResolvedOnQueue];
        _resolved.interpolationActive = oldInterpolationActive;
        _resolved.scaleActive = oldScaleActive;
        _resolved.committed = oldCommitted;
        _resolved.unavailableReason = reason;
        [self publishStatus:reason failed:YES];
        [self publishPlanState:0 reason:reason];
        return;
    }
    [oldEngine invalidate];
    [oldLow invalidate];
    [oldRife invalidate];
    [oldDistil invalidate];
    [oldSR invalidate];
    [oldVideoSR invalidate];
    [oldAnimeSR invalidate];
    [oldCuganSR invalidate];
    [self clearPendingRife];
    _rifeSlowMode = NO;
    _lowPrescaleSlowMode = NO;
    [self resetAsyncScaleOnQueue];
    _configVersion += 1;
    _inflightEpoch = _configVersion;
    _inflight = 0;
    _havePair = NO;
    [self clearPlaySlots];
    if (distil || rife) {
        if (_lastEnhanced) { CVPixelBufferRelease(_lastEnhanced); _lastEnhanced = nullptr; }
        if (_lastOriginal) { CVPixelBufferRelease(_lastOriginal); _lastOriginal = nullptr; }
        _haveLastPts = NO;
    }
    [self resetSchedulerOnQueue];
    [self recomputeInteractiveDelay];
    [self refreshResolvedOnQueue];
    _resolved.committed = YES;
    _resolved.configVersion = _configVersion;
    [self beginMeasurementEpoch];
    [self publishPlanState:2 reason:_resolved.activeSummary ?: @"增强运行"];
}

- (void)startAsyncEngine:(SPLivePlanRequest *)request {
    _asyncPrepareFailed = NO;
    if (_width < 2 || _height < 2) {
        _request = request;
        _sessionReady = NO;
        _resolved.committed = NO;
        [self refreshResolvedOnQueue];
        [self publishStatus:@"计划已记下，等到来源画面后准备引擎" failed:NO];
        [self publishPlanState:1 reason:@"计划已记下，等到来源画面后准备引擎"];
        return;
    }
    _preparing = YES;
    _prepareToken += 1;
    uint64_t token = _prepareToken;
    int width = _width;
    int height = _height;
    SPLivePlanRequest *copy = [request copy];
    NSString *engine = copy.engineID.length ? copy.engineID : @"apple.frc";
    [self publishStatus:@"正在准备引擎" failed:NO];
    [self publishPlanState:1 reason:@"正在准备引擎，当前画面仍用上一份已生效的计划"];
    dispatch_async(_prepareQ, ^{
        NSError *error = nil;
        SPLowLatencyEngine *lowLatency = nil;
        SPRifeBridge *rife = nil;
        SPDistilDRBA *distil = nil;
        SPAppleLowLatencySR *appleSR = nil;
        SPAppleVideoSR *videoSR = nil;
        SPAnime4K *animeSR = nil;
        SPRealCUGAN *cuganSR = nil;
        if (copy.interpolationEnabled && [engine isEqualToString:@"apple.lowlatency"]) {
            NSInteger frames = (copy.rateKind == SPLiveRateFixedFPS || copy.multiplier >= 4) ? 2 : 1;
            lowLatency = [[SPLowLatencyEngine alloc] init];
            BOOL pre=[self requestUsesLowPrescale:copy width:width height:height];
            if (![lowLatency prepareWidth:pre ? copy.outputWidth : width height:pre ? copy.outputHeight : height frames:frames error:&error]) lowLatency = nil;
            else copy.modelID = lowLatency.modelID;
        } else if (copy.interpolationEnabled && [engine isEqualToString:@"rife.metal"]) {
            if (!copy.modelID.length) copy.modelID = @"rife-v4.25";
            if (!copy.qualityID.length) copy.qualityID = @"balanced";
            rife = [[SPRifeBridge alloc] init];
            if (![rife prepareModelID:copy.modelID quality:copy.qualityID width:width height:height error:&error]) rife = nil;
        } else if (copy.interpolationEnabled && [engine isEqualToString:@"distildrba.coreml"]) {
            copy.modelID = @"distildrba.v1.720p";
            distil = [[SPDistilDRBA alloc] init];
            if (![distil prepareWidth:width height:height error:&error]) distil = nil;
        }
        BOOL needsAsyncInterpolation = [self requestUsesAsyncEngine:copy];
        if (!error && [self requestUsesAsyncScale:copy]) {
            BOOL autoAnime = (copy.scaleEngine == SPLiveScaleAnime4K || copy.scaleEngine == SPLiveScaleRealCUGAN) && copy.outputWidth == 0 && copy.outputHeight == 0;
            int targetWidth = autoAnime ? width * 2 : copy.outputWidth;
            int targetHeight = autoAnime ? height * 2 : copy.outputHeight;
            float scale = width > 0 ? (float)targetWidth / (float)width : 0;
            float scaleH = height > 0 ? (float)targetHeight / (float)height : 0;
            if (targetWidth < 2 || targetHeight < 2 || fabsf(scale - scaleH) > 0.0001f) {
                error = SPLiveError(37, @"低延迟超分需要与来源比例一致的明确输出尺寸。 ");
            } else {
                if (copy.scaleEngine == SPLiveScaleAnime4K || copy.scaleEngine == SPLiveScaleRealCUGAN) {
                    if (fabsf(scale - 2.0f) > 0.0001f) error = SPLiveError(39, @"该动画超分当前使用 2× 来源尺寸。");
                    else if (copy.scaleEngine == SPLiveScaleAnime4K) { animeSR = [[SPAnime4K alloc] init]; if (![animeSR prepareWidth:width height:height error:&error]) animeSR = nil; }
                    else { cuganSR = [[SPRealCUGAN alloc] init]; if (![cuganSR prepareWidth:width height:height variant:copy.scaleQualityID ?: @"none" error:&error]) cuganSR = nil; }
                } else if (copy.scaleEngine == SPLiveScaleAppleVideoSR) {
                    int integerScale = (int)roundf(scale);
                    if (fabsf(scale-integerScale) > 0.0001f) error = SPLiveError(38, @"视频超分需要支持的整数倍率。");
                    else { videoSR = [[SPAppleVideoSR alloc] init]; if (![videoSR prepareWidth:width height:height scale:integerScale error:&error]) videoSR = nil; }
                } else {
                    appleSR = [[SPAppleLowLatencySR alloc] init];
                    if (![appleSR prepareWidth:width height:height scale:scale error:&error]) appleSR = nil;
                }
            }
        }
        dispatch_async(self->_q, ^{
            if (token != self->_prepareToken) {
                [lowLatency invalidate];
                [rife invalidate];
                [distil invalidate];
                [appleSR invalidate];
                [videoSR invalidate];
                [animeSR invalidate];
                [cuganSR invalidate];
                return;
            }
            self->_preparing = NO;
            if (error || (needsAsyncInterpolation && !lowLatency && !rife && !distil) || ([self requestUsesAsyncScale:copy] && !appleSR && !videoSR && !animeSR && !cuganSR)) {
                [lowLatency invalidate]; [rife invalidate]; [distil invalidate]; [appleSR invalidate]; [videoSR invalidate]; [animeSR invalidate]; [cuganSR invalidate];
                self->_asyncPrepareFailed = YES;
                NSString *reason = error.localizedDescription ?: @"准备失败，仍使用上一份可用计划";
                self->_resolved.unavailableReason = reason;
                [self publishStatus:reason failed:YES];
                [self publishPlanState:0 reason:reason];
                return;
            }
            [self installRequest:copy lowLatency:lowLatency rife:rife distil:distil appleSR:appleSR videoSR:videoSR animeSR:animeSR cuganSR:cuganSR];
        });
    });
}

- (void)updateRequest:(SPLivePlanRequest *)request {
    SPLivePlanRequest *copy = [request copy];
    dispatch_async(_q, ^{
        self->_ackRequestID = copy.requestID;
        self->_ackEngineID = copy.engineID ?: @"";
        self->_ackModelID = copy.modelID ?: @"";
        // Every new request supersedes any preparation already in flight,
        // including when the new request is synchronous or is rejected.
        self->_prepareToken += 1;
        self->_preparing = NO;
        NSString *reason = nil;
        if (![self validateRequest:copy reason:&reason]) {
            self->_resolved.unavailableReason = reason;
            self->_resolved.requestedSummary = reason;
            [self publishStatus:reason failed:YES];
            [self publishPlanState:0 reason:reason];
            return;
        }
        BOOL needsEngine = copy.interpolationEnabled || copy.scaleEnabled;
        if ([self requestUsesAsyncEngine:copy] || [self requestUsesAsyncScale:copy]) {
            [self startAsyncEngine:copy];
            return;
        }
        if (self->_width < 2) {
            self->_request = copy;
            self->_resolved.committed = !needsEngine;
            self->_sessionReady = !needsEngine;
            [self recomputeInteractiveDelay];
            [self refreshResolvedOnQueue];
            [self publishStatus:needsEngine ? @"计划已记下，等到来源画面后准备引擎" : @"预览原画面" failed:NO];
            return;
        }
        SPFRCEngine *oldEngine = self->_engine;
        SPLowLatencyEngine *oldLow = self->_lowLatency;
        SPRifeBridge *oldRife = self->_rife;
        SPDistilDRBA *oldDistil = self->_distil;
        SPAppleLowLatencySR *oldSR = self->_appleSR;
        SPAppleVideoSR *oldVideoSR = self->_videoSR;
        SPAnime4K *oldAnimeSR = self->_animeSR;
        SPRealCUGAN *oldCuganSR = self->_cuganSR;
        SPFrameBudgetMetal *oldMetal = self->_metal;
        SPSpatialScaler *oldScaler = self->_scaler;
        SPSpatialScaler *oldBaseline = self->_baselineScaler;
        SPLivePlanRequest *oldRequest = self->_request;
        BOOL oldReady = self->_sessionReady;
        self->_engine = nil;
        self->_metal = nil;
        self->_scaler = nil;
        self->_baselineScaler = nil;
        self->_request = copy;
        self->_sessionReady = NO;
        NSError *error = nil;
        BOOL ok = [self buildOnQueue:&error];
        if (!ok) {
            [self->_engine invalidate];
            self->_engine = oldEngine;
            self->_metal = oldMetal;
            self->_scaler = oldScaler;
            self->_baselineScaler = oldBaseline;
            self->_request = oldRequest;
            self->_sessionReady = oldReady;
            self->_resolved.committed = oldReady;
            self->_resolved.unavailableReason = error.localizedDescription ?: @"准备失败，仍使用上一份可用计划";
            [self publishStatus:self->_resolved.unavailableReason failed:YES];
            [self publishPlanState:0 reason:self->_resolved.unavailableReason];
            return;
        }
        [oldEngine invalidate];
        [oldLow invalidate];
        [oldRife invalidate];
        [oldDistil invalidate];
        [oldSR invalidate];
        [oldVideoSR invalidate];
        [oldAnimeSR invalidate];
        [oldCuganSR invalidate];
        self->_lowLatency = nil;
        self->_rife = nil;
        self->_distil = nil;
        self->_appleSR = nil;
        self->_videoSR = nil;
        self->_animeSR = nil;
        self->_cuganSR = nil;
        [self resetAsyncScaleOnQueue];
        self->_configVersion += 1;
        self->_inflightEpoch = self->_configVersion;
        self->_inflight = 0;
        self->_havePair = NO;
        [self clearPlaySlots];
        [self resetSchedulerOnQueue];
        [self recomputeInteractiveDelay];
        [self refreshResolvedOnQueue];
        self->_resolved.committed = YES;
        self->_resolved.configVersion = self->_configVersion;
        [self beginMeasurementEpoch];
        if (self->_width < 2 && needsEngine) {
            [self publishStatus:@"计划已接受，等到来源画面后准备引擎" failed:NO];
            [self publishPlanState:1 reason:@"计划已接受，等到来源画面后准备引擎"];
        } else {
            [self publishPlanState:2 reason:self->_resolved.activeSummary ?: @"已生效"];
        }
    });
}

- (void)setViewMode:(SPLiveViewMode)mode {
    dispatch_async(_q, ^{
        if (self->_request.viewMode != mode) { self->_fpsMeter.resetOutput(); self->_fpsObservationEpoch += 1; }
        self->_request.viewMode = mode;
        if (!self->_lastEnhanced && !self->_lastOriginal) return;
        [self showPair:self->_lastEnhanced original:self->_lastOriginal pts:self->_lastRedrawPts
             synthetic:self->_lastSynthetic captureHost:0 frameID:0 redraw:YES];
    });
}

- (void)resetFPSObservations {
    dispatch_async(_q, ^{ self->_fpsMeter.reset(); self->_fpsObservationEpoch += 1; });
}

- (void)discardQueuedStateOnQueue {
    _fpsMeter.reset();
    _fpsObservationEpoch += 1;
    [self clearPendingRife];
    _rifeSlowMode = NO;
    _lowPrescaleSlowMode = NO;
    [self resetAsyncScaleOnQueue];
    [self clearPlaySlots];
    self->_pending.clear();
    self->_marks.clear();
    self->_haveAnchor = NO;
    self->_haveLastPts = NO;
    self->_havePreviousSourcePts = NO;
    self->_previousSourceIdentity = 0;
    self->_havePair = NO;
    self->_haveLuma = NO;
    self->_lastPairB = 0;
    if (self->_clock) {
        dispatch_source_cancel(self->_clock);
        self->_clock = nil;
    }
    {
        std::lock_guard<std::mutex> lock(self->_inMx);
        while (!self->_inbound.empty()) {
            CVPixelBufferRelease(self->_inbound.front().buffer);
            self->_inbound.pop_front();
        }
    }
    for (auto &entry : self->_held) {
        if (entry.second.source) CVPixelBufferRelease(entry.second.source);
        if (entry.second.yuv) CVPixelBufferRelease(entry.second.yuv);
        if (entry.second.lowPrescaled) CVPixelBufferRelease(entry.second.lowPrescaled);
    }
    self->_held.clear();
    self->_inflightEpoch += 1;
    self->_inflight = 0;
    [self resetSchedulerOnQueue];
}

- (void)adoptSourceGeneration:(uint64_t)generation {
    dispatch_async(_q, ^{
        if (generation < self->_sourceGeneration) return;
        BOOL same = generation == self->_sourceGeneration;
        if (same && !self->_stopped) {
            [self->_preview setGeneration:generation];
            [self->_outputPreview setGeneration:generation];
            return;
        }
        self->_prepareToken += 1;
        self->_preparing = NO;
        self->_asyncPrepareFailed = NO;
        if ([self requestUsesAsyncScale:self->_request] && (self->_appleSR || self->_videoSR || self->_animeSR || self->_cuganSR)) {
            [self->_appleSR invalidate];
            [self->_videoSR invalidate];
            [self->_animeSR invalidate];
            [self->_cuganSR invalidate];
            self->_appleSR = nil;
            self->_videoSR = nil;
            self->_animeSR = nil;
            self->_cuganSR = nil;
            self->_sessionReady = NO;
        }
        self->_sourceGeneration = generation;
        if (self->_distil || self->_rife || self->_lowLatency) {
            if (self->_lastEnhanced) { CVPixelBufferRelease(self->_lastEnhanced); self->_lastEnhanced = nullptr; }
            if (self->_lastOriginal) { CVPixelBufferRelease(self->_lastOriginal); self->_lastOriginal = nullptr; }
        }
        self->_stopped = NO;
        self->_stoppedDrops = 0;
        self->_generationDrops = 0;
        [self discardQueuedStateOnQueue];
        [self beginMeasurementEpoch];
        [self->_preview setGeneration:generation];
        [self->_outputPreview setGeneration:generation];
        if (!self->_sessionReady) [self publishStatus:@"来源已接入" failed:NO];
    });
}

- (void)resetSchedulerOnQueue {
    sp::SPRateRequest rate;
    BOOL valid = YES;
    if (!_request.interpolationEnabled) {
        _resolved.interpolationActive = NO;
        return;
    }
    if (_request.rateKind == SPLiveRateMultiplier) {
        rate.kind = sp::SPRateKind::Multiplier;
        rate.multiplier = (int)_request.multiplier;
        _resolved.targetNumerator = _request.multiplier;
        _resolved.targetDenominator = 1;
    } else {
        rate.kind = sp::SPRateKind::FixedFPS;
        rate.fps = sp::spMake(_request.fpsNumerator, _request.fpsDenominator);
        _resolved.targetNumerator = _request.fpsNumerator;
        _resolved.targetDenominator = _request.fpsDenominator;
        if (_request.fpsNumerator <= 0 || _request.fpsDenominator <= 0) valid = NO;
    }
    if (!valid || !_scheduler.reset(rate, _configVersion, sp::spMake(1, 2))) {
        _resolved.unavailableReason = @"帧率请求无效";
        _resolved.interpolationActive = NO;
        [self publishStatus:@"帧率请求无效" failed:YES];
    }
}

- (void)refreshResolvedOnQueue {
    _resolved.configVersion = _configVersion;
    _resolved.colorPath = @"sdr.bt709.8bit";
    NSString *engine = _request.engineID.length ? _request.engineID : @"apple.frc";
    _resolved.engineID = engine;
    if (_request.modelID.length) _resolved.modelID = _request.modelID;
    else if ([engine isEqualToString:@"apple.frc"]) _resolved.modelID = _request.quality == SPFRCQualityHigh ? @"vt.frc.quality" : @"vt.frc.normal";
    _resolved.scaleEngineID = _request.scaleEngine == SPLiveScaleRealCUGAN ? @"realcugan" : (_request.scaleEngine == SPLiveScaleAnime4K ? @"anime4k" : (_request.scaleEngine == SPLiveScaleAppleVideoSR ? @"apple.video-sr" : (_request.scaleEngine == SPLiveScaleAppleLowLatencySR ? @"apple.low-sr" :
        (_request.scaleEngine == SPLiveScaleMetalFX ? @"metalfx.spatial" : @"lanczos"))));
    _resolved.scaleQualityID = _request.scaleEngine == SPLiveScaleRealCUGAN ? (_request.scaleQualityID ?: @"none") : @"";
    BOOL autoAnime = _request.scaleEnabled && (_request.scaleEngine == SPLiveScaleAnime4K || _request.scaleEngine == SPLiveScaleRealCUGAN) && _request.outputWidth == 0 && _request.outputHeight == 0;
    _resolved.outputWidth = autoAnime ? _width * 2 : (_request.scaleEnabled ? _request.outputWidth : _width);
    _resolved.outputHeight = autoAnime ? _height * 2 : (_request.scaleEnabled ? _request.outputHeight : _height);
    double target = 0;
    if (_request.interpolationEnabled && _request.rateKind == SPLiveRateFixedFPS && _request.fpsDenominator > 0) {
        target = (double)_request.fpsNumerator / (double)_request.fpsDenominator;
    } else if (_request.interpolationEnabled && _request.multiplier > 1) {
        double source = _fpsMeter.inputRate((int64_t)(CACurrentMediaTime() * 1e9));
        if (source <= 0 && _haveInterval && _intervalHost > 0) {
            double seconds = (double)SPHostToNs(_intervalHost) / 1e9;
            if (seconds > 0.001) source = 1.0 / seconds;
        }
        if (source > 0) target = source * (double)_request.multiplier;
    }
    _resolved.presentationLimited = target > 1 && _request.displayRefreshHz > 1 && target > _request.displayRefreshHz + 1.0;
    if (!_request.interpolationEnabled && !_request.scaleEnabled) {
        _resolved.interpolationActive = NO;
        _resolved.scaleActive = NO;
        _resolved.unavailableReason = @"";
        _sessionReady = YES;
        [self publishStatus:@"预览原画面" failed:NO];
    }
    NSString *requestedRate = _request.rateKind == SPLiveRateMultiplier
        ? [NSString stringWithFormat:@"X%ld", (long)_request.multiplier]
        : [NSString stringWithFormat:@"%lld/%lld", _request.fpsNumerator, _request.fpsDenominator];
    _resolved.requestedSummary = [NSString stringWithFormat:@"请求 %@ %@", requestedRate,
                                  _request.interpolationEnabled ? @"插帧" : @"不插帧"];
    _resolved.activeSummary = _resolved.committed
        ? [NSString stringWithFormat:@"生效 v%llu %@", (unsigned long long)_configVersion, requestedRate]
        : @"尚未生效";
}

- (uint64_t)resumeSource {
    __block uint64_t value = 1;
    dispatch_sync(_q, ^{ value = self->_sourceGeneration; });
    [self adoptSourceGeneration:value];
    dispatch_sync(_q, ^{});
    return value;
}

- (void)stop {
    void (^stopOnQueue)(void) = ^{
        self->_stopped = YES;
        self->_configVersion += 1;
        self->_inflightEpoch = self->_configVersion;
        self->_sessionReady = NO;
        self->_prepareToken += 1;
        self->_preparing = NO;
        self->_request.interpolationEnabled = NO;
        self->_request.scaleEnabled = NO;
        [self->_preview setGeneration:0];
        [self->_outputPreview setGeneration:0];
        [self->_engine invalidate];
        self->_engine = nil;
        [self->_lowLatency invalidate];
        self->_lowLatency = nil;
        [self->_rife invalidate];
        self->_rife = nil;
        [self->_distil invalidate];
        self->_distil = nil;
        [self->_appleSR invalidate];
        [self->_videoSR invalidate];
        [self->_animeSR invalidate];
        [self->_cuganSR invalidate];
        self->_appleSR = nil;
        self->_videoSR = nil;
        self->_animeSR = nil;
        self->_cuganSR = nil;
        self->_scaler = nil;
        self->_baselineScaler = nil;
        self->_metal = nil;
        [self discardQueuedStateOnQueue];
        if (self->_lastEnhanced) { CVPixelBufferRelease(self->_lastEnhanced); self->_lastEnhanced = nullptr; }
        if (self->_lastOriginal) { CVPixelBufferRelease(self->_lastOriginal); self->_lastOriginal = nullptr; }
    };
    if (dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self) stopOnQueue();
    else dispatch_sync(_q, stopOnQueue);
    [self publishStatus:@"已停止" failed:NO];
}

- (void)noteCaptureStatus:(NSInteger)statusCode {
    dispatch_async(_q, ^{
        self->_captured += 1;
        self->_windowCallbacks += 1;
        if (statusCode == 1) self->_idle += 1;
        else if (statusCode == 2) {
            self->_interrupted += 1;
            [self publishStatus:@"来源中断" failed:YES];
        } else self->_completeFrames += 1;
        int64_t elapsed = SPHostToNs(SPHostNow() - self->_windowStart);
        if (elapsed > 1000000000LL) {
            self->_windowStart = SPHostNow();
            self->_windowCallbacks = 0;
            self->_windowChanged = 0;
        }
        [self publishStats];
    });
}

- (void)pushPixelBuffer:(CVPixelBufferRef)buffer
                 ptsNum:(int64_t)ptsNum
                 ptsDen:(int64_t)ptsDen
                   host:(int64_t)host
             generation:(uint64_t)generation {
    [self pushPixelBuffer:buffer ptsNum:ptsNum ptsDen:ptsDen host:host readyHost:host generation:generation];
}

- (void)pushPixelBuffer:(CVPixelBufferRef)buffer
                 ptsNum:(int64_t)ptsNum
                 ptsDen:(int64_t)ptsDen
                   host:(int64_t)host
              readyHost:(int64_t)readyHost
             generation:(uint64_t)generation {
    if (!buffer || ptsDen == 0) return;
    CVPixelBufferRetain(buffer);
    std::lock_guard<std::mutex> lock(_inMx);
    const NSUInteger cap = [self inboundCap];
    if (_inbound.size() >= cap) {
        CVPixelBufferRelease(_inbound.front().buffer);
        _inbound.pop_front();
        _queueDrops += 1;
        _epochQueueDrops += 1;
    }
    SPLiveInbound item;
    item.buffer = buffer;
    item.ptsNum = ptsNum;
    item.ptsDen = ptsDen;
    item.host = host;
    item.readyHost = readyHost > 0 ? readyHost : host;
    item.generation = generation;
    _inbound.push_back(item);
    if (!_pumpQueued) {
        _pumpQueued = YES;
        dispatch_async(_q, ^{ [self pump]; });
    }
}

- (CVPixelBufferRef)transfer:(CVPixelBufferRef)source format:(OSType)format {
    if (!source || !_transfer) return NULL;
    if (CVPixelBufferGetPixelFormatType(source) == format && !SPBufferIsHDR(source)) {
        CVPixelBufferRetain(source);
        return source;
    }
    int width = (int)CVPixelBufferGetWidth(source);
    int height = (int)CVPixelBufferGetHeight(source);
    width &= ~1;
    height &= ~1;
    if (width < 2 || height < 2) return NULL;
    CVPixelBufferRef destination = SPCreateBuffer(width, height, format);
    if (!destination) return NULL;
    SPForceSDRAttachments(source);
    SPForceSDRAttachments(destination);
    int64_t transferStart = SPHostNow();
    OSStatus status = VTPixelTransferSessionTransferImage(_transfer, source, destination);
    SPPushSample(_transferNs, SPHostToNs(SPHostNow() - transferStart));
    if (status != noErr) {
        CVPixelBufferRelease(destination);
        return NULL;
    }
    SPForceSDRAttachments(destination);
    return destination;
}

- (CVPixelBufferRef)yuvForIdentity:(uint64_t)identity {
    auto found = _held.find(identity);
    if (found == _held.end()) return NULL;
    if (!found->second.yuv) {
        found->second.yuv = [self transfer:found->second.source format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
    }
    return found->second.yuv;
}

- (CVPixelBufferRef)lowPrescaledForIdentity:(uint64_t)identity {
    auto found=_held.find(identity);
    if (found==_held.end() || !_scaler) return NULL;
    if (found->second.lowPrescaled && found->second.lowPrescaledConfig!=_configVersion) {
        CVPixelBufferRelease(found->second.lowPrescaled); found->second.lowPrescaled=nullptr;
    }
    if (!found->second.lowPrescaled) {
        CVPixelBufferRef bgra=[self transfer:found->second.source format:kCVPixelFormatType_32BGRA];
        if (!bgra) return NULL;
        found->second.lowPrescaled=[self scaleBuffer:bgra with:_scaler];
        if (found->second.lowPrescaled) _lowPrescaleInputs++;
        CVPixelBufferRelease(bgra);
        found->second.lowPrescaledConfig=_configVersion;
    }
    return found->second.lowPrescaled;
}

- (CVPixelBufferRef)displayBufferForSource:(CVPixelBufferRef)source {
    if (!source) return NULL;
    CVPixelBufferRef bgra = [self transfer:source format:kCVPixelFormatType_32BGRA];
    if (!bgra) return NULL;
    if (!_request.scaleEnabled) return bgra;
    int outW = _request.outputWidth > 0 ? _request.outputWidth : (int)CVPixelBufferGetWidth(bgra);
    int outH = _request.outputHeight > 0 ? _request.outputHeight : (int)CVPixelBufferGetHeight(bgra);
    outW &= ~1;
    outH &= ~1;
    if (!_scaler) {
        return bgra;
    }
    NSError *error = nil;
    CVPixelBufferRef scaled = [_scaler scaleBuffer:bgra error:&error];
    CVPixelBufferRelease(bgra);
    return scaled;
}

- (void)recordPresentationFailure:(NSString *)reason endpoint:(NSString *)endpoint generation:(uint64_t)generation config:(uint64_t)config epoch:(uint64_t)epoch frame:(uint64_t)frame {
    NSString *key = [NSString stringWithFormat:@"%@.%@", endpoint, reason ?: @"unknown"];
    NSDictionary *sample = @{ @"reason": reason ?: @"unknown", @"endpoint": endpoint, @"frameID": @(frame),
        @"generation": @(generation), @"configVersion": @(config), @"measurementEpoch": @(epoch), @"observedHost": @(SPHostNow()) };
    _presentationFailuresLifetime[key] = @([_presentationFailuresLifetime[key] unsignedLongLongValue] + 1);
    if (!_firstPresentationFailureLifetime[endpoint]) _firstPresentationFailureLifetime[endpoint] = sample;
    if (generation == _sourceGeneration && config == _configVersion && epoch == _measurementEpoch) {
        _presentationFailuresEpoch[key] = @([_presentationFailuresEpoch[key] unsignedLongLongValue] + 1);
        if (!_firstPresentationFailureEpoch[endpoint]) _firstPresentationFailureEpoch[endpoint] = sample;
    }
}

- (void)installPresentationHooks {
    SPLiveProcessor *strong = self;
    void (^block)(NSDictionary *) = ^(NSDictionary *info) {
        dispatch_async(strong->_q, ^{ [strong notePresented:info]; });
    };
    void (^failure)(NSString *, NSDictionary *) = ^(NSString *endpoint, NSDictionary *info) {
        dispatch_async(strong->_q, ^{ [strong recordPresentationFailure:info[@"reason"] endpoint:endpoint
            generation:[info[@"generation"] unsignedLongLongValue] config:[info[@"configVersion"] unsignedLongLongValue]
            epoch:[info[@"measurementEpoch"] unsignedLongLongValue] frame:[info[@"frameID"] unsignedLongLongValue]]; });
    };
    self.preview.presentationFailure = ^(NSDictionary *info) { failure(@"preview", info); };
    self.outputPreview.presentationFailure = ^(NSDictionary *info) { failure(@"output", info); };
    self.preview.presented = ^(NSDictionary *info) {
        NSMutableDictionary *tagged = [info mutableCopy]; tagged[@"endpoint"] = @"preview"; block(tagged);
    };
    self.outputPreview.presented = ^(NSDictionary *info) {
        dispatch_async(strong->_q, ^{
            if ([info[@"presentedTime"] doubleValue] > 0) strong->_outputPresentedValidTime++;
            else strong->_outputPresentedZeroTime++;
            NSMutableDictionary *tagged = [info mutableCopy]; tagged[@"endpoint"] = @"output";
            [strong notePresented:tagged];
        });
    };
    self.outputPreview.surfaceReady = ^(NSDictionary *info) {
        dispatch_async(strong->_q, ^{
            uint64_t generation = [info[@"generation"] unsignedLongLongValue];
            uint64_t config = [info[@"configVersion"] unsignedLongLongValue];
            if ([info[@"gpuCompleted"] boolValue]) strong->_outputWarmGPUCompleted++;
            else strong->_outputWarmGPUFailed++;
            strong->_outputWarmMode=[info[@"viewMode"] integerValue];
            strong->_outputWarmEnhancedWidth=[info[@"enhancedWidth"] intValue];
            strong->_outputWarmEnhancedHeight=[info[@"enhancedHeight"] intValue];
            strong->_outputWarmOriginalWidth=[info[@"originalWidth"] intValue];
            strong->_outputWarmOriginalHeight=[info[@"originalHeight"] intValue];
            if (!strong->_stopped && strong->_outputSurfaceToken && [info[@"counts"] boolValue] &&
                [info[@"gpuCompleted"] boolValue] && [info[@"windowVisible"] boolValue] &&
                [info[@"surfaceToken"] unsignedLongLongValue] == strong->_outputSurfaceToken &&
                [info[@"measurementEpoch"] unsignedLongLongValue] == strong->_measurementEpoch &&
                generation == strong->_sourceGeneration && config == strong->_configVersion &&
                strong->_resolved.committed && (strong->_resolved.interpolationActive || strong->_resolved.scaleActive)) {
                uint64_t token = strong->_outputSurfaceToken;
                strong->_outputSurfaceToken = 0;
                [strong.outputPreview setSurfaceToken:0];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (strong.outputSurfaceHandler) strong.outputSurfaceHandler(generation, config, token);
                });
            } else strong->_outputWarmRejected++;
        });
    };
}

- (void)awaitOutputSurfaceWithToken:(uint64_t)token {
    dispatch_async(_q, ^{ self->_outputSurfaceToken = token; [self.outputPreview setSurfaceToken:token]; });
}

- (NSDictionary *)sizeChainSnapshot {
    const auto sample = _presentationGeometry.get(_scoreOutput);
    if (!sample.valid || !_resolved.committed || _resolved.configVersion != _configVersion) return @{};
    return @{ @"endpoint": _scoreOutput ? @"output" : @"preview", @"sourceWidth": @(sample.sourceWidth), @"sourceHeight": @(sample.sourceHeight),
        @"processingWidth": @(sample.processingWidth), @"processingHeight": @(sample.processingHeight),
        @"bufferWidth": @(sample.bufferWidth), @"bufferHeight": @(sample.bufferHeight), @"drawableWidth": @(sample.drawableWidth), @"drawableHeight": @(sample.drawableHeight),
        @"presentedTimeNs": @(sample.presentedTimeNs), @"sourceGeneration": @(_sourceGeneration), @"configVersion": @(_configVersion), @"measurementEpoch": @(_measurementEpoch),
        @"engineID": _resolved.engineID ?: @"", @"modelID": _resolved.modelID ?: @"", @"downsampled": @([self requestUsesLowPrescale:_request width:_width height:_height]) };
}

- (NSDictionary *)presentationOrderSummary {
    auto convert = [](sp::PresentationSummary s) -> NSDictionary * {
        return @{ @"backwards": @(s.backwards), @"duplicates": @(s.duplicates), @"ambiguousTimes": @(s.ambiguousTimes),
                  @"invalidTimes": @(s.invalidTimes), @"invisible": @(s.invisible), @"excluded": @(s.excluded) };
    };
    return @{ @"preview": convert(_presentationOrder.summary(false)), @"output": convert(_presentationOrder.summary(true)),
              @"windowSize": @(_presentationOrder.events().size()), @"windowCapacity": @(sp::PresentationOrder::capacity),
              @"evictedSinceEpochStart": @(_presentationOrder.evicted()), @"coversWholeEpoch": @(_presentationOrder.evicted() == 0),
              @"scope": @"bounded callback window ordered by presentedTime; ambiguous ties excluded" };
}

- (NSDictionary *)presentationOrderDiagnostics {
    __block NSDictionary *result;
    void (^capture)(void) = ^{
        NSMutableArray *events = [NSMutableArray arrayWithCapacity:self->_presentationOrder.events().size()];
        for (const auto &e : self->_presentationOrder.events()) {
            [events addObject:@{ @"ptsNs": @(e.pts), @"presentedTimeNs": @(e.presented), @"frameID": @(e.frame),
                @"endpoint": e.output ? @"output" : @"preview", @"visible": @(e.visible), @"held": @(e.held), @"originalSynthetic": @(e.originalSynthetic) }];
        }
        result = @{ @"summary": [self presentationOrderSummary], @"sourceGeneration": @(self->_sourceGeneration),
                    @"configVersion": @(self->_configVersion), @"measurementEpoch": @(self->_measurementEpoch), @"eventsInCallbackOrder": events };
    };
    if (dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self) capture(); else dispatch_sync(_q, capture);
    return result;
}

- (void)notePresented:(NSDictionary *)info {
    uint64_t configVersion = [info[@"configVersion"] unsignedLongLongValue];
    uint64_t epoch = [info[@"measurementEpoch"] unsignedLongLongValue];
    NSString *ignored = ![info[@"counts"] boolValue] ? @"redrawOrUnscored" :
        ([info[@"generation"] unsignedLongLongValue] != _sourceGeneration ? @"generation" :
         (configVersion != 0 && configVersion != _configVersion ? @"configuration" :
          (epoch != 0 && epoch != _measurementEpoch ? @"epoch" : nil)));
    if (ignored) {
        NSString *key = [NSString stringWithFormat:@"%@.%@", info[@"endpoint"] ?: @"unknown", ignored];
        _ignoredPresentedCallbacks[key] = @([_ignoredPresentedCallbacks[key] unsignedLongLongValue] + 1);
        return;
    }
    sp::SPRational pts = sp::spMake([info[@"ptsNum"] longLongValue], [info[@"ptsDen"] longLongValue]);
    if (_probeWindowOpen && sp::spCmp(pts, _probeMinPts) < 0) return;
    const uint64_t meterFrameID = [info[@"frameID"] unsignedLongLongValue];
    auto meterMark = _marks.find(meterFrameID);
    const bool held = meterMark == _marks.end() || meterMark->second.held || meterMark->second.fpsEpoch != _fpsObservationEpoch;
    const double presentTime = [info[@"presentedTime"] doubleValue];
    __int128 ptsNs = pts.den > 0 ? (__int128)pts.num * 1000000000 / pts.den : INT64_MIN;
    const bool physicalVisible = [info[@"windowVisible"] boolValue] && ![info[@"occluded"] boolValue] && [info[@"exposed"] boolValue];
    if (ptsNs >= INT64_MIN && ptsNs <= INT64_MAX) {
        int64_t timeNs = presentTime > 0 && presentTime < (double)INT64_MAX / 1e9 ? (int64_t)(presentTime * 1e9) : 0;
        _presentationOrder.add({(int64_t)ptsNs, timeNs, meterFrameID, [info[@"endpoint"] isEqualToString:@"output"], physicalVisible,
                                held, [info[@"viewMode"] integerValue] == SPLiveViewOriginal && [info[@"synthetic"] boolValue]}, _sourceGeneration, configVersion ?: _configVersion, epoch ?: _measurementEpoch);
    }
    if (physicalVisible && !held && _resolved.committed && _resolved.interpolationActive && _resolved.configVersion == _configVersion &&
        presentTime > 0 && presentTime < (double)INT64_MAX / 1e9) {
        const bool output = [info[@"endpoint"] isEqualToString:@"output"];
        if (output == (bool)_scoreOutput) {
            sp::PresentationGeometrySample sample;
            sample.sourceWidth = _sourceWidth; sample.sourceHeight = _sourceHeight;
            sample.processingWidth = _lowLatency ? _lowLatency.width : _width;
            sample.processingHeight = _lowLatency ? _lowLatency.height : _height;
            sample.bufferWidth = [info[@"width"] intValue]; sample.bufferHeight = [info[@"height"] intValue];
            sample.drawableWidth = [info[@"drawableWidth"] intValue]; sample.drawableHeight = [info[@"drawableHeight"] intValue];
            sample.presentedTimeNs = (int64_t)(presentTime * 1e9);
            _presentationGeometry.record(output, sample);
        }
    }
    if (ptsNs >= INT64_MIN && ptsNs <= INT64_MAX && presentTime > 0 && presentTime < (double)INT64_MAX / 1e9) {
        const bool originalSynthetic = [info[@"viewMode"] integerValue] == SPLiveViewOriginal && [info[@"synthetic"] boolValue];
        const bool visible = [info[@"windowVisible"] boolValue] && ![info[@"occluded"] boolValue] && [info[@"exposed"] boolValue];
        _fpsMeter.presented((int64_t)ptsNs, (int64_t)(presentTime * 1e9), meterFrameID, held, originalSynthetic,
                            visible);
        if (visible && !held && !originalSynthetic && (!_physicalHavePts || sp::spCmp(pts, _physicalLastPts) > 0)) {
            if ([info[@"synthetic"] boolValue]) _epochPhysicalSynthetic++; else _epochPhysicalSource++;
            _physicalLastPts=pts; _physicalHavePts=YES;
        }
    }
    _presentedCallbacks += 1;
    if ([info[@"synthetic"] boolValue]) {
        _presentedSynthetic += 1;
        _epochPresentedSynthetic += 1;
    } else {
        _presentedSource += 1;
        _epochPresentedSource += 1;
    }
    int width = [info[@"width"] intValue];
    int height = [info[@"height"] intValue];
    if (_epochWidth == 0) {
        _epochWidth = width;
        _epochHeight = height;
    } else if (width != _epochWidth || height != _epochHeight) {
        _epochSizeChanges += 1;
        _epochWidth = width;
        _epochHeight = height;
    }
    if (_epochHavePts && sp::spCmp(pts, _epochLastPts) <= 0) {
        if (sp::spCmp(pts, _epochLastPts) == 0) _epochDuplicates += 1;
        else _epochMonotonic = NO;
    }
    _epochLastPts = pts;
    _epochHavePts = YES;
    int64_t captureHost = [info[@"captureHost"] longLongValue];
    int64_t presentedHost = [info[@"presentedHost"] longLongValue];
    int64_t latencyNs = (captureHost > 0 && presentedHost > captureHost) ? SPHostToNs(presentedHost - captureHost) : -1;
    if ([info[@"occluded"] boolValue]) _occludedPresents += 1;
    int64_t drawableWait = [info[@"drawableWaitNs"] longLongValue];
    if (drawableWait > 0) SPPushSample(_drawableWaitNs, drawableWait);
    int64_t gpuHost = [info[@"gpuHost"] longLongValue];
    if (presentedHost > 0 && gpuHost > 0 && presentedHost >= gpuHost) {
        SPPushSample(_presentGapNs, SPHostToNs(presentedHost - gpuHost));
    }
    double presentedTime = [info[@"presentedTime"] doubleValue];
    double handlerMedia = [info[@"handlerMediaTime"] doubleValue];
    if (presentedTime > 0 && handlerMedia > presentedTime) {
        int64_t deliveryNs = (int64_t)((handlerMedia - presentedTime) * 1e9);
        SPPushSample(_presentMediaLagNs, deliveryNs);
        if (latencyNs >= deliveryNs) SPPushSample(_captureToDisplayNs, latencyNs - deliveryNs);
        if (presentedHost > 0 && gpuHost > 0 && presentedHost >= gpuHost) {
            int64_t gpuToCallbackNs = SPHostToNs(presentedHost - gpuHost);
            if (gpuToCallbackNs >= deliveryNs) SPPushSample(_gpuToDisplayNs, gpuToCallbackNs - deliveryNs);
        }
    }
    if (latencyNs >= 0) {
        std::lock_guard<std::mutex> lock(_latencyMx);
        SPPushSample(_latencyNs, latencyNs);
        int bucket = (int)(latencyNs / 1000000LL);
        if (bucket < 0) bucket = 0;
        if (bucket > 200) bucket = 200;
        _epochHist[bucket] += 1;
        _epochSamples += 1;
    }
    uint64_t frameID = [info[@"frameID"] unsignedLongLongValue];
    double enhancedCenter = [info[@"enhancedCenter"] doubleValue];
    double originalCenter = [info[@"originalCenter"] doubleValue];
    auto mark = _marks.find(frameID);
    if (mark != _marks.end()) {
        if (presentedHost > 0 && mark->second.readyHost > 0) {
            SPPushSample(_queueNs, SPHostToNs(presentedHost - mark->second.readyHost));
        }
        if (presentedHost > 0 && mark->second.targetHost > 0) {
            SPPushSample(_playheadNs, SPHostToNs(presentedHost - mark->second.targetHost));
        }
        if (mark->second.hasCenter) {
            enhancedCenter = mark->second.enhancedCenter;
            originalCenter = mark->second.originalCenter;
        }
        _marks.erase(mark);
    }
    if (_probeAggregateOnly) {
        if (_probeHaveLast && sp::spCmp(_probeLastPts, pts) >= 0) _probeMonotonic = NO;
        _probeLastPts = pts;
        _probeHaveLast = YES;
        if ([info[@"width"] intValue] != _resolved.outputWidth || [info[@"height"] intValue] != _resolved.outputHeight) {
            _probeSizeOK = NO;
        }
    } else if (_probeOutputs) {
        NSMutableDictionary *row = [info mutableCopy];
        row[@"enhancedCenter"] = @(enhancedCenter);
        row[@"originalCenter"] = @(originalCenter);
        row[@"centerX"] = @(enhancedCenter);
        row[@"latencyMs"] = @(latencyNs >= 0 ? (double)latencyNs / 1e6 : -1);
        [_probeOutputs addObject:row];
    }
    [self publishStats];
}

- (void)clearPlaySlots {
    for (auto &slot : _slots) SPReleaseSlot(slot);
    _slots.clear();
}

- (void)rememberPair:(CVPixelBufferRef)enhanced original:(CVPixelBufferRef)original pts:(sp::SPRational)pts synthetic:(BOOL)synthetic {
    if (_lastEnhanced) CVPixelBufferRelease(_lastEnhanced);
    if (_lastOriginal) CVPixelBufferRelease(_lastOriginal);
    _lastEnhanced = enhanced ? CVPixelBufferRetain(enhanced) : nullptr;
    _lastOriginal = original ? CVPixelBufferRetain(original) : nullptr;
    _lastRedrawPts = pts;
    _lastSynthetic = synthetic;
}

- (void)ensureClock {
    if (_clock) return;
    _clock = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    SPLiveProcessor *strong = self;
    dispatch_source_set_event_handler(_clock, ^{ [strong drainDue]; });
    dispatch_resume(_clock);
    dispatch_source_set_timer(_clock, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
}

- (void)armClockAt:(int64_t)targetHost {
    [self ensureClock];
    int64_t now = SPHostNow();
    int64_t delta = targetHost > now ? targetHost - now : 0;
    int64_t ns = SPHostToNs(delta);
    if (ns < 0) ns = 0;
    dispatch_source_set_timer(_clock, dispatch_time(DISPATCH_TIME_NOW, ns), DISPATCH_TIME_FOREVER, 400 * NSEC_PER_USEC);
}

- (double)outputFramesPerSecond {
    if (_request.rateKind == SPLiveRateFixedFPS && _request.fpsDenominator > 0) {
        return (double)_request.fpsNumerator / (double)_request.fpsDenominator;
    }
    double source = 30.0;
    if (_haveInterval && _intervalHost > 0) {
        double seconds = (double)SPHostToNs(_intervalHost) / 1e9;
        if (seconds > 0.001) source = 1.0 / seconds;
    }
    if (!_request.interpolationEnabled) return source;
    int multiplier = _request.multiplier > 0 ? _request.multiplier : 1;
    return source * multiplier;
}

- (NSUInteger)slotCapByBytes {
    int w = _resolved.outputWidth > 0 ? _resolved.outputWidth : (_width > 0 ? _width : 1920);
    int h = _resolved.outputHeight > 0 ? _resolved.outputHeight : (_height > 0 ? _height : 1080);
    uint64_t planes = _request.viewMode == SPLiveViewCompare ? 2ull : 1ull;
    uint64_t bytes = (uint64_t)w * (uint64_t)h * 4ull * planes;
    if (bytes < 1) bytes = 1;
    NSUInteger cap = (NSUInteger)(SPQueueByteBudget / bytes);
    if (cap < 3) cap = 3;
    if (cap > 32) cap = 32;
    return cap;
}

- (NSUInteger)slotCap {
    NSUInteger byBytes = [self slotCapByBytes];
    double fps = [self outputFramesPerSecond];
    if (fps < 1) fps = 1;
    double delaySec = (double)SPHostToNs(_delayHost) / 1e9;
    NSUInteger byTime = (NSUInteger)(fps * delaySec + 0.999) + 2;
    if (byTime < 3) byTime = 3;
    return MIN(byBytes, byTime);
}

- (NSUInteger)inboundCap {
    double delaySec = (double)SPHostToNs(_delayHost) / 1e9;
    double sourceFps = 30.0;
    if (_haveInterval && _intervalHost > 0) {
        double seconds = (double)SPHostToNs(_intervalHost) / 1e9;
        if (seconds > 0.001) sourceFps = 1.0 / seconds;
    }
    NSUInteger cap = (NSUInteger)(sourceFps * delaySec + 0.999) + 2;
    if (cap < 4) cap = 4;
    if (cap > 12) cap = 12;
    return cap;
}

- (void)beginMeasurementEpoch {
    _fpsMeter.resetOutput();
    _fpsObservationEpoch += 1;
    _latencyNs.clear();
    _frcNs.clear();
    _scaleNs.clear();
    _transferNs.clear();
    _queueNs.clear();
    _playheadNs.clear();
    _drawableWaitNs.clear();
    _presentGapNs.clear();
    _presentMediaLagNs.clear();
    _gpuToDisplayNs.clear();
    _captureToDisplayNs.clear();
    _captureToModelReadyNs.clear();
    _captureToOutputReadyNs.clear();
    _copyEntryNs.clear();
    _phaseRejectNoted = NO;
    memset(_epochHist, 0, sizeof(_epochHist));
    _epochSamples = 0;
    _epochDuplicates = 0;
    _epochSizeChanges = 0;
    _epochScheduled = 0;
    _epochStaticHoldPhases = 0;
    _epochPresentedSynthetic = 0;
    _epochPresentedSource = 0;
    _epochPhysicalSource = 0; _epochPhysicalSynthetic = 0; _physicalHavePts = NO;
    _epochDeadline = 0;
    _epochQueueDrops = 0;
    [_presentationFailuresEpoch removeAllObjects];
    [_firstPresentationFailureEpoch removeAllObjects];
    _epochMonotonic = YES;
    _epochHavePts = NO;
    _epochWidth = 0;
    _epochHeight = 0;
    _claimedDrops.clear();
    _frcEwmaSec = 0.025;
    _scaleEwmaSec = 0.004;
    _measurementEpoch += 1;
    _presentationOrder.reset(_sourceGeneration, _configVersion, _measurementEpoch);
    _presentationGeometry.reset();
    [self recomputeInteractiveDelay];
}

- (double)informationLeadSeconds:(double)interval {
    if (!_request.interpolationEnabled || interval <= 0) return 0;
    if (_request.rateKind == SPLiveRateFixedFPS) return interval;
    int multiplier = (int)_request.multiplier;
    if (multiplier < 2) multiplier = 2;
    return interval * (double)(multiplier - 1) / (double)multiplier;
}

- (BOOL)noteUniqueSyntheticDrop:(sp::SPRational)pts {
    for (const auto &item : _claimedDrops) {
        if (sp::spCmp(item, pts) == 0) return NO;
    }
    _claimedDrops.push_back(pts);
    if (_claimedDrops.size() > 8192) _claimedDrops.erase(_claimedDrops.begin(), _claimedDrops.begin() + 2048);
    _deadlineDrops += 1;
    _epochDeadline += 1;
    return YES;
}

- (BOOL)noteClockRetiredSyntheticDrop:(sp::SPRational)pts {
    for (const auto &item : _claimedDrops) if (sp::spCmp(item, pts) == 0) return NO;
    _claimedDrops.push_back(pts);
    if (_claimedDrops.size() > 8192) _claimedDrops.erase(_claimedDrops.begin(), _claimedDrops.begin()+2048);
    _clockRetiredPhaseDrops += 1;
    return YES;
}

// Retire only work tied to the previous PTS-to-host mapping. In-flight
// model/SR work remains bounded and its callback is rejected by clockEpoch.
- (void)retireClockTimeline {
    ++_clockEpoch;
    _fpsMeter.resetOutput();
    _fpsObservationEpoch += 1;
    for (const auto &pending : _pending) [self noteClockRetiredSyntheticDrop:pending.pts];
    for (const auto &pending : _rifePending) [self noteClockRetiredSyntheticDrop:pending.pts];
    [self clearPendingRife];
    while (!_srPending.empty()) {
        SPSRJob *pending = _srPending.front(); _srPending.pop_front();
        _srPendingBytes = _srPendingBytes >= pending->bytes ? _srPendingBytes-pending->bytes : 0;
        if (pending->synthetic) [self noteClockRetiredSyntheticDrop:pending->pts];
        SPReleaseSRJob(pending);
    }
    for (const auto &slot : _slots) if (slot.synthetic) [self noteClockRetiredSyntheticDrop:slot.pts];
    _videoSRDiscontinuity = YES;
    _pending.clear();
    [self clearPlaySlots];
}

- (void)recomputeInteractiveDelay {
    double interval = 1.0 / 30.0;
    if (_haveInterval && _intervalHost > 0) {
        double seconds = (double)SPHostToNs(_intervalHost) / 1e9;
        if (seconds > 0.001) interval = seconds;
    }
    if (interval > 1.0 / 30.0) interval = 1.0 / 30.0;
    double lead = [self informationLeadSeconds:interval];
    double frc = _frcEwmaSec;
    if (_frcNs.size() >= 8) {
        std::vector<int64_t> recent = _frcNs;
        if (recent.size() > 32) recent.erase(recent.begin(), recent.end() - 32);
        std::sort(recent.begin(), recent.end());
        size_t index = (recent.size() - 1) * 80 / 100;
        frc = MAX(frc, (double)recent[index] / 1e9);
    }
    double process = frc + _scaleEwmaSec;
    if (process < 0.008) process = 0.008;
    double cap = _request.quality == SPFRCQualityHigh ? SPQualityCapSec : SPInteractiveCapSec;
    double wanted = lead + process + 0.016;
    if (_lowLatency && [self requestUsesLowPrescale:_request width:_width height:_height] && _captureToOutputReadyNs.size() >= 8) {
        // Include actual capture-to-ready time, which also covers pre-scaling,
        // conversion, asynchronous delivery and comparison baseline work.
        double observed = SPPercentileMs(_captureToOutputReadyNs) / 1000.0;
        if (observed > 0) wanted = MAX(wanted, lead + observed + 0.008);
    }
    if (wanted < lead + 0.012) wanted = lead + 0.012;
    BOOL clamped = wanted > cap;
    double delay = clamped ? cap : wanted;
    double fps = [self outputFramesPerSecond];
    if (fps < 1) fps = 1;
    NSUInteger byBytes = [self slotCapByBytes];
    double queueLimit = (double)(byBytes > 2 ? byBytes - 2 : 1) / fps;
    if (delay > queueLimit) {
        delay = queueLimit;
        clamped = YES;
    }
    if (delay > cap) {
        delay = cap;
        clamped = YES;
    }
    int64_t next = SPRationalToHost(sp::spMake((int64_t)llround(delay * 1000.0), 1000));
    if (_delayHost > next) {
        double current = (double)SPHostToNs(_delayHost) / 1e9;
        if (current > cap + 0.001) {
            [self retireClockTimeline];
            _haveAnchor = NO;
            _haveLastPts = NO;
        } else {
            int64_t maxDrop = (_haveInterval && _intervalHost > 0) ? _intervalHost / 2 : SPRationalToHost(sp::spMake(8, 1000));
            if (_delayHost - next > maxDrop) next = _delayHost - maxDrop;
        }
    }
    if (clamped && !_delayClampNoted && !_rife && ![self requestUsesLatestPresentation:_request]) {
        _delayClampNoted = YES;
        [self publishStatus:@"互动预算已用尽，赶不上的帧会计入覆盖率" failed:YES];
    } else if (!clamped && _delayClampNoted) {
        _delayClampNoted = NO;
        if (!_holdFailureStatus) {
            NSString *status = _resolved.interpolationActive ? @"增强运行" : (_resolved.scaleActive ? @"缩放运行" : @"预览原画面");
            [self publishStatus:status failed:NO];
        }
    } else if (!clamped) {
        _delayClampNoted = NO;
    }
    _delayClamped = clamped;
    _delayHost = next;
}

- (int64_t)targetHostForPTS:(sp::SPRational)pts {
    if (!_haveAnchor) return SPHostNow() + _delayHost;
    sp::SPRational delta{};
    if (!sp::spSub(pts, _anchorPts, delta)) return SPHostNow() + _delayHost;
    return _anchorHost + SPRationalToHost(delta) + _delayHost;
}

- (void)noteSourceClock:(sp::SPRational)pts host:(int64_t)host {
    if (host <= 0) host = SPHostNow();
    BOOL traceHadAnchor = _haveAnchor;
    BOOL traceErrorValid = _haveAnchor;
    BOOL traceReanchored = NO;
    int64_t traceError = 0;
    sp::SPRational traceOldAnchor = _anchorPts;
    if (_haveAnchor) {
        int64_t expected = [self targetHostForPTS:pts] - _delayHost;
        int64_t error = host - expected;
        traceError = error;
        if (error < 0) error = -error;
        if (SPHostToNs(error) > 150000000LL) {
            traceReanchored = YES;
            [self retireClockTimeline];
            _anchorPts = pts;
            _anchorHost = host;
            _haveLastPts = NO;
        }
    } else if (!_haveAnchor) {
        _anchorPts = pts;
        _anchorHost = host;
        _haveAnchor = YES;
    }
    if (_havePreviousSourcePts) {
        sp::SPRational delta{};
        if (sp::spSub(pts, _previousSourcePts, delta) && sp::spCmp(delta, sp::spMake(0, 1)) > 0) {
            int64_t interval = SPRationalToHost(delta);
            if (interval > 0) {
                _intervalHost = _haveInterval ? (_intervalHost * 3 + interval) / 4 : interval;
                _haveInterval = YES;
                [self recomputeInteractiveDelay];
                [self refreshResolvedOnQueue];
            }
        }
    }
    _previousSourcePts = pts;
    _havePreviousSourcePts = YES;
    if (_testCapturePlayout && _testTimingTrace.count < 80) {
        if (!_testTimingTrace) _testTimingTrace=[NSMutableArray array];
        [_testTimingTrace addObject:@{ @"kind":@"sourceClock", @"ptsNum":@(pts.num), @"ptsDen":@(pts.den),
            @"hadAnchor":@(traceHadAnchor), @"oldAnchorPtsNum":@(traceOldAnchor.num), @"oldAnchorPtsDen":@(traceOldAnchor.den),
            @"reanchored":@(traceReanchored), @"clockErrorValid":@(traceErrorValid), @"clockErrorMs":@((double)SPHostToNs(traceError)/1e6),
            @"anchorPtsNum":@(_anchorPts.num), @"anchorPtsDen":@(_anchorPts.den),
            @"anchorHostFromSourceMs":@((double)SPHostToNs(_anchorHost-host)/1e6), @"delayMs":@((double)SPHostToNs(_delayHost)/1e6) }];
    }
}

// Observe only actual source identity/PTS, not synthetic or hold output PTS.
// Scheduler output can mention an older source after the current input, so
// ignore duplicate and backwards observations rather than updating EWMA twice.
- (void)observeSourceIdentity:(uint64_t)identity {
    auto found = _held.find(identity);
    if (found == _held.end()) return;
    const auto pts = found->second.pts;
    if (_havePreviousSourcePts && sp::spCmp(pts, _previousSourcePts) <= 0) return;
    [self noteSourceClock:pts host:found->second.host];
}

- (void)erasePending:(sp::SPRational)pts {
    _pending.erase(std::remove_if(_pending.begin(), _pending.end(), [&](const SPPendingPhase &item) {
        return sp::spCmp(item.pts, pts) == 0;
    }), _pending.end());
}

- (BOOL)waitForPendingBefore:(sp::SPRational)pts now:(int64_t)now earliest:(int64_t *)earliest {
    BOOL wait = NO;
    for (auto it = _pending.begin(); it != _pending.end();) {
        if (it->generation != _sourceGeneration || sp::spCmp(it->pts, pts) >= 0) {
            ++it;
            continue;
        }
        if ([self requestUsesLatestPresentation:_request]) {
            [self noteUniqueSyntheticDrop:it->pts];
            it = _pending.erase(it);
            continue;
        }
        if (it->targetHost > now) {
            if (!wait || it->targetHost < *earliest) *earliest = it->targetHost;
            wait = YES;
            ++it;
            continue;
        }
        if (_testCapturePlayout && _testPendingTrace.count < 24) {
            if (!_testPendingTrace) _testPendingTrace=[NSMutableArray array];
            [_testPendingTrace addObject:@{ @"kind":@"expired", @"ptsNum":@(it->pts.num), @"ptsDen":@(it->pts.den),
                @"lateMs":@((double)SPHostToNs(now-it->targetHost)/1e6), @"delayMs":@((double)SPHostToNs(_delayHost)/1e6) }];
        }
        if ([self noteUniqueSyntheticDrop:it->pts]) _pendingExpiredDrops++;
        it = _pending.erase(it);
    }
    return wait;
}

- (CVPixelBufferRef)scaleBuffer:(CVPixelBufferRef)bgra with:(SPSpatialScaler *)scaler {
    if (!bgra) return NULL;
    if (!scaler) {
        CVPixelBufferRetain(bgra);
        return bgra;
    }
    int64_t started = SPHostNow();
    CVPixelBufferRef scaled = [scaler scaleBuffer:bgra error:NULL];
    int64_t ns = SPHostToNs(SPHostNow() - started);
    SPPushSample(_scaleNs, ns);
    double seconds = (double)ns / 1e9;
    _scaleEwmaSec = _scaleEwmaSec <= 0 ? seconds : (0.8 * _scaleEwmaSec + 0.2 * seconds);
    return scaled;
}

- (void)showPair:(CVPixelBufferRef)enhanced
        original:(CVPixelBufferRef)original
             pts:(sp::SPRational)pts
       synthetic:(BOOL)synthetic
     captureHost:(int64_t)captureHost
         frameID:(uint64_t)frameID
          redraw:(BOOL)redraw {
    [self.preview setDiagnosticsConfig:_configVersion epoch:_measurementEpoch];
    [self.outputPreview setDiagnosticsConfig:_configVersion epoch:_measurementEpoch];
    BOOL outputVisible = self.outputPreview.windowVisibleSnapshot;
    if (_scoreOutput != outputVisible) { _fpsMeter.resetOutput(); _fpsObservationEpoch += 1; _presentationGeometry.reset(); }
    _scoreOutput = outputVisible;
    uint64_t generation = _sourceGeneration;
    BOOL previewCounts = redraw ? NO : !outputVisible;
    BOOL outputCounts = redraw ? NO : outputVisible;
    if (self.preview) {
        NSString *reason = nil;
        BOOL accepted = [self.preview presentEnhanced:enhanced original:original mode:_request.viewMode
                                          captureHost:captureHost generation:generation
                                               ptsNum:pts.num ptsDen:pts.den synthetic:synthetic
                                              frameID:frameID counts:previewCounts reason:&reason];
        if (!accepted && previewCounts) { _renderDrops += 1; [self recordPresentationFailure:reason endpoint:@"preview" generation:generation config:_configVersion epoch:_measurementEpoch frame:frameID]; }
    }
    if (self.outputPreview) {
        NSString *reason = nil;
        BOOL accepted = [self.outputPreview presentEnhanced:enhanced original:original mode:_request.viewMode
                                                captureHost:captureHost generation:generation
                                                     ptsNum:pts.num ptsDen:pts.den synthetic:synthetic
                                                    frameID:frameID counts:outputCounts reason:&reason];
        if (!accepted && outputCounts) { _renderDrops += 1; [self recordPresentationFailure:reason endpoint:@"output" generation:generation config:_configVersion epoch:_measurementEpoch frame:frameID]; }
    }
}

- (void)drainDue {
    int64_t now = SPHostNow();
    int64_t slop = SPRationalToHost(sp::spMake(1, 1000));
    while (!_slots.empty()) {
        int64_t earliest = 0;
        if ([self waitForPendingBefore:_slots.front().pts now:now earliest:&earliest]) {
            [self armClockAt:earliest];
            return;
        }
        if (_slots.front().targetHost > now + slop) {
            [self armClockAt:_slots.front().targetHost];
            return;
        }
        while (_slots.size() > 1 && _slots[1].targetHost <= now + slop) {
            if (_slots.front().synthetic && [self noteUniqueSyntheticDrop:_slots.front().pts]) _dueMergeDrops++;
            [self erasePending:_slots.front().pts];
            _marks.erase(_slots.front().frameID);
            SPReleaseSlot(_slots.front());
            _slots.erase(_slots.begin());
        }
        if (_slots.empty()) break;
        if (_slots.front().targetHost > now + slop) {
            [self armClockAt:_slots.front().targetHost];
            return;
        }
        SPPlaySlot slot = _slots.front();
        _slots.erase(_slots.begin());
        if (slot.sourceGeneration != _sourceGeneration || slot.configVersion != _configVersion) {
            _marks.erase(slot.frameID);
            SPReleaseSlot(slot);
            continue;
        }
        if (_haveLastPts && sp::spCmp(slot.pts, _lastPresentedPts) <= 0) {
            if (slot.synthetic) [self noteUniqueSyntheticDrop:slot.pts];
            _marks.erase(slot.frameID);
            SPReleaseSlot(slot);
            continue;
        }
        [self showPair:slot.enhanced original:slot.original pts:slot.pts synthetic:slot.synthetic
           captureHost:slot.captureHost frameID:slot.frameID redraw:NO];
        if (_testCapturePlayout) _testPlayout.emplace_back(slot.pts, slot.synthetic);
        [self rememberPair:slot.enhanced original:slot.original pts:slot.pts synthetic:slot.synthetic];
        _lastPresentedPts = slot.pts;
        _haveLastPts = YES;
        SPReleaseSlot(slot);
        if (_slots.empty()) {
            [self armClockAt:now + SPRationalToHost(sp::spMake(1, 10))];
            return;
        }
        [self armClockAt:_slots.front().targetHost];
        return;
    }
    [self armClockAt:now + SPRationalToHost(sp::spMake(1, 10))];
}

- (void)enqueueReadyEnhanced:(CVPixelBufferRef)enhanced
                    original:(CVPixelBufferRef)original
                         pts:(sp::SPRational)pts
                   synthetic:(BOOL)synthetic
                         held:(BOOL)held
                 captureHost:(int64_t)captureHost
                  generation:(uint64_t)generation
              deadlineHost:(int64_t)deadlineHost {
    if (!enhanced || generation != _sourceGeneration) {
        if (enhanced) CVPixelBufferRelease(enhanced);
        if (original) CVPixelBufferRelease(original);
        return;
    }
    if (synthetic && captureHost > 0 && SPHostNow() > captureHost)
        SPPushSample(_captureToOutputReadyNs, SPHostToNs(SPHostNow() - captureHost));
    if (synthetic && _lowLatency && [self requestUsesLowPrescale:_request width:_width height:_height]) {
        [self recomputeInteractiveDelay];
        if (!_testKeepLowRealtime && _delayClamped) _lowPrescaleSlowMode = YES;
    }
    if (_haveLastPts && sp::spCmp(pts, _lastPresentedPts) <= 0) {
        if (synthetic && [self noteUniqueSyntheticDrop:pts]) _staleReadyDrops++;
        [self erasePending:pts];
        CVPixelBufferRelease(enhanced);
        if (original) CVPixelBufferRelease(original);
        return;
    }
    SPPlaySlot slot;
    slot.pts = pts;
    slot.targetHost = [self requestUsesLatestPresentation:_request] ? SPHostNow() : (deadlineHost > 0 ? deadlineHost : [self targetHostForPTS:pts]);
    slot.synthetic = synthetic;
    slot.enhanced = enhanced;
    slot.original = original ?: CVPixelBufferRetain(enhanced);
    slot.frameID = ++_nextFrameID;
    slot.readyHost = SPHostNow();
    slot.sourceGeneration = generation;
    slot.configVersion = _configVersion;
    slot.captureHost = captureHost;
    [self erasePending:pts];
    if (synthetic && ![self requestUsesLatestPresentation:_request] && slot.targetHost + SPRationalToHost(sp::spMake(2, 1000)) < slot.readyHost) {
        if ([self noteUniqueSyntheticDrop:pts]) _lateReadyDrops++;
        SPReleaseSlot(slot);
        return;
    }
    if (_probeWindowOpen && _centerSamples < 8 && enhanced && original) {
        int64_t sampleStart = SPHostNow();
        slot.enhancedCenter = SPWhiteCenterX(enhanced);
        slot.originalCenter = SPWhiteCenterX(original);
        slot.hasCenter = slot.enhancedCenter >= 0 || slot.originalCenter >= 0;
        _centerSampleNs += (uint64_t)SPHostToNs(SPHostNow() - sampleStart);
        _centerSamples += 1;
    }
    auto at = std::lower_bound(_slots.begin(), _slots.end(), slot, [](const SPPlaySlot &a, const SPPlaySlot &b) {
        return sp::spCmp(a.pts, b.pts) < 0;
    });
    _slots.insert(at, slot);
    SPFrameMark mark;
    mark.readyHost = slot.readyHost;
    mark.targetHost = slot.targetHost;
    mark.hasCenter = slot.hasCenter;
    mark.enhancedCenter = slot.enhancedCenter;
    mark.originalCenter = slot.originalCenter;
    mark.held = held;
    mark.fpsEpoch = _fpsObservationEpoch;
    _marks[slot.frameID] = mark;
    if (_slots.size() > _peakSlots) _peakSlots = _slots.size();
    NSUInteger cap = [self slotCap];
    while (_slots.size() > cap) {
        auto victim = std::find_if(_slots.begin(), _slots.end(), [](const SPPlaySlot &item) { return item.synthetic; });
        if (victim == _slots.end()) victim = _slots.begin();
        if (victim->synthetic && [self noteUniqueSyntheticDrop:victim->pts]) _slotEvictionDrops++;
        _marks.erase(victim->frameID);
        SPReleaseSlot(*victim);
        _slots.erase(victim);
    }
    [self ensureClock];
    [self drainDue];
}

- (CVPixelBufferRef)bgraFromSource:(CVPixelBufferRef)source {
    return [self transfer:source format:kCVPixelFormatType_32BGRA];
}

// Owns both buffers on entry. One active request plus at most two waiting
// requests share a conservative byte budget; no wait occurs on the live queue.
- (void)enqueueAsyncScale:(CVPixelBufferRef)input original:(CVPixelBufferRef)original
                     pts:(sp::SPRational)pts synthetic:(BOOL)synthetic held:(BOOL)held
             captureHost:(int64_t)captureHost generation:(uint64_t)generation deadlineHost:(int64_t)deadlineHost {
    if (!input || (!_appleSR && !_videoSR && !_animeSR && !_cuganSR) || _srFailed) {
        if (input) CVPixelBufferRelease(input); if (original) CVPixelBufferRelease(original);
        if (synthetic) { [self erasePending:pts]; [self noteUniqueSyntheticDrop:pts]; }
        return;
    }
    uint64_t inputBytes = (uint64_t)CVPixelBufferGetBytesPerRow(input) * CVPixelBufferGetHeight(input);
    uint64_t originalBytes = original ? (uint64_t)CVPixelBufferGetBytesPerRow(original) * CVPixelBufferGetHeight(original) : 0;
    // Temporal video SR retains the previous RGBA-half output, plus the new
    // RGBA-half output and converted BGRA. Include all three in the budget.
    uint64_t outputBudget = (uint64_t)MAX(_resolved.outputWidth, 1) * (uint64_t)MAX(_resolved.outputHeight, 1) * (_videoSR ? 20 : (_cuganSR ? 16 : 8));
    uint64_t cost = inputBytes + originalBytes + outputBudget;
    if ([self requestUsesLatestScale:_request] && ((_srBusy && sp::spCmp(pts,_srActivePTS)<=0) ||
        (!_srPending.empty() && sp::spCmp(pts,_srPending.front()->pts)<=0))) {
        CVPixelBufferRelease(input);if(original)CVPixelBufferRelease(original);
        if(synthetic){[self erasePending:pts];[self noteUniqueSyntheticDrop:pts];}
        _queueDrops+=1;_epochQueueDrops+=1;return;
    }
    if ([self requestUsesLatestScale:_request] && !_srPending.empty()) {
        SPSRJob *replaced = _srPending.front(); _srPending.pop_front();
        _srPendingBytes = _srPendingBytes >= replaced->bytes ? _srPendingBytes - replaced->bytes : 0;
        if (replaced->synthetic) { [self erasePending:replaced->pts]; [self noteUniqueSyntheticDrop:replaced->pts]; }
        SPReleaseSRJob(replaced);
        _queueDrops += 1; _epochQueueDrops += 1;
    }
    if (_srPending.size() >= 2 || cost > SPQueueByteBudget || _srPendingBytes > SPQueueByteBudget - cost) {
        CVPixelBufferRelease(input); if (original) CVPixelBufferRelease(original);
        if (synthetic) { [self erasePending:pts]; [self noteUniqueSyntheticDrop:pts]; }
        if (_videoSR) _videoSRDiscontinuity = YES;
        _queueDrops += 1; _epochQueueDrops += 1;
        return;
    }
    SPSRJob *job = new SPSRJob();
    job->input = input; job->original = original; job->pts = pts; job->synthetic = synthetic;
    job->held = held;
    job->captureHost = captureHost; job->targetHost = deadlineHost; job->clockEpoch = _clockEpoch;
    job->sourceGeneration = generation; job->configVersion = _configVersion;
    job->sequence = _srSequence; job->bytes = cost;
    job->discontinuity = _videoSR && _videoSRDiscontinuity;
    if (_videoSR) _videoSRDiscontinuity = NO;
    _srPendingBytes += cost;
    _srPending.push_back(job);
    [self drainAsyncScaleOnQueue];
}

- (void)drainAsyncScaleOnQueue {
    if (_srBusy || _srFailed || _srPending.empty() || (!_appleSR && !_videoSR && !_animeSR && !_cuganSR)) return;
    SPSRJob *job = _srPending.front();
    _srPending.pop_front();
    _srBusy = YES;
    _srActivePTS = job->pts;
    CMTime pts = job->pts.den > 0 && job->pts.den <= INT32_MAX
        ? CMTimeMake(job->pts.num, (int32_t)job->pts.den) : kCMTimeInvalid;
    SPLiveProcessor *strong = self;
    SPFRCEngineCompletion completion = ^(uint64_t token, CVPixelBufferRef output, double latency, NSError *error) {
            (void)token;
            dispatch_async(strong->_q, ^{
                if (job->sequence != strong->_srSequence || job->sourceGeneration != strong->_sourceGeneration ||
                    job->configVersion != strong->_configVersion || strong->_stopped) {
                    if (output) CVPixelBufferRelease(output);
                    SPReleaseSRJob(job);
                    return;
                }
                strong->_srBusy = NO;
                strong->_srPendingBytes = strong->_srPendingBytes >= job->bytes ? strong->_srPendingBytes - job->bytes : 0;
                if (job->clockEpoch != strong->_clockEpoch) {
                    if (job->synthetic) [strong noteClockRetiredSyntheticDrop:job->pts];
                    if (output) CVPixelBufferRelease(output);
                    SPReleaseSRJob(job); [strong drainAsyncScaleOnQueue]; return;
                }
                if (latency > 0) {
                    SPPushSample(strong->_scaleNs, (int64_t)(latency * 1e9));
                    strong->_scaleEwmaSec = strong->_scaleEwmaSec <= 0 ? latency : (0.8 * strong->_scaleEwmaSec + 0.2 * latency);
                    [strong recomputeInteractiveDelay];
                }
                if (job->clockEpoch != strong->_clockEpoch) {
                    if (job->synthetic) [strong noteClockRetiredSyntheticDrop:job->pts];
                    if (output) CVPixelBufferRelease(output);
                    SPReleaseSRJob(job); [strong drainAsyncScaleOnQueue]; return;
                }
                CVPixelBufferRef bgra = output ? [strong transfer:output format:kCVPixelFormatType_32BGRA] : NULL;
                if (output) CVPixelBufferRelease(output);
                if (error || !bgra) {
                    if (bgra) CVPixelBufferRelease(bgra);
                    if (job->synthetic) { [strong erasePending:job->pts]; [strong noteUniqueSyntheticDrop:job->pts]; }
                    [strong failAsyncScaleOnQueue:error.localizedDescription ?: @"超分处理失败。"];
                } else {
                    CVPixelBufferRef original = job->original;
                    job->original = nullptr;
                    [strong enqueueReadyEnhanced:bgra original:original pts:job->pts synthetic:job->synthetic held:job->held
                                      captureHost:job->captureHost generation:job->sourceGeneration deadlineHost:job->targetHost];
                }
                SPReleaseSRJob(job);
                [strong drainAsyncScaleOnQueue];
            });
        };
    BOOL accepted = _cuganSR
        ? [_cuganSR submitSource:job->input pts:pts token:job->sequence completion:completion]
        : _animeSR
        ? [_animeSR submitSource:job->input pts:pts token:job->sequence completion:completion]
        : _videoSR
        ? [_videoSR submitSource:job->input pts:pts discontinuity:job->discontinuity token:job->sequence completion:completion]
        : [_appleSR submitSource:job->input pts:pts token:job->sequence completion:completion];
    if (!accepted) {
        _srBusy = NO;
        _srPendingBytes = _srPendingBytes >= job->bytes ? _srPendingBytes - job->bytes : 0;
        if (job->synthetic) { [self erasePending:job->pts]; [self noteUniqueSyntheticDrop:job->pts]; }
        [self failAsyncScaleOnQueue:@"超分不能处理当前来源格式或时间戳。"];
        SPReleaseSRJob(job);
    }
}

- (void)failAsyncScaleOnQueue:(NSString *)reason {
    _srFailed = YES;
    _holdFailureStatus = YES;
    _resolved.scaleActive = NO;
    _resolved.unavailableReason = reason;
    while (!_srPending.empty()) {
        SPSRJob *pending = _srPending.front(); _srPending.pop_front();
        if (pending->synthetic) { [self erasePending:pending->pts]; [self noteUniqueSyntheticDrop:pending->pts]; }
        SPReleaseSRJob(pending);
    }
    _srPendingBytes = 0;
    [self publishStatus:reason failed:YES];
}

- (void)enqueueSourceIdentity:(uint64_t)identity
                          pts:(sp::SPRational)pts
                         host:(int64_t)host
                   generation:(uint64_t)generation
                        force:(BOOL)force {
    auto found = _held.find(identity);
    if (found == _held.end()) return;
    BOOL held = sp::spCmp(pts, found->second.pts) != 0;
    if (_videoSR && _havePreviousSourcePts) {
        sp::SPRational delta{};
        if (!sp::spSub(pts, _previousSourcePts, delta) || sp::spCmp(delta, sp::spMake(0,1)) <= 0 ||
            (_haveInterval && SPRationalToHost(delta) > MAX(_intervalHost * 3, SPRationalToHost(sp::spMake(1,10))))) {
            _videoSRDiscontinuity = YES;
        }
    }
    if (!held) [self observeSourceIdentity:identity];
    // Keep the last result visible while the slow model works. Otherwise
    // newer source frames would make every completed midpoint stale.
    if (!force && (_distil || (_rife && _rifeSlowMode) || (_lowLatency && _lowPrescaleSlowMode)) && _resolved.interpolationActive && _sessionReady && _lastEnhanced && _request.viewMode != SPLiveViewOriginal) return;
    if (_sessionReady && _lowLatency && [self requestUsesLowPrescale:_request width:_width height:_height]) {
        CVPixelBufferRef cached=[self lowPrescaledForIdentity:identity];
        if (!cached) { [self publishStatus:@"低延迟前置缩放失败" failed:YES]; return; }
        CVPixelBufferRef enhanced=CVPixelBufferRetain(cached);
        CVPixelBufferRef original=_request.viewMode==SPLiveViewCompare ? CVPixelBufferRetain(cached) : NULL;
        [self enqueueReadyEnhanced:enhanced original:original pts:pts synthetic:NO held:held captureHost:host generation:generation deadlineHost:0];
        return;
    }
    CVPixelBufferRef bgra = [self bgraFromSource:found->second.source];
    if (!bgra) return;
    if ([self requestUsesAsyncScale:_request] && _sessionReady && (_appleSR || _videoSR || _animeSR || _cuganSR)) {
        CVPixelBufferRef original = _request.viewMode == SPLiveViewCompare ? [self scaleBuffer:bgra with:_baselineScaler] : NULL;
        [self enqueueAsyncScale:bgra original:original pts:pts synthetic:NO held:held captureHost:host generation:generation deadlineHost:0];
        return;
    }
    CVPixelBufferRef enhanced = [self scaleBuffer:bgra with:_request.scaleEnabled ? _scaler : nil];
    CVPixelBufferRef original = nil;
    if (_request.viewMode == SPLiveViewCompare) {
        original = [self scaleBuffer:bgra with:_request.scaleEnabled ? _baselineScaler : nil];
    }
    CVPixelBufferRelease(bgra);
    if (!enhanced) enhanced = original ? CVPixelBufferRetain(original) : NULL;
    if (!original && enhanced) original = CVPixelBufferRetain(enhanced);
    [self enqueueReadyEnhanced:enhanced original:original pts:pts synthetic:NO held:held captureHost:host generation:generation deadlineHost:0];
}

- (void)submitEventGroup:(const std::vector<sp::SPScheduleOutput> &)events generation:(uint64_t)generation {
    // A phase depends on frame B; observe its real source clock before its
    // deadline is calculated, including callers which submit a pair directly.
    if (!events.empty() && generation == _sourceGeneration) [self observeSourceIdentity:events.front().frameB];
    if (_testCapturePlayout && !events.empty() && _testTimingTrace.count < 80) {
        auto b = _held.find(events.front().frameB);
        if (b != _held.end()) {
            if (!_testTimingTrace) _testTimingTrace=[NSMutableArray array];
            [_testTimingTrace addObject:@{ @"kind":@"phasePlan", @"ptsNum":@(events.front().pts.num), @"ptsDen":@(events.front().pts.den),
                @"sourcePtsNum":@(b->second.pts.num), @"sourcePtsDen":@(b->second.pts.den),
                @"anchorPtsNum":@(_anchorPts.num), @"anchorPtsDen":@(_anchorPts.den), @"anchorValid":@(_haveAnchor),
                @"deadlineFromSourceMs":@((double)SPHostToNs([self targetHostForPTS:events.front().pts]-b->second.host)/1e6),
                @"delayMs":@((double)SPHostToNs(_delayHost)/1e6) }];
        }
    }
    BOOL wantLow = [_request.engineID isEqualToString:@"apple.lowlatency"];
    BOOL wantRife = [_request.engineID isEqualToString:@"rife.metal"];
    BOOL wantDistil = [_request.engineID isEqualToString:@"distildrba.coreml"];
    BOOL haveEngine = wantLow ? (_lowLatency != nil) : (wantRife ? (_rife != nil) : (wantDistil ? (_distil != nil) : (_engine != nil)));
    BOOL slowPair=(wantRife && _rifeSlowMode) || (wantLow && _lowPrescaleSlowMode);
    if (!events.empty() && slowPair && _inflight >= 1 && haveEngine) {
        auto a = _held.find(events.front().frameA), b = _held.find(events.front().frameB);
        if (a != _held.end() && b != _held.end()) {
            if (!_rifePending.empty()) { _queueDrops += _rifePending.size(); _epochQueueDrops += _rifePending.size(); }
            [self clearPendingRife];
            _rifePending = events;
            _rifePendingGeneration = generation;
            a->second.pins += 1; b->second.pins += 1;
            return;
        }
    }
    if (events.empty() || _inflight >= ((wantDistil || slowPair) ? 1 : 2) || !haveEngine) {
        if (!events.empty()) {
            _queueDrops += events.size();
            _epochQueueDrops += events.size();
            if (!haveEngine) _engineUnavailableDrops += events.size();
            else _inflightLimitDrops += events.size();
        }
        return;
    }
    NSMutableArray<NSNumber *> *phases = [NSMutableArray array];
    for (const auto &event : events) {
        float value = 0;
        if (wantLow) {
            if (![SPLowLatencyEngine supportsPhaseNumerator:event.phase.num denominator:event.phase.den frames:_lowLatency.frames outFloat:&value]) {
                if (!_phaseRejectNoted) {
                    _phaseRejectNoted = YES;
                    NSString *text = [NSString stringWithFormat:@"相位 %lld/%lld 不在低延迟支持的 1/2 或 1/4、1/2、3/4 里，请求没有被改写。可改用 Apple 帧率转换。",
                                      event.phase.num, event.phase.den];
                    _resolved.unavailableReason = text;
                    _holdFailureStatus = YES;
                    [self publishStatus:text failed:YES];
                }
                _queueDrops += events.size();
                _epochQueueDrops += events.size();
                return;
            }
        } else if (!sp::spPhaseFitsFloat(event.phase, value)) {
            _syntheticFail += 1;
            _resolved.unavailableReason = @"相位无法精确提交";
            [self publishStatus:wantRife ? @"该相位无法交给 RIFE" : @"该相位无法交给 Apple 帧率转换" failed:YES];
            return;
        }
        [phases addObject:@(value)];
    }
    CVPixelBufferRef a = NULL;
    CVPixelBufferRef b = NULL;
    if (wantLow || wantRife || wantDistil) {
        auto heldA = _held.find(events.front().frameA);
        auto heldB = _held.find(events.front().frameB);
        a = heldA == _held.end() ? NULL : heldA->second.source;
        b = heldB == _held.end() ? NULL : heldB->second.source;
    } else {
        a = [self yuvForIdentity:events.front().frameA];
        b = [self yuvForIdentity:events.front().frameB];
    }
    if (!a || !b) {
        _syntheticFail += 1;
        return;
    }
    if (wantLow && SPIdenticalSourcePixels(a,b)) {
        CVPixelBufferRef image=NULL;
        if ([self requestUsesLowPrescale:_request width:_width height:_height]) {
            CVPixelBufferRef cached=[self lowPrescaledForIdentity:events.front().frameA];
            if(cached) image=CVPixelBufferRetain(cached);
        } else {
            CVPixelBufferRef source=[self bgraFromSource:a];
            image=source ? [self scaleBuffer:source with:_request.scaleEnabled ? _scaler : nil] : NULL;
            if(source)CVPixelBufferRelease(source);
        }
        if (!image) { _syntheticFail += events.size(); [self publishStatus:@"静止帧处理失败" failed:YES]; return; }
        auto heldB=_held.find(events.front().frameB); int64_t host=heldB==_held.end()?0:heldB->second.host;
        for(const auto &event:events) {
            _staticHoldPhases++; _epochStaticHoldPhases++;
            [self enqueueReadyEnhanced:CVPixelBufferRetain(image) original:CVPixelBufferRetain(image) pts:event.pts synthetic:NO held:YES captureHost:host generation:generation deadlineHost:0];
        }
        CVPixelBufferRelease(image); return;
    }
    if (wantLow && [self requestUsesLowPrescale:_request width:_width height:_height]) {
        a=[self lowPrescaledForIdentity:events.front().frameA];
        b=[self lowPrescaledForIdentity:events.front().frameB];
        if (!a || !b) { _syntheticFail += 1; [self publishStatus:@"低延迟前置缩放失败" failed:YES]; return; }
    }
    // Sessions are pooled and pairs may land on different sessions, so do not
    // claim sequential submission even though the timestamps are now real.
    BOOL sequential = NO;
    SPLiveJob *job = new SPLiveJob();
    job->configVersion = _configVersion;
    job->generation = generation;
    job->clockEpoch = _clockEpoch;
    auto hostB = _held.find(events.front().frameB);
    job->captureHost = hostB == _held.end() ? 0 : hostB->second.host;
    job->count = (int)MIN((size_t)3, events.size());
    for (int i = 0; i < job->count; ++i) {
        job->pts[i] = events[(size_t)i].pts;
        job->targetHost[i] = [self targetHostForPTS:job->pts[i]];
    }
    job->frameA = events.front().frameA;
    job->frameB = events.front().frameB;
    job->inflightEpoch = _inflightEpoch;
    if (auto aHeld = _held.find(job->frameA); aHeld != _held.end()) aHeld->second.pins += 1;
    if (auto bHeld = _held.find(job->frameB); bHeld != _held.end()) bHeld->second.pins += 1;
    uint64_t token = (uint64_t)(uintptr_t)job;
    _inflight += 1;
    _havePair = YES;
    _lastPairB = events.front().frameB;
    SPLiveProcessor *selfRef = self;
    SPFRCPhasesCompletion finish = ^(uint64_t doneToken, NSArray<SPOwnedPixelBuffer *> *outputs, double latency, NSError *error) {
        NSMutableArray<SPOwnedPixelBuffer *> *kept = [NSMutableArray array];
        for (SPOwnedPixelBuffer *box in outputs) {
            CVPixelBufferRetain(box.buffer);
            [kept addObject:[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:box.buffer]];
        }
        dispatch_async(selfRef->_q, ^{
            [selfRef finishJob:job token:doneToken outputs:kept latency:latency error:error];
        });
    };
    BOOL submitted = NO;
    if (wantLow) {
        auto heldA = _held.find(job->frameA), heldB = _held.find(job->frameB);
        if (heldA != _held.end() && heldB != _held.end()) {
            const auto pa = heldA->second.pts, pb = heldB->second.pts;
            if (pa.den > 0 && pa.den <= INT32_MAX && pb.den > 0 && pb.den <= INT32_MAX) {
                submitted = [_lowLatency submitPrevious:a current:b
                    previousPTS:CMTimeMake(pa.num, (int32_t)pa.den) currentPTS:CMTimeMake(pb.num, (int32_t)pb.den)
                    phases:phases token:token completion:finish];
            }
        }
    }
    else if (wantRife) submitted = [_rife submitPrevious:a current:b timesteps:phases token:token completion:finish];
    else if (wantDistil) {
        auto heldA = _held.find(job->frameA);
        auto previous = heldA == _held.end() ? _held.end() : _held.find(heldA->second.previousIdentity);
        const auto midpoint = job->pts[0];
        if (previous != _held.end() && job->count == 1 && midpoint.den > 0 && midpoint.den <= INT32_MAX) {
            submitted = [_distil submitPrevious:previous->second.source current:a next:b
                pts:CMTimeMake(midpoint.num, (int32_t)midpoint.den) token:token
                completion:^(uint64_t doneToken, CVPixelBufferRef output, double latency, NSError *error) {
                    NSArray *boxes = output ? @[[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:output]] : @[];
                    finish(doneToken, boxes, latency, error);
                }];
        }
    }
    else {
        auto heldA = _held.find(job->frameA), heldB = _held.find(job->frameB);
        if (heldA != _held.end() && heldB != _held.end()) {
            const auto pa = heldA->second.pts, pb = heldB->second.pts;
            if (pa.den > 0 && pa.den <= INT32_MAX && pb.den > 0 && pb.den <= INT32_MAX) {
                submitted = [_engine submitPhasesWithFrameA:a frameB:b
                    ptsA:CMTimeMake(pa.num, (int32_t)pa.den) ptsB:CMTimeMake(pb.num, (int32_t)pb.den)
                    phases:phases sequential:sequential token:token completion:finish];
            }
        }
    }
    if (!submitted) {
        if (job->inflightEpoch == _inflightEpoch) _inflight = MAX(0, _inflight - 1);
        [self unpinJob:job];
        _queueDrops += (uint64_t)MAX(1, job->count);
        _epochQueueDrops += (uint64_t)MAX(1, job->count);
        _engineSubmissionRejectedDrops += (uint64_t)MAX(1, job->count);
        delete job;
    } else {
        _submitted += 1;
        for (int phaseIndex = 0; phaseIndex < job->count; ++phaseIndex) {
            const auto &event = events[(size_t)phaseIndex];
            SPPendingPhase phase;
            phase.pts = event.pts;
            phase.targetHost = job->targetHost[phaseIndex];
            phase.generation = generation;
            if (_testCapturePlayout && _testPendingTrace.count < 24) {
                if (!_testPendingTrace) _testPendingTrace=[NSMutableArray array];
                [_testPendingTrace addObject:@{ @"kind":@"submitted", @"ptsNum":@(event.pts.num), @"ptsDen":@(event.pts.den),
                    @"deadlineFromSourceMs":@((double)SPHostToNs(phase.targetHost-job->captureHost)/1e6),
                    @"enqueueFromSourceMs":@((double)SPHostToNs(SPHostNow()-job->captureHost)/1e6),
                    @"anchorValid":@(_haveAnchor), @"anchorPtsNum":@(_anchorPts.num), @"anchorPtsDen":@(_anchorPts.den),
                    @"anchorHostFromSourceMs":@((double)SPHostToNs(_anchorHost-job->captureHost)/1e6),
                    @"frameBptsNum":@(hostB == _held.end() ? 0 : hostB->second.pts.num),
                    @"frameBptsDen":@(hostB == _held.end() ? 0 : hostB->second.pts.den),
                    @"delayMs":@((double)SPHostToNs(_delayHost)/1e6) }];
            }
            _pending.push_back(phase);
        }
    }
}

- (void)unpinJob:(SPLiveJob *)job {
    for (uint64_t identity : {job->frameA, job->frameB}) {
        auto found = _held.find(identity);
        if (found != _held.end() && found->second.pins > 0) found->second.pins -= 1;
    }
}

- (void)finishJob:(SPLiveJob *)job
            token:(uint64_t)token
          outputs:(NSArray<SPOwnedPixelBuffer *> *)outputs
          latency:(double)latency
            error:(NSError *)error {
    (void)token;
    if (job->inflightEpoch == _inflightEpoch) _inflight = MAX(0, _inflight - 1);
    [self unpinJob:job];
    if (job->configVersion != _configVersion || job->generation != _sourceGeneration || _stopped) {
        delete job;
        return;
    }
    if (job->clockEpoch != _clockEpoch) {
        _clockRetiredJobs += 1; _clockRetiredModelOutputs += outputs.count;
        delete job;
        return;
    }
    if (job->captureHost > 0 && SPHostNow() > job->captureHost)
        SPPushSample(_captureToModelReadyNs, SPHostToNs(SPHostNow() - job->captureHost));
    if (latency > 0) {
        SPPushSample(_frcNs, (int64_t)(latency * 1e9));
        _frcEwmaSec = _frcEwmaSec <= 0 ? latency : (0.5 * _frcEwmaSec + 0.5 * latency);
        [self recomputeInteractiveDelay];
        if (_rife && _delayClamped) _rifeSlowMode = YES;
        if (!_testKeepLowRealtime && _lowLatency && _delayClamped && [self requestUsesLowPrescale:_request width:_width height:_height]) _lowPrescaleSlowMode = YES;
    }
    // Delay recomputation can itself retire the clock mapping.
    if (job->clockEpoch != _clockEpoch) {
        _clockRetiredJobs += 1; _clockRetiredModelOutputs += outputs.count;
        delete job; return;
    }
    if (_probeWindowOpen && job->count > 0) {
        BOOL measured = NO;
        for (int i = 0; i < job->count; ++i) {
            if (sp::spCmp(job->pts[i], _probeMinPts) >= 0) measured = YES;
        }
        if (!measured) {
            for (int i = 0; i < job->count; ++i) [self erasePending:job->pts[i]];
            delete job;
            return;
        }
    }
    if (error || outputs.count == 0) {
        [self clearPendingRife];
        for (int i = 0; i < job->count; ++i) [self erasePending:job->pts[i]];
        _syntheticFail += (uint64_t)MAX((NSUInteger)1, outputs.count);
        _resolved.interpolationActive = NO;
        _resolved.unavailableReason = error.localizedDescription ?: @"插帧失败";
        [self publishStatus:_resolved.unavailableReason failed:YES];
        delete job;
        return;
    }
    BOOL recovered = _resolved.unavailableReason.length > 0;
    _resolved.interpolationActive = YES;
    if (!_srFailed) _resolved.unavailableReason = @"";
    if (recovered && !_holdFailureStatus && !_srFailed) [self publishStatus:@"增强运行" failed:NO];
    _syntheticOK += outputs.count;
    NSUInteger index = 0;
    for (SPOwnedPixelBuffer *box in outputs) {
        const NSUInteger phaseIndex = MIN(index, (NSUInteger)2);
        sp::SPRational pts = job->pts[phaseIndex];
        int64_t phaseDeadline = job->targetHost[phaseIndex];
        index += 1;
        CVPixelBufferRef bgra = [self transfer:box.buffer format:kCVPixelFormatType_32BGRA];
        if ([self requestUsesAsyncScale:_request]) {
            CVPixelBufferRef original = nil;
            auto sourceA = _held.find(job->frameA);
            if (_request.viewMode == SPLiveViewCompare && sourceA != _held.end()) {
                CVPixelBufferRef base = [self bgraFromSource:sourceA->second.source];
                original = [self scaleBuffer:base with:_baselineScaler];
                if (base) CVPixelBufferRelease(base);
            }
            [self enqueueAsyncScale:bgra original:original pts:pts synthetic:YES held:NO
                        captureHost:job->captureHost generation:job->generation deadlineHost:phaseDeadline];
            continue;
        }
        CVPixelBufferRef scaled = bgra;
        if (bgra && _scaler && [_request.engineID isEqualToString:@"apple.lowlatency"] && [self requestUsesLowPrescale:_request width:_width height:_height]) _lowSyntheticNoRescale++;
        if (bgra && _scaler && !([_request.engineID isEqualToString:@"apple.lowlatency"] && [self requestUsesLowPrescale:_request width:_width height:_height])) {
            scaled = [_scaler scaleBuffer:bgra error:NULL];
            CVPixelBufferRelease(bgra);
        }
        if (!scaled) {
            _syntheticFail += 1;
            [self erasePending:pts];
            continue;
        }
        CVPixelBufferRef original = nil;
        auto sourceA = _held.find(job->frameA);
        if (_request.viewMode == SPLiveViewCompare && sourceA != _held.end()) {
            if (_lowLatency && [self requestUsesLowPrescale:_request width:_width height:_height]) {
                CVPixelBufferRef cached=[self lowPrescaledForIdentity:job->frameA];
                if (cached) original=CVPixelBufferRetain(cached);
            } else {
                CVPixelBufferRef base = [self bgraFromSource:sourceA->second.source];
                original = [self scaleBuffer:base with:_request.scaleEnabled ? _baselineScaler : nil];
                if (base) CVPixelBufferRelease(base);
            }
        }
        if (_testCapturePlayout && original && sourceA != _held.end()) {
            int a=SPTestBGRAFirstByte(sourceA->second.source), b=SPTestBGRAFirstByte(original);
            if (a>=0 && b>=0) { if (abs(a-b)<=2) _testBaselineMatches++; else _testBaselineMismatches++; }
        }
        [self enqueueReadyEnhanced:scaled original:original pts:pts synthetic:YES held:NO
                      captureHost:job->captureHost generation:job->generation deadlineHost:phaseDeadline];
    }
    if (!_rifePending.empty() && _rifePendingGeneration == _sourceGeneration && (_rife || _lowLatency) && !_stopped) {
        auto pending = _rifePending;
        uint64_t pendingGeneration = _rifePendingGeneration;
        [self clearPendingRife];
        [self submitEventGroup:pending generation:pendingGeneration];
    }
    [self trimHeld];
    delete job;
}

- (void)trimHeld {
    if (_held.size() < 8) return;
    std::vector<uint64_t> keys;
    keys.reserve(_held.size());
    for (const auto &entry : _held) keys.push_back(entry.first);
    std::sort(keys.begin(), keys.end());
    for (uint64_t key : keys) {
        if (_held.size() <= 6) break;
        auto found = _held.find(key);
        if (found == _held.end()) continue;
        if (found->second.pins > 0) continue;
        if (found->second.source) CVPixelBufferRelease(found->second.source);
        if (found->second.yuv) CVPixelBufferRelease(found->second.yuv);
        if (found->second.lowPrescaled) CVPixelBufferRelease(found->second.lowPrescaled);
        _held.erase(found);
    }
}

// The accepted input clock and its generated events must be processed as one
// ordered operation. Shared with the deterministic production-path contract.
- (void)handleAcceptedInput:(uint64_t)identity events:(const std::vector<sp::SPScheduleOutput> &)events generation:(uint64_t)generation {
    [self observeSourceIdentity:identity];
    [self handleEvents:events generation:generation];
}

- (void)handleEvents:(const std::vector<sp::SPScheduleOutput> &)events generation:(uint64_t)generation {
    size_t index = 0;
    while (index < events.size()) {
        const sp::SPScheduleOutput &event = events[index];
        if (event.skipReason == sp::SPScheduleSkipReason::SceneCut ||
            event.skipReason == sp::SPScheduleSkipReason::Gap ||
            event.skipReason == sp::SPScheduleSkipReason::Boundary) {
            _sceneSkips += 1;
            _havePair = NO;
            [self clearPendingRife];
        }
        if (event.action != sp::SPScheduleAction::Interpolate) {
            auto found = _held.find(event.sourceIdentity);
            int64_t host = found == _held.end() ? 0 : found->second.host;
            [self enqueueSourceIdentity:event.sourceIdentity pts:event.pts host:host generation:generation
                                   force:event.skipReason != sp::SPScheduleSkipReason::None];
            index += 1;
            continue;
        }
        std::vector<sp::SPScheduleOutput> group;
        while (index < events.size() && events[index].action == sp::SPScheduleAction::Interpolate &&
               events[index].frameA == event.frameA && events[index].frameB == event.frameB) {
            group.push_back(events[index]);
            index += 1;
        }
        _scheduledSynthetic += group.size();
        _epochScheduled += group.size();
        if (_probeWindowOpen) {
            for (const auto &item : group) {
                if (sp::spCmp(item.pts, _probeMinPts) >= 0) _measuredScheduled += 1;
            }
        }
        if (group.size() > 3) _phaseBatchSplits += 1;
        for (size_t batch = 0; batch < group.size(); batch += 3) {
            size_t count = MIN((size_t)3, group.size() - batch);
            std::vector<sp::SPScheduleOutput> slice(group.begin() + (long)batch, group.begin() + (long)(batch + count));
            [self submitEventGroup:slice generation:generation];
        }
    }
}

- (BOOL)buildOnQueue:(NSError **)error {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        if (error) *error = SPLiveError(30, @"没有 Metal 设备");
        return NO;
    }
    if (_request.interpolationEnabled && ![self requestUsesAsyncEngine:_request]) {
        if (![SPFRCEngine isAvailable]) {
            if (error) *error = SPLiveError(31, @"这台 Mac 不支持 Apple 帧率转换");
            _resolved.interpolationActive = NO;
            _resolved.unavailableReason = @"Apple 帧率转换不可用";
            return NO;
        }
        NSError *local = nil;
        _metal = [[SPFrameBudgetMetal alloc] initWithDevice:device library:nil width:(uint32_t)_width
                                                     height:(uint32_t)_height
                                                pixelFormat:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                                                      error:&local];
        SPFRCQuality quality = _request.quality == SPFRCQualityHigh ? SPFRCQualityHigh : SPFRCQualityNormal;
        _engine = _metal ? [[SPFRCEngine alloc] initWithMetal:_metal sessions:2 outputCapacity:8 quality:quality error:&local] : nil;
        if (!_engine) {
            if (error) *error = local ?: SPLiveError(32, @"插帧会话创建失败");
            _resolved.interpolationActive = NO;
            _resolved.unavailableReason = local.localizedDescription ?: @"插帧会话创建失败";
            return NO;
        }
        _resolved.interpolationActive = YES;
        _resolved.unavailableReason = @"";
    } else if (_request.interpolationEnabled) {
        if (!_lowLatency && !_rife && !_distil) {
            if (error) *error = SPLiveError(35, @"引擎还没有准备好");
            _resolved.interpolationActive = NO;
            return NO;
        }
        _resolved.interpolationActive = YES;
        _resolved.engineID = _request.engineID ?: @"";
        _resolved.modelID = _request.modelID ?: @"";
        _resolved.unavailableReason = @"";
    }
    if (_request.scaleEnabled) {
        BOOL autoAnime = (_request.scaleEngine == SPLiveScaleAnime4K || _request.scaleEngine == SPLiveScaleRealCUGAN) && _request.outputWidth == 0 && _request.outputHeight == 0;
        int outW = autoAnime ? _width * 2 : (_request.outputWidth > 0 ? (_request.outputWidth & ~1) : _width);
        int outH = autoAnime ? _height * 2 : (_request.outputHeight > 0 ? (_request.outputHeight & ~1) : _height);
        if (outW < 2 || outH < 2) {
            if (error) *error = SPLiveError(33, @"输出尺寸无效");
            return NO;
        }
        NSError *local = nil;
        if (![self requestUsesAsyncScale:_request]) {
            _scaler = [[SPSpatialScaler alloc] initWithDevice:device inputW:_width inputH:_height outputW:outW outputH:outH
                                                       engine:_request.scaleEngine error:&local];
        }
        if (_request.scaleEngine == SPLiveScaleLanczos) _baselineScaler = _scaler;
        else _baselineScaler = [[SPSpatialScaler alloc] initWithDevice:device inputW:_width inputH:_height outputW:outW outputH:outH
                                                                engine:SPLiveScaleLanczos error:&local];
        BOOL scaleEngineReady = _request.scaleEngine == SPLiveScaleAppleLowLatencySR ? _appleSR != nil : (_request.scaleEngine == SPLiveScaleAppleVideoSR ? _videoSR != nil : (_request.scaleEngine == SPLiveScaleAnime4K ? _animeSR != nil : (_request.scaleEngine == SPLiveScaleRealCUGAN ? _cuganSR != nil : _scaler != nil)));
        if (!scaleEngineReady || !_baselineScaler) {
            _resolved.scaleActive = NO;
            _resolved.unavailableReason = local.localizedDescription ?: @"缩放创建失败";
            if (error) *error = local ?: SPLiveError(34, _resolved.unavailableReason);
            [self publishStatus:_resolved.unavailableReason failed:YES];
            return ([self requestUsesAsyncScale:_request] || [self requestUsesLowPrescale:_request width:_width height:_height]) ? NO : (!_request.interpolationEnabled ? NO : YES);
        }
        if ([self requestUsesLowPrescale:_request width:_width height:_height]) {
            CVPixelBufferRef sample=NULL;
            for (const auto &entry : _held) if (entry.second.source) { sample=entry.second.source; break; }
            if (sample) {
                CVPixelBufferRef bgra=[self transfer:sample format:kCVPixelFormatType_32BGRA];
                CVPixelBufferRef scaled=bgra ? [self scaleBuffer:bgra with:_scaler] : NULL;
                if (bgra) CVPixelBufferRelease(bgra);
                BOOL valid=scaled && CVPixelBufferGetWidth(scaled)==outW && CVPixelBufferGetHeight(scaled)==outH;
                if (scaled) CVPixelBufferRelease(scaled);
                if (!valid) { if (error) *error=SPLiveError(39,@"低延迟前置缩放准备失败"); return NO; }
            }
        }
        _resolved.scaleActive = YES;
        _resolved.outputWidth = outW;
        _resolved.outputHeight = outH;
    } else {
        _resolved.scaleActive = NO;
        _resolved.outputWidth = _width;
        _resolved.outputHeight = _height;
    }
    if (!_request.interpolationEnabled) _resolved.interpolationActive = NO;
    _resolved.unavailableReason = @"";
    _sessionReady = YES;
    _resolved.committed = YES;
    NSString *status = _stopped ? @"已停止" : (_resolved.interpolationActive ? @"增强运行" : (_resolved.scaleActive ? @"缩放运行" : @"预览原画面"));
    if (!_stopped && _resolved.presentationLimited) status = [status stringByAppendingString:@" · 显示器刷新率低于目标帧率"];
    [self publishStatus:status failed:NO];
    return YES;
}

- (void)beginBuildOnQueue {
    if (_sessionReady || _width < 2) return;
    if ([self requestUsesAsyncEngine:_request] || [self requestUsesAsyncScale:_request]) {
        if (_preparing || _asyncPrepareFailed) return;
        [self startAsyncEngine:_request];
        return;
    }
    if (_building) return;
    _building = YES;
    [self publishStatus:@"准备引擎" failed:NO];
    NSError *error = nil;
    int64_t traceBuildStart = _testCapturePlayout ? SPHostNow() : 0;
    BOOL ok = [self buildOnQueue:&error];
    if (_testCapturePlayout && _testTimingTrace.count < 80) {
        if (!_testTimingTrace) _testTimingTrace=[NSMutableArray array];
        [_testTimingTrace addObject:@{ @"kind":@"rebuild", @"durationMs":@((double)SPHostToNs(SPHostNow()-traceBuildStart)/1e6),
            @"success":@(ok), @"error":error.localizedDescription ?: @"", @"configVersion":@(_configVersion) }];
    }
    _building = NO;
    if (!ok) [self publishStatus:error.localizedDescription ?: @"准备失败" failed:YES];
}

- (void)pump {
    std::deque<SPLiveInbound> batch;
    {
        std::lock_guard<std::mutex> lock(_inMx);
        batch.swap(_inbound);
        _pumpQueued = NO;
    }
    for (auto &item : batch) {
        if (item.readyHost > item.host) SPPushSample(_copyEntryNs, SPHostToNs(item.readyHost - item.host));
        if (_stopped) {
            _stoppedDrops += 1;
            CVPixelBufferRelease(item.buffer);
            if (_stoppedDrops == 1 || _stoppedDrops % 60 == 0) {
                [self publishStatus:@"已停止，新帧已丢弃" failed:YES];
            }
            continue;
        }
        if (item.generation != _sourceGeneration) {
            _generationDrops += 1;
            CVPixelBufferRelease(item.buffer);
            continue;
        }
        if (item.ptsDen > 0) {
            __int128 inputPTS = (__int128)item.ptsNum * 1000000000 / item.ptsDen;
            if (inputPTS >= INT64_MIN && inputPTS <= INT64_MAX)
                _fpsMeter.input((int64_t)inputPTS, (int64_t)(CACurrentMediaTime() * 1e9));
        }
        if (SPBufferIsHDR(item.buffer)) {
            CVPixelBufferRelease(item.buffer);
            _resolved.interpolationActive = NO;
            _resolved.scaleActive = NO;
            BOOL rife = [_request.engineID isEqualToString:@"rife.metal"];
            NSString *reason = rife ? @"RIFE 只处理 8 位 SDR，HDR 已停用" : @"HDR 捕获未增强";
            _resolved.unavailableReason = reason;
            [self publishStatus:reason failed:YES];
            continue;
        }
        _sourcePixelFormat = CVPixelBufferGetPixelFormatType(item.buffer);
        int previousSourceWidth = _sourceWidth, previousSourceHeight = _sourceHeight;
        _sourceWidth = (int)CVPixelBufferGetWidth(item.buffer);
        _sourceHeight = (int)CVPixelBufferGetHeight(item.buffer);
        int width = _sourceWidth & ~1;
        int height = _sourceHeight & ~1;
        // A prepared processing size can precede the first observed raw size.
        // First observation confirms it; only a change between known raw sizes
        // invalidates an otherwise identical even-sized processing pipeline.
        BOOL hadRawSize = previousSourceWidth > 0 && previousSourceHeight > 0;
        BOOL rawSizeChanged = hadRawSize && (_sourceWidth != previousSourceWidth || _sourceHeight != previousSourceHeight);
        if (_testCapturePlayout && _testTimingTrace.count < 80) {
            if (!_testTimingTrace) _testTimingTrace=[NSMutableArray array];
            [_testTimingTrace addObject:@{ @"kind":@"pumpInput", @"ptsNum":@(item.ptsNum), @"ptsDen":@(item.ptsDen),
                @"sourceSize":@[@(_sourceWidth),@(_sourceHeight)], @"knownRawBefore":@(hadRawSize),
                @"sizeInvalidates":@(width!=_width || height!=_height || rawSizeChanged), @"sessionReady":@(_sessionReady),
                @"captureToPumpMs":@((double)SPHostToNs(SPHostNow()-item.host)/1e6),
                @"configVersion":@(_configVersion), @"measurementEpoch":@(_measurementEpoch) }];
        }
        if (width != _width || height != _height || rawSizeChanged) {
            _width = width;
            _height = height;
            _configVersion += 1;
            _inflightEpoch = _configVersion;
            _inflight = 0;
            _sessionReady = NO;
            _prepareToken += 1;
            _preparing = NO;
            _asyncPrepareFailed = NO;
            [_engine invalidate];
            _engine = nil;
            [_lowLatency invalidate];
            _lowLatency = nil;
            [_rife invalidate];
            _rife = nil;
            [_distil invalidate];
            _distil = nil;
            _previousSourceIdentity = 0;
            [_appleSR invalidate];
            [_videoSR invalidate];
            [_animeSR invalidate];
            [_cuganSR invalidate];
            _appleSR = nil;
            _videoSR = nil;
            _animeSR = nil;
            _cuganSR = nil;
            [self resetAsyncScaleOnQueue];
            _scaler = nil;
            _baselineScaler = nil;
            _havePair = NO;
            [self clearPlaySlots];
            _pending.clear();
            _marks.clear();
            _haveLastPts = NO;
            _haveAnchor = NO;
            [self resetSchedulerOnQueue];
            [self beginMeasurementEpoch];
        }
        uint8_t luma[64];
        SPSampleLuma(item.buffer, luma, 64);
        BOOL cut = NO;
        BOOL changed = YES;
        if (_haveLuma) {
            cut = sp::spDetectSceneCut(_previousLuma, luma, 64);
            int64_t mad = 0;
            for (int i = 0; i < 64; ++i) {
                int delta = (int)luma[i] - (int)_previousLuma[i];
                if (delta < 0) delta = -delta;
                mad += delta;
            }
            changed = mad / 64 > 3;
        }
        memcpy(_previousLuma, luma, 64);
        _haveLuma = YES;
        if (cut && _videoSR) _videoSRDiscontinuity = YES;
        if (changed) _windowChanged += 1;
        uint64_t identity = _nextIdentity++;
        _held[identity].source = item.buffer;
        _held[identity].host = item.host;
        _held[identity].pts = sp::spMake(item.ptsNum, item.ptsDen);
        auto previous = _held.find(_previousSourceIdentity);
        if (!cut && previous != _held.end()) {
            sp::SPRational delta{};
            if (sp::spSub(_held[identity].pts, previous->second.pts, delta) &&
                sp::spCmp(delta, sp::spMake(0, 1)) > 0 && sp::spCmp(delta, sp::spMake(1, 2)) <= 0)
                _held[identity].previousIdentity = _previousSourceIdentity;
        }
        _previousSourceIdentity = identity;
        if ((_request.interpolationEnabled || _request.scaleEnabled) && !_sessionReady) {
            [self beginBuildOnQueue];
        }
        BOOL engineReady = _engine != nil || _lowLatency != nil || _rife != nil || _distil != nil;
        if (_request.interpolationEnabled && _sessionReady && engineReady) {
            sp::SPScheduleInput input;
            input.pts = sp::spMake(item.ptsNum, item.ptsDen);
            input.identity = identity;
            input.generation = _configVersion;
            input.sceneCutBefore = cut;
            sp::SPSchedulePushResult result = _scheduler.push(input);
            if (result.reject == sp::SPScheduleReject::None) {
                [self handleAcceptedInput:identity events:result.events generation:item.generation];
            }
        } else {
            sp::SPRational pts = sp::spMake(item.ptsNum, item.ptsDen);
            [self observeSourceIdentity:identity];
            [self enqueueSourceIdentity:identity pts:pts host:item.host generation:item.generation force:NO];
        }
        [self trimHeld];
    }
    [self publishStats];
}

- (BOOL)installSynchronouslyWidth:(int)width height:(int)height error:(NSError **)error {
    __block BOOL ok = NO;
    __block NSError *local = nil;
    dispatch_sync(_q, ^{
        self->_stopped = NO;
        self->_width = width & ~1;
        self->_height = height & ~1;
        [self resetSchedulerOnQueue];
        [self refreshResolvedOnQueue];
        ok = [self buildOnQueue:&local];
    });
    if (!ok && error) *error = local;
    return ok;
}

+ (CVPixelBufferRef)syntheticFrame:(int)index {
    CVPixelBufferRef buffer = SPCreateBuffer(1280, 720, kCVPixelFormatType_32BGRA);
    if (!buffer) return NULL;
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    for (int y = 0; y < 720; ++y) {
        uint8_t *row = base + (size_t)y * stride;
        for (int x = 0; x < 1280; ++x) {
            row[x * 4 + 0] = 18;
            row[x * 4 + 1] = 18;
            row[x * 4 + 2] = 18;
            row[x * 4 + 3] = 255;
        }
    }
    int origin = 48 + (index % 20) * 36;
    for (int y = 220; y < 292; ++y) {
        uint8_t *row = base + (size_t)y * stride;
        for (int x = origin; x < origin + 72 && x < 1280; ++x) {
            row[x * 4 + 0] = 240;
            row[x * 4 + 1] = 240;
            row[x * 4 + 2] = 240;
            row[x * 4 + 3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    SPForceSDRAttachments(buffer);
    return buffer;
}

+ (NSDictionary<NSString *, id> *)runFRCPTSProbe {
    SPLiveProcessor *processor = [[SPLiveProcessor alloc] init];
    processor->_request.interpolationEnabled = YES;
    NSError *error = nil;
    if (![processor installSynchronouslyWidth:1280 height:720 error:&error])
        return @{@"processed": @NO, @"error": error.localizedDescription ?: @"prepare"};
    CVPixelBufferRef a = [self syntheticFrame:0], b = [self syntheticFrame:1];
    __block CVPixelBufferRef ya = NULL, yb = NULL;
    dispatch_sync(processor->_q, ^{
        ya = [processor transfer:a format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
        yb = [processor transfer:b format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
    });
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSUInteger count = 0;
    __block NSString *failure = @"";
    CMTime ptsA = CMTimeMake(3000000, 30000), ptsB = CMTimeMake(3001001, 30000);
    BOOL submitted = ya && yb && [processor->_engine submitPhasesWithFrameA:ya frameB:yb ptsA:ptsA ptsB:ptsB
        phases:@[@0.25f, @0.5f, @0.75f] sequential:NO token:1
        completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *outputs, double latency, NSError *runError) {
            (void)token; (void)latency; count = outputs.count; failure = runError.localizedDescription ?: @"";
            dispatch_semaphore_signal(done);
        }];
    if (submitted) dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    BOOL sameRejected = ya && yb && ![processor->_engine submitPhasesWithFrameA:ya frameB:yb ptsA:ptsA ptsB:ptsA
        phases:@[@0.5f] sequential:NO token:2 completion:^(uint64_t t, NSArray<SPOwnedPixelBuffer *> *o, double l, NSError *e) {
            (void)t; (void)o; (void)l; (void)e;
        }];
    __block BOOL midpointOK = NO;
    dispatch_semaphore_t midpointDone = dispatch_semaphore_create(0);
    BOOL midpointSubmitted = ya && yb && [processor->_engine submitPairWithFrameA:ya frameB:yb ptsA:ptsA ptsB:ptsB token:3
        completion:^(uint64_t token, CVPixelBufferRef output, double latency, NSError *runError) {
            (void)token; (void)latency; midpointOK = output != NULL && runError == nil;
            if (output) CVPixelBufferRelease(output);
            dispatch_semaphore_signal(midpointDone);
        }];
    if (midpointSubmitted) dispatch_semaphore_wait(midpointDone, DISPATCH_TIME_FOREVER);
    if (a) CVPixelBufferRelease(a); if (b) CVPixelBufferRelease(b);
    if (ya) CVPixelBufferRelease(ya); if (yb) CVPixelBufferRelease(yb);
    [processor stop];
    return @{@"processed": @(submitted && count == 3 && failure.length == 0), @"outputCount": @(count),
             @"duplicatePTSRejected": @(sameRejected), @"ptsA": @"3000000/30000", @"ptsB": @"3001001/30000",
             @"fileMidpointProcessed": @(midpointSubmitted && midpointOK),
             @"phases": @[@0.25f, @0.5f, @0.75f], @"error": failure};
}

+ (NSDictionary<NSString *, id> *)runAppleLowSRProbe {
    NSArray<NSNumber *> *factors = [SPAppleLowLatencySR supportedFactorsForWidth:1280 height:720];
    BOOL supportsCandidate = NO;
    for (NSNumber *factor in factors) if (fabsf(factor.floatValue - 1.5f) < 0.0001f) supportsCandidate = YES;
    if (!supportsCandidate) return @{@"supportedFactors": factors, @"candidateSupported": @NO, @"processed": @NO};
    SPAppleLowLatencySR *scaler = [[SPAppleLowLatencySR alloc] init];
    NSError *error = nil;
    if (![scaler prepareWidth:1280 height:720 scale:1.5f error:&error]) {
        return @{@"supportedFactors": factors, @"candidateSupported": @YES, @"processed": @NO,
                 @"error": error.localizedDescription ?: @"prepare"};
    }
    CVPixelBufferRef source = [self syntheticFrame:0];
    if (!source) { [scaler invalidate]; return @{@"candidateSupported": @YES, @"processed": @NO, @"error": @"source allocation"}; }
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    __block CVPixelBufferRef output = NULL;
    __block NSError *resultError = nil;
    __block double latency = 0;
    BOOL submitted = [scaler submitSource:source pts:CMTimeMake(1001, 30000) token:1
        completion:^(uint64_t token, CVPixelBufferRef result, double seconds, NSError *error) {
            (void)token; output = result; resultError = error; latency = seconds; dispatch_semaphore_signal(gate);
        }];
    if (submitted) dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
    int width = output ? (int)CVPixelBufferGetWidth(output) : 0;
    int height = output ? (int)CVPixelBufferGetHeight(output) : 0;
    OSType format = output ? CVPixelBufferGetPixelFormatType(output) : 0;
    double sourceCenter = SPWhiteCenterX(source);
    __block CVPixelBufferRef rgb = NULL;
    if (output) {
        SPLiveProcessor *converter = [[SPLiveProcessor alloc] init];
        dispatch_sync(converter->_q, ^{ rgb = [converter transfer:output format:kCVPixelFormatType_32BGRA]; });
    }
    double outputCenter = SPWhiteCenterX(rgb);
    BOOL contentOK = sourceCenter >= 0 && outputCenter >= 0 && fabs(outputCenter - sourceCenter * 1.5) <= 8;
    BOOL separateSurface = output && CVPixelBufferGetIOSurface(source) != CVPixelBufferGetIOSurface(output);
    BOOL processed = submitted && !resultError && width == 1920 && height == 1080 && contentOK && separateSurface;
    if (rgb) CVPixelBufferRelease(rgb);
    if (output) CVPixelBufferRelease(output);
    CVPixelBufferRelease(source);
    int continuousOK = 0, continuousFailed = 0;
    for (int i = 0; i < 300; ++i) {
        CVPixelBufferRef next = [self syntheticFrame:i];
        if (!next) { continuousFailed++; continue; }
        dispatch_semaphore_t nextGate = dispatch_semaphore_create(0);
        __block BOOL oneOK = NO;
        BOOL accepted = [scaler submitSource:next pts:CMTimeMake(i, 30) token:(uint64_t)i + 10
            completion:^(uint64_t callbackToken, CVPixelBufferRef result, double seconds, NSError *local) {
                (void)seconds;
                oneOK = callbackToken == (uint64_t)i + 10 && !local && result &&
                    CVPixelBufferGetWidth(result) == 1920 && CVPixelBufferGetHeight(result) == 1080;
                if (result) CVPixelBufferRelease(result);
                dispatch_semaphore_signal(nextGate);
            }];
        if (accepted) dispatch_semaphore_wait(nextGate, DISPATCH_TIME_FOREVER);
        if (accepted && oneOK) continuousOK++; else continuousFailed++;
        CVPixelBufferRelease(next);
    }
    [scaler invalidate];
    return @{@"supportedFactors": factors, @"candidateSupported": @YES, @"processed": @(processed),
             @"width": @(width), @"height": @(height), @"pixelFormat": @(format), @"pts": @"1001/30000",
             @"sourceCenter": @(sourceCenter), @"outputCenter": @(outputCenter), @"contentPositionOK": @(contentOK),
             @"separateSurface": @(separateSurface), @"continuousFrames": @300,
             @"continuousProcessed": @(continuousOK), @"continuousFailed": @(continuousFailed),
             @"continuousNote": @"Synthetic component test concurrent with other activity; not a realtime performance measurement.",
             @"elapsedSec": @(latency), @"error": resultError.localizedDescription ?: @""};
}

+ (NSDictionary<NSString *, id> *)runStaticHoldContract {
    CVPixelBufferRef a=SPQualityNV12(NO,0), b=SPQualityNV12(NO,0);
    if(!a||!b){if(a)CVPixelBufferRelease(a);if(b)CVPixelBufferRelease(b);return @{ @"ok":@NO, @"error":@"allocation" };}
    int64_t started=SPHostNow(); BOOL identical=SPIdenticalSourcePixels(a,b); double compareMs=(double)SPHostToNs(SPHostNow()-started)/1e6;
    CVPixelBufferLockBaseAddress(b,0);uint8_t *uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,1);size_t stride=CVPixelBufferGetBytesPerRowOfPlane(b,1), rows=CVPixelBufferGetHeightOfPlane(b,1), cols=CVPixelBufferGetWidthOfPlane(b,1)*2;
    uv[(rows-1)*stride+cols-1]^=1;CVPixelBufferUnlockBaseAddress(b,0);
    BOOL chromaDifference=!SPIdenticalSourcePixels(a,b);
    CVPixelBufferLockBaseAddress(b,0);uv=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,1);uv[(rows-1)*stride+cols-1]^=1;CVPixelBufferUnlockBaseAddress(b,0);
    CVPixelBufferLockBaseAddress(b,0);uint8_t *y=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,0);size_t ys=CVPixelBufferGetBytesPerRowOfPlane(b,0);y[1439*ys+2559]^=1;CVPixelBufferUnlockBaseAddress(b,0);
    BOOL lumaDifference=!SPIdenticalSourcePixels(a,b);
    CVPixelBufferLockBaseAddress(b,0);y=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b,0);y[1439*ys+2559]^=1;CVPixelBufferUnlockBaseAddress(b,0);
    NSError *error=nil;SPLowLatencyEngine *engine=[[SPLowLatencyEngine alloc] init];BOOL prepared=[engine prepareWidth:1920 height:1080 frames:1 error:&error];
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init];[p adoptSourceGeneration:1];
    SPLivePlanRequest *request=[[SPLivePlanRequest alloc] init];request.interpolationEnabled=YES;request.engineID=@"apple.lowlatency";request.rateKind=SPLiveRateMultiplier;request.multiplier=2;
    request.scaleEnabled=YES;request.scaleEngine=SPLiveScaleLanczos;request.outputWidth=1920;request.outputHeight=1080;
    dispatch_sync(p->_q, ^{ p->_width=2560;p->_height=1440;p->_held[11].source=CVPixelBufferRetain(a);p->_held[11].pts=sp::spMake(0,1);p->_held[11].host=SPHostNow();
        p->_held[12].source=CVPixelBufferRetain(b);p->_held[12].pts=sp::spMake(1,60);p->_held[12].host=SPHostNow();
        if(prepared)[p installRequest:request lowLatency:engine rife:nil distil:nil appleSR:nil videoSR:nil animeSR:nil cuganSR:nil];
        sp::SPScheduleOutput event;event.action=sp::SPScheduleAction::Interpolate;event.frameA=11;event.frameB=12;event.pts=sp::spMake(1,120);event.phase=sp::spMake(1,2);
        if(p->_sessionReady)[p submitEventGroup:{event} generation:1]; });
    __block BOOL held=NO;
    for(int i=0;i<200&&!held;i++){usleep(10000);dispatch_sync(p->_q,^{ held=p->_lastEnhanced && !p->_lastSynthetic && sp::spCmp(p->_lastRedrawPts,sp::spMake(1,120))==0 && p->_staticHoldPhases==1 && p->_submitted==0 && p->_syntheticOK==0; });}
    [p stop];CVPixelBufferRelease(a);CVPixelBufferRelease(b);
    return @{ @"ok":@(identical&&chromaDifference&&lumaDifference&&prepared&&held), @"identicalFullFrame":@(identical), @"singleChromaChangeRejected":@(chromaDifference),
        @"singleLumaChangeRejected":@(lumaDifference), @"actualProcessorHeldWithoutModel":@(held), @"comparisonMs":@(compareMs),
        @"scope":@"2K NV12 exact identity and headless production held phase; no visual or physical FPS acceptance" };
}

// Controlled synthetic component comparison. No capture, window, physical
// presentation or file provider is involved. Each result is from its named bridge.
+ (NSDictionary<NSString *, id> *)runNativeBridgeQualityProbeWithBundle:(NSBundle *)bundle {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return @{ @"ok": @NO, @"error": @"no Metal device", @"cases": @[] };
    SPLiveProcessor *converter = [[SPLiveProcessor alloc] init];
    NSMutableArray *cases = [NSMutableArray array];
    NSString *selection = NSProcessInfo.processInfo.environment[@"KHUA_NATIVE_BRIDGE_ENGINE"] ?: @"all";
    NSArray<NSString *> *choices = @[@"all", @"frc-normal", @"frc-quality", @"rife", @"llfi"];
    if (![choices containsObject:selection]) return @{ @"ok":@NO, @"error":@"invalid KHUA_NATIVE_BRIDGE_ENGINE", @"cases":@[] };
    BOOL allOK = YES, timedOut = NO;
    for (int style=0; style<2; ++style) for (int moving=0; moving<2; ++moving) {
        CVPixelBufferRef input=SPQualityNV12(NO,moving?8:0,style);
        CVPixelBufferRef rgba=input?[converter transfer:input format:kCVPixelFormatType_32BGRA]:NULL;
        NSDictionary *diff=rgba?SPQualityDiff(rgba,rgba):@{};
        BOOL ok=diff.count>0; allOK=allOK && ok;
        [cases addObject:@{ @"engine":@"generator-identity", @"model":@"none", @"quality":@"none", @"pattern":style?@"thin-glyph":@"3px-stripes", @"motion":moving?@"8px":@"static",
            @"inputSize":@[@2560,@1440], @"processingSize":@[@2560,@1440], @"actualOutputSize":rgba?@[@(CVPixelBufferGetWidth(rgba)),@(CVPixelBufferGetHeight(rgba))]:@[],
            @"inputPixelFormat":@"NV12 video range", @"actualOutputPixelFormat":@(rgba?CVPixelBufferGetPixelFormatType(rgba):0), @"phase":@0,
            @"requestedWarmups":@0, @"warmupsCompleted":@0, @"requestedSamples":@1, @"samples":@(ok?1:0), @"timingScope":@"not timed",
            @"processed":@(ok), @"difference":diff, @"role":@"generator identity only; not app capture/color/display baseline" }];
        if(rgba)CVPixelBufferRelease(rgba); if(input)CVPixelBufferRelease(input);
    }
    for (int kind=0; kind<4 && !timedOut; ++kind) {
        NSString *selectionKey = @[@"frc-normal", @"frc-quality", @"rife", @"llfi"][kind];
        if (![selection isEqualToString:@"all"] && ![selection isEqualToString:selectionKey]) continue;
        NSString *engineName = kind < 2 ? @"apple.frc.bridge" : (kind == 2 ? @"rife.metal.bridge" : @"apple.lowlatency.bridge");
        NSString *quality = kind == 1 ? @"quality" : (kind == 2 ? @"fast" : @"normal");
        NSString *model = kind == 0 ? @"vt.frc.normal" : (kind == 1 ? @"vt.frc.quality" : (kind == 2 ? @"rife-v4.25" : @"vt.llfi.temporal.1"));
        NSError *setupError = nil;
        SPFrameBudgetMetal *metal = nil; SPFRCEngine *frc = nil; SPRifeBridge *rife = nil; SPLowLatencyEngine *low = nil; SPSpatialScaler *down = nil;
        if (kind < 2) {
            metal = [[SPFrameBudgetMetal alloc] initWithDevice:device library:nil width:2560 height:1440 pixelFormat:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange error:&setupError];
            if (metal) frc = [[SPFRCEngine alloc] initWithMetal:metal sessions:1 outputCapacity:4 quality:kind == 1 ? SPFRCQualityHigh : SPFRCQualityNormal error:&setupError];
        } else if (kind == 2) {
            rife = [[SPRifeBridge alloc] initWithResourceBundle:bundle];
            if (![rife prepareModelID:model quality:quality width:2560 height:1440 error:&setupError]) rife = nil;
        } else {
            low = [[SPLowLatencyEngine alloc] init];
            if (![low prepareWidth:1920 height:1080 frames:1 error:&setupError]) low = nil;
            if (low) down = [[SPSpatialScaler alloc] initWithDevice:device inputW:2560 inputH:1440 outputW:1920 outputH:1080 engine:SPLiveScaleLanczos error:&setupError];
        }
        BOOL ready = kind < 2 ? frc != nil : (kind == 2 ? rife != nil : low != nil && down != nil);
        for (int style=0; style<2 && !timedOut; ++style) for (int moving=0; moving<2 && !timedOut; ++moving) {
            NSMutableDictionary *item = [@{ @"engine":engineName, @"model":model, @"quality":quality,
                @"pattern":style?@"thin-glyph":@"3px-stripes", @"motion":moving?@"8px":@"static", @"phase":@0.5,
                @"inputSize":@[@2560,@1440], @"processingSize":kind==3?@[@1920,@1080]:@[@2560,@1440],
                @"inputPixelFormat":kind==3?@"BGRA8 after Lanczos 1440-to-1080":@"NV12 video range",
                @"requestedWarmups":@1, @"requestedSamples":@3, @"warmupsCompleted":@0, @"samples":@0,
                @"timingScope":@"bridge submit through completion and waiter wake-up; includes bridge conversions, excludes setup and comparison",
                @"role":kind==3?@"1080p performance reference; not native 1440p":@"native-size bridge comparison" } mutableCopy];
            if (!ready) { item[@"failure"] = setupError.localizedDescription ?: @"bridge setup failed"; allOK=NO; [cases addObject:item]; continue; }
            CVPixelBufferRef a=SPQualityNV12(NO,0,style), b=SPQualityNV12(NO,moving?8:0,style), gt=SPQualityNV12(NO,moving?4:0,style);
            CVPixelBufferRef inputA=a, inputB=b;
            CVPixelBufferRef ref=[converter transfer:gt format:kCVPixelFormatType_32BGRA];
            CVPixelBufferRef downA=NULL, downB=NULL, downGT=NULL;
            if (kind==3 && a && b && ref) {
                CVPixelBufferRef rgbaA=[converter transfer:a format:kCVPixelFormatType_32BGRA], rgbaB=[converter transfer:b format:kCVPixelFormatType_32BGRA];
                downA=rgbaA?[down scaleBuffer:rgbaA error:&setupError]:NULL; downB=rgbaB?[down scaleBuffer:rgbaB error:&setupError]:NULL;
                downGT=[down scaleBuffer:ref error:&setupError];
                if(rgbaA)CVPixelBufferRelease(rgbaA); if(rgbaB)CVPixelBufferRelease(rgbaB);
                CVPixelBufferRelease(ref); ref=downGT?CVPixelBufferRetain(downGT):NULL; inputA=downA; inputB=downB;
            }
            if (a) { item[@"actualSourceSize"]=@[@(CVPixelBufferGetWidth(a)), @(CVPixelBufferGetHeight(a))]; item[@"actualSourcePixelFormat"]=@(CVPixelBufferGetPixelFormatType(a)); }
            if (inputA) { item[@"actualBridgeInputSize"]=@[@(CVPixelBufferGetWidth(inputA)), @(CVPixelBufferGetHeight(inputA))]; item[@"actualBridgeInputPixelFormat"]=@(CVPixelBufferGetPixelFormatType(inputA)); }
            NSMutableArray *latencies=[NSMutableArray array], *differences=[NSMutableArray array]; NSDictionary *diff=nil; int warm=0; NSString *failure=@"";
            if (!inputA || !inputB || !ref) failure=setupError.localizedDescription ?: @"input allocation or conversion failed";
            for (int n=0; n<4 && !failure.length; ++n) {
                dispatch_semaphore_t done=dispatch_semaphore_create(0);
                __block NSArray<SPOwnedPixelBuffer *> *outputs=nil; __block NSError *runError=nil;
                CVPixelBufferRetain(inputA); CVPixelBufferRetain(inputB);
                SPFRCPhasesCompletion complete = ^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *frames, double elapsed, NSError *error) {
                    (void)token; (void)elapsed; outputs=frames; runError=error; CVPixelBufferRelease(inputA); CVPixelBufferRelease(inputB); dispatch_semaphore_signal(done);
                };
                int64_t started=SPHostNow();
                BOOL submitted = kind<2 ? [frc submitPhasesWithFrameA:inputA frameB:inputB ptsA:CMTimeMake(0,60) ptsB:CMTimeMake(1,60) phases:@[@0.5] sequential:NO token:n+1 completion:complete] :
                    (kind==2 ? [rife submitPrevious:inputA current:inputB timesteps:@[@0.5] token:n+1 completion:complete] :
                     [low submitPrevious:inputA current:inputB previousPTS:CMTimeMake(0,60) currentPTS:CMTimeMake(1,60) phases:@[@0.5] token:n+1 completion:complete]);
                if (!submitted) { CVPixelBufferRelease(inputA); CVPixelBufferRelease(inputB); failure=@"bridge rejected submission"; break; }
                if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30*NSEC_PER_SEC)) != 0) { failure=@"bridge completion timeout (30s); remaining cases skipped"; timedOut=YES; break; }
                double ms=(double)SPHostToNs(SPHostNow()-started)/1e6;
                CVPixelBufferRef raw=outputs.count ? outputs[0].buffer : NULL;
                if (runError || !raw) { failure=runError.localizedDescription ?: @"no output"; break; }
                item[@"actualOutputSize"]=@[@(CVPixelBufferGetWidth(raw)),@(CVPixelBufferGetHeight(raw))];
                item[@"actualOutputPixelFormat"]=@(CVPixelBufferGetPixelFormatType(raw));
                int expectedW=kind==3?1920:2560, expectedH=kind==3?1080:1440;
                if (CVPixelBufferGetWidth(raw)!=expectedW || CVPixelBufferGetHeight(raw)!=expectedH) { failure=@"output dimensions differ from requested processing size"; break; }
                if(n==0) { warm++; continue; }
                CVPixelBufferRef output=[converter transfer:raw format:kCVPixelFormatType_32BGRA];
                if (!output) { failure=@"output BGRA comparison conversion failed"; break; }
                diff=SPQualityDiff(ref,output); CVPixelBufferRelease(output);
                if (!diff.count) { failure=@"comparison failed"; break; }
                [latencies addObject:@(ms)]; [differences addObject:diff];
            }
            item[@"warmupsCompleted"]=@(warm); item[@"samples"]=@(latencies.count); item[@"latencyMs"]=latencies;
            if(diff) item[@"phaseVsSyntheticMidpointSamples"]=differences;
            if(failure.length) item[@"failure"]=failure;
            item[@"processed"]=@(warm==1 && latencies.count==3 && !failure.length);
            if(![item[@"processed"] boolValue]) allOK=NO;
            [cases addObject:item];
            for(CVPixelBufferRef f : {a,b,gt,ref,downA,downB,downGT}) if(f)CVPixelBufferRelease(f);
        }
        [frc invalidate]; [rife invalidate]; [low invalidate];
    }
    [converter stop];
    return @{ @"ok":@(allOK && !timedOut), @"cases":cases, @"timedOut":@(timedOut), @"selection":selection,
        @"scope":@"synthetic 2560x1440 NV12 patterns through application FRC/RIFE bridges and downscaled 1080p LLFI reference; no capture, file provider, drawable, physical playback, subjective acceptance, or sustained FPS" };
}

+ (NSDictionary<NSString *, id> *)runLiveQualityProbe {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice(); NSError *error=nil;
    SPSpatialScaler *down=[[SPSpatialScaler alloc] initWithDevice:device inputW:2560 inputH:1440 outputW:1920 outputH:1080 engine:SPLiveScaleLanczos error:&error];
    SPSpatialScaler *up=[[SPSpatialScaler alloc] initWithDevice:device inputW:1920 inputH:1080 outputW:2560 outputH:1440 engine:SPLiveScaleLanczos error:&error];
    if(!down||!up)return @{ @"ok":@NO, @"error":error.localizedDescription ?: @"scaler" };
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init]; NSMutableArray *cases=[NSMutableArray array]; BOOL ok=YES;
    for(int style=0;style<2;style++) for(int full=0;full<2;full++) for(int moving=0;moving<2;moving++) {
        if(style && full) continue;
        CVPixelBufferRef inputA=SPQualityNV12(full,0,style), inputB=SPQualityNV12(full,moving?8:0,style), inputGT=SPQualityNV12(full,moving?4:0,style);
        CVPixelBufferRef largeA=[p transfer:inputA format:kCVPixelFormatType_32BGRA], largeB=[p transfer:inputB format:kCVPixelFormatType_32BGRA], largeGT=[p transfer:inputGT format:kCVPixelFormatType_32BGRA];
        CVPixelBufferRef smallA=[down scaleBuffer:largeA error:&error], smallB=[down scaleBuffer:largeB error:&error], smallGT=[down scaleBuffer:largeGT error:&error];
        CVPixelBufferRef roundtrip=[up scaleBuffer:smallA error:&error];
        SPLowLatencyEngine *engine=[[SPLowLatencyEngine alloc] init]; BOOL ready=[engine prepareWidth:1920 height:1080 frames:1 error:&error];
        dispatch_semaphore_t done=dispatch_semaphore_create(0); __block CVPixelBufferRef raw=NULL; __block NSString *failure=@"";
        BOOL submitted=ready && smallA && smallB && [engine submitPrevious:smallA current:smallB previousPTS:CMTimeMake(0,60) currentPTS:CMTimeMake(1,60) phases:@[@0.5f] token:1 completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *outputs, double latency, NSError *err) {
            (void)token;(void)latency; if(outputs.count)raw=CVPixelBufferRetain(outputs[0].buffer);failure=err.localizedDescription ?: @"";dispatch_semaphore_signal(done);
        }];
        if(submitted)dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
        CVPixelBufferRef output=[p transfer:raw format:kCVPixelFormatType_32BGRA];
        NSDictionary *spatial=SPQualityDiff(largeA,roundtrip), *motion=SPQualityDiff(smallGT,output);
        BOOL valid=output && spatial.count>0 && motion.count>0 && failure.length==0;
        ok=ok&&valid;
        [cases addObject:@{ @"range":full?@"full":@"video", @"pattern":style?@"thin-glyph-like":@"3px-stripes", @"motion":moving?@"8px":@"static", @"processed":@(valid),
            @"sourceFormat":full?@"NV12-full":@"NV12-video", @"sourceTo1080To2k":spatial, @"phaseOutputVs1080Midpoint":motion,
            @"llOutputFormat":@(raw?CVPixelBufferGetPixelFormatType(raw):0), @"error":failure }];
        [engine invalidate];
        for(CVPixelBufferRef f : {inputA,inputB,inputGT,largeA,largeB,largeGT,smallA,smallB,smallGT,roundtrip,raw,output}) if(f)CVPixelBufferRelease(f);
    }
    __block SPLivePreviewView *preview=nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ preview=[[SPLivePreviewView alloc] initWithFrame:NSMakeRect(0,0,64,32)]; });
    NSDictionary *resources=[preview runOffscreenDrawAndLifetimeProbe];
    NSError *frcError=nil;
    SPFrameBudgetMetal *metal=[[SPFrameBudgetMetal alloc] initWithDevice:device library:nil width:2560 height:1440 pixelFormat:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange error:&frcError];
    SPFRCEngine *frc=metal?[[SPFRCEngine alloc] initWithMetal:metal sessions:1 outputCapacity:4 quality:SPFRCQualityNormal error:&frcError]:nil;
    NSMutableArray *nativeFRC=[NSMutableArray array];
    if(frc) for(int moving=0;moving<2;moving++) {
        CVPixelBufferRef a=SPQualityNV12(NO,0,YES), b=SPQualityNV12(NO,moving?8:0,YES), gt=SPQualityNV12(NO,moving?4:0,YES);
        dispatch_semaphore_t done=dispatch_semaphore_create(0); __block CVPixelBufferRef raw=NULL; __block NSString *failure=@"";
        BOOL submitted=[frc submitPhasesWithFrameA:a frameB:b ptsA:CMTimeMake(0,60) ptsB:CMTimeMake(1,60) phases:@[@0.5f] sequential:NO token:1 completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *outputs, double latency, NSError *err) {
            (void)token;(void)latency;if(outputs.count)raw=CVPixelBufferRetain(outputs[0].buffer);failure=err.localizedDescription ?: @"";dispatch_semaphore_signal(done);
        }];
        if(submitted)dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
        CVPixelBufferRef ref=[p transfer:gt format:kCVPixelFormatType_32BGRA], output=[p transfer:raw format:kCVPixelFormatType_32BGRA];
        [nativeFRC addObject:@{ @"motion":moving?@"8px":@"static", @"processed":@(output!=NULL), @"sourceSize":@[@2560,@1440],
            @"phaseOutputVsNativeMidpoint":SPQualityDiff(ref,output), @"error":failure }];
        for(CVPixelBufferRef f : {a,b,gt,raw,ref,output})if(f)CVPixelBufferRelease(f);
    }
    [frc invalidate];
    [p stop]; return @{ @"ok":@(ok && [resources[@"ok"] boolValue]), @"cases":cases, @"renderResources":resources,
        @"nativeFRC":nativeFRC, @"nativeFRCPrepareError":frcError.localizedDescription ?: @"",
        @"scope":@"synthetic 709 NV12 source, actual 2K→1080 Lanczos→VT low latency; sampled pixels and fixed synthetic midpoint, no real content or visible playback" };
}

+ (NSDictionary<NSString *, id> *)runLiveSwitchContract {
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init]; [p adoptSourceGeneration:1];
    __block NSMutableArray *events=[NSMutableArray array];
    p.planHandler=^(NSInteger state, NSString *engine, NSString *model, NSString *reason, uint64_t requestID) {
        [events addObject:@{ @"state":@(state), @"engine":engine, @"model":model, @"reason":reason, @"id":@(requestID) }];
    };
    dispatch_sync(p->_q, ^{ p->_width=640; p->_height=360; });
    SPLivePlanRequest *rife=[[SPLivePlanRequest alloc] init]; rife.requestID=100; rife.interpolationEnabled=YES;
    rife.engineID=@"rife.metal"; rife.modelID=@"rife-v4.26"; rife.qualityID=@"fast"; rife.rateKind=SPLiveRateMultiplier; rife.multiplier=2;
    [p updateRequest:rife]; __block BOOL initial=NO;
    for(int i=0;i<400&&!initial;i++) { usleep(10000); dispatch_sync(p->_q, ^{ initial=p->_resolved.committed && p->_rife!=nil && [p->_resolved.engineID isEqualToString:@"rife.metal"]; }); }
    SPLivePlanRequest *ll=[[SPLivePlanRequest alloc] init]; ll.requestID=102; ll.interpolationEnabled=YES;
    ll.engineID=@"apple.lowlatency"; ll.modelID=@"vt.llfi.temporal.1"; ll.rateKind=SPLiveRateMultiplier; ll.multiplier=2;
    SPLivePlanRequest *bad=[ll copy]; bad.requestID=101; bad.multiplier=3; [p updateRequest:bad];
    dispatch_sync(p->_q,^{}); __block BOOL rejectedRetains=NO;
    dispatch_sync(p->_q, ^{ rejectedRetains=p->_rife!=nil && p->_resolved.committed && [p->_resolved.engineID isEqualToString:@"rife.metal"] && p->_resolved.unavailableReason.length>0; });
    [p updateRequest:ll]; __block BOOL actualLL=NO;
    for(int i=0;i<400&&!actualLL;i++) { usleep(10000); dispatch_sync(p->_q, ^{ actualLL=p->_resolved.committed && p->_lowLatency!=nil && [p->_resolved.engineID isEqualToString:@"apple.lowlatency"]; }); }
    SPLivePlanRequest *old=[ll copy]; old.requestID=103; SPLivePlanRequest *newer=[ll copy]; newer.requestID=104;
    newer.engineID=@"apple.frc"; newer.modelID=@"vt.frc.normal";
    [p updateRequest:old]; [p updateRequest:newer];
    __block BOOL latestFRC=NO;
    for(int i=0;i<400&&!latestFRC;i++) { usleep(10000); dispatch_sync(p->_q, ^{ latestFRC=p->_resolved.committed && p->_engine!=nil && [p->_resolved.engineID isEqualToString:@"apple.frc"]; }); }
    usleep(100000); __block NSArray *captured;
    dispatch_sync(dispatch_get_main_queue(), ^{ captured=[events copy]; });
    BOOL llAck=NO, rejectAck=NO, latestAck=NO, lateOldCommit=NO;
    for(NSDictionary *item in captured) { uint64_t id=[item[@"id"] unsignedLongLongValue]; NSInteger state=[item[@"state"] integerValue];
        if(id==102 && state==2 && [item[@"engine"] isEqual:@"apple.lowlatency"]) llAck=YES;
        if(id==101 && state==0 && [item[@"engine"] isEqual:@"apple.lowlatency"] && [item[@"reason"] length]>0) rejectAck=YES;
        if(id==104 && state==2 && [item[@"engine"] isEqual:@"apple.frc"]) latestAck=YES;
        if(id==103 && state==2) lateOldCommit=YES;
    }
    [p stop]; BOOL ok=initial && actualLL && rejectedRetains && latestFRC && llAck && rejectAck && latestAck && !lateOldCommit;
    return @{ @"ok":@(ok), @"initialRIFE426":@(initial), @"realLLActivated":@(actualLL), @"failureRetainedRIFE":@(rejectedRetains),
        @"newerFRCActive":@(latestFRC), @"correctLLAck":@(llAck), @"correctRejectedAck":@(rejectAck),
        @"correctNewerAck":@(latestAck), @"oldPrepareCommitted":@(lateOldCommit), @"events":captured ?: @[],
        @"scope":@"real processor update/prepare/commit and rejection; no picker, native UI or physical presentation" };
}

+ (NSDictionary<NSString *, id> *)runLowLatencyPrescaleSmoke {
    const int width=2560,height=1440,count=90;
    CVPixelBufferRef frames[4]={};
    for(int i=0;i<4;i++) {
        frames[i]=SPCreateBuffer(width,height,kCVPixelFormatType_32BGRA);
        if(!frames[i]) { for(auto f:frames)if(f)CVPixelBufferRelease(f); return @{ @"ok":@NO, @"error":@"source allocation" }; }
        CVPixelBufferLockBaseAddress(frames[i],0); uint8_t *base=(uint8_t *)CVPixelBufferGetBaseAddress(frames[i]); size_t stride=CVPixelBufferGetBytesPerRow(frames[i]);
        for(int y=0;y<height;y++) for(int x=0;x<width;x++) { uint8_t *px=base+y*stride+x*4; BOOL mark=x>=800+i*4&&x<1040+i*4&&y>=480&&y<720; px[0]=px[1]=px[2]=mark?200:40+i*10;px[3]=255; }
        CVPixelBufferUnlockBaseAddress(frames[i],0); SPForceSDRAttachments(frames[i]);
    }
    VTPixelTransferSessionRef inputTransfer=NULL; VTPixelTransferSessionCreate(kCFAllocatorDefault,&inputTransfer);
    for(int i=0;i<4;i++) {
        CVPixelBufferRef nv=SPCreateBuffer(width,height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        if(!nv || !inputTransfer || VTPixelTransferSessionTransferImage(inputTransfer,frames[i],nv)!=noErr) {
            if(nv)CVPixelBufferRelease(nv); if(inputTransfer)CFRelease(inputTransfer);
            for(auto f:frames)if(f)CVPixelBufferRelease(f); return @{ @"ok":@NO, @"error":@"NV12 conversion" };
        }
        SPForceSDRAttachments(nv); CVPixelBufferRelease(frames[i]); frames[i]=nv;
    }
    if(inputTransfer)CFRelease(inputTransfer);
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init]; [p adoptSourceGeneration:1];
    CVPixelBufferRef sampleFrame=frames[0];
    BOOL forceRealtime=getenv("KHUA_TEST_KEEP_LOW_REALTIME")!=NULL;
    dispatch_sync(p->_q, ^{ p->_width=width; p->_height=height; p->_testCapturePlayout=YES; p->_testKeepLowRealtime=forceRealtime;
        p->_held[999].source=CVPixelBufferRetain(sampleFrame); p->_held[999].pts=sp::spMake(0,1); });
    SPLivePlanRequest *request=[[SPLivePlanRequest alloc] init]; request.requestID=501; request.interpolationEnabled=YES;
    request.engineID=@"apple.lowlatency"; request.modelID=@"vt.llfi.temporal.1"; request.rateKind=SPLiveRateMultiplier;
    request.multiplier=2; request.scaleEnabled=YES; request.scaleEngine=SPLiveScaleLanczos;
    request.outputWidth=1920; request.outputHeight=1080; request.viewMode=SPLiveViewCompare;
    request.captureCapFPS=60; request.displayRefreshHz=120; [p updateRequest:request];
    __block BOOL prepared=NO;
    for(int i=0;i<600&&!prepared;i++) { usleep(10000); dispatch_sync(p->_q, ^{ prepared=p->_sessionReady && p->_lowLatency.width==1920 && p->_lowLatency.height==1080 && p->_resolved.committed; }); }
    if(!prepared) { NSString *reason=p.resolvedPlan.unavailableReason ?: @"prepare timeout"; [p stop]; for(auto f:frames)CVPixelBufferRelease(f); return @{ @"ok":@NO, @"prepared":@NO, @"error":reason }; }
    int64_t start=SPHostNow(),last=start;
    for(int i=0;i<count;i++) { SPWaitUntilHost(start+SPRationalToHost(sp::spMake(i,60))); last=SPHostNow(); [p pushPixelBuffer:frames[i%4] ptsNum:i ptsDen:60 host:last generation:1]; }
    double sourceHz=(count-1)*1e9/(double)SPHostToNs(last-start);
    usleep(700000); __block BOOL sizeOK=NO,ordered=YES,grid=YES,baseline=NO; __block int src=0,syn=0,stableSrc=0,stableSyn=0;
    __block NSDictionary *stats; __block NSArray *pendingTrace; __block NSArray *missingTicks;
    dispatch_sync(p->_q, ^{ const auto &v=p->_testPlayout; for(size_t i=0;i<v.size();i++) { if(v[i].second)syn++;else src++; if(i&&sp::spCmp(v[i-1].first,v[i].first)>=0)ordered=NO;
        __int128 ticks=(__int128)v[i].first.num*120; int64_t den=v[i].first.den; if(den<=0 || ticks%den!=0 || ((ticks/den)&1)!=(v[i].second?1:0))grid=NO; }
        bool present[120]={};
        for(const auto &item:v) { __int128 ticks=(__int128)item.first.num*120; if(item.first.den<=0 || ticks%item.first.den) continue;
            int tick=(int)(ticks/item.first.den); if(tick>=36&&tick<156) { present[tick-36]=true; if(item.second)stableSyn++;else stableSrc++; } }
        NSMutableArray *missing=[NSMutableArray array]; for(int j=0;j<120;j++) if(!present[j]) [missing addObject:@(j+36)]; missingTicks=[missing copy];
        sizeOK=p->_lastEnhanced && CVPixelBufferGetWidth(p->_lastEnhanced)==1920 && CVPixelBufferGetHeight(p->_lastEnhanced)==1080;
        baseline=p->_lastOriginal && CVPixelBufferGetWidth(p->_lastOriginal)==1920 && CVPixelBufferGetHeight(p->_lastOriginal)==1080;
        stats=[p currentStats]; pendingTrace=[p->_testPendingTrace copy] ?: @[]; });
    SPLivePlanRequest *bad=[request copy]; bad.requestID=502; bad.outputWidth=1918; [p updateRequest:bad];
    __block BOOL rejectedRetained=NO;
    for(int i=0;i<600&&!rejectedRetained;i++) { usleep(10000); dispatch_sync(p->_q, ^{ rejectedRetained=p->_resolved.unavailableReason.length>0 && p->_resolved.committed && p->_lowLatency.width==1920; }); }
    __block uint64_t baselineMatches=0, baselineMismatches=0, prescaledInputs=0, noRescale=0;
    dispatch_sync(p->_q, ^{ baselineMatches=p->_testBaselineMatches; baselineMismatches=p->_testBaselineMismatches;
        prescaledInputs=p->_lowPrescaleInputs; noRescale=p->_lowSyntheticNoRescale; });
    [p adoptSourceGeneration:2]; __block BOOL generationClear=NO, staleRejected=NO;
    dispatch_sync(p->_q, ^{ generationClear=p->_sourceGeneration==2 && !p->_lastEnhanced && p->_held.empty();
        SPLiveJob *stale=new SPLiveJob(); stale->generation=1; stale->configVersion=p->_configVersion; stale->count=1; stale->pts[0]=sp::spMake(1,120);
        SPOwnedPixelBuffer *box=[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:CVPixelBufferRetain(sampleFrame)];
        [p finishJob:stale token:0 outputs:@[box] latency:0 error:nil]; staleRejected=!p->_lastEnhanced && p->_held.empty(); });
    [p stop]; __block BOOL stoppedClean=NO; dispatch_sync(p->_q, ^{ stoppedClean=p->_stopped && !p->_lowLatency && p->_held.empty(); });
    for(auto f:frames)CVPixelBufferRelease(f);
    BOOL ok=prepared && sizeOK && baseline && ordered && grid && src>0 && syn>0 && rejectedRetained && generationClear && staleRejected && stoppedClean && baselineMatches>0 && baselineMismatches==0 && prescaledInputs>0 && noRescale>0;
    return @{ @"ok":@(ok), @"prepared":@(prepared), @"sourceSize":@[@2560,@1440], @"sourceFormat":@"NV12 video-range", @"processingSize":@[@1920,@1080],
        @"outputSizeCorrect":@(sizeOK), @"baselineSizeCorrect":@(baseline), @"playoutSources":@(src), @"playoutSynthetic":@(syn),
        @"ptsOrdered":@(ordered), @"ptsOn120Grid":@(grid), @"inputCount":@(count), @"invalidAspectRetainsPlan":@(rejectedRetained), @"sourceGenerationClears":@(generationClear), @"oldGenerationRejected":@(staleRejected), @"stopReleasesEngineAndFrames":@(stoppedClean),
        @"sourceABaselineMatches":@(baselineMatches), @"sourceABaselineMismatches":@(baselineMismatches), @"prescaledInputs":@(prescaledInputs), @"syntheticNoRescale":@(noRescale),
        @"stableIntervalPTS":@"[0.3,1.3)", @"stableSource":@(stableSrc), @"stableSynthetic":@(stableSyn), @"stableExpectedEach":@60, @"stableMissing120Ticks":missingTicks ?: @[],
        @"inputHzObserved":@(sourceHz), @"forcedOriginalRealtimePolicy":@(forceRealtime), @"pendingTrace":pendingTrace,
        @"submitted":stats[@"submitted"] ?: @0, @"modelOutputs":stats[@"syntheticOK"] ?: @0,
        @"queueDrops":stats[@"queueDrops"] ?: @0, @"deadlineDrops":stats[@"deadlineDrops"] ?: @0,
        @"slowMode":stats[@"lowPrescaleSlowMode"] ?: @NO, @"delayClamped":stats[@"delayClamped"] ?: @NO,
        @"frcP95ms":stats[@"frcP95ms"] ?: @0, @"scaleP95ms":stats[@"scaleP95ms"] ?: @0,
        @"transferP95ms":stats[@"transferP95ms"] ?: @0, @"modelReadyP95ms":stats[@"captureToModelReadyP95ms"] ?: @0,
        @"readyP95ms":stats[@"captureToOutputReadyP95ms"] ?: @0,
        @"pendingExpired":stats[@"pendingExpiredDrops"] ?: @0, @"lateReady":stats[@"lateReadyDrops"] ?: @0,
        @"processingOrder":stats[@"lowLatencyProcessingOrder"] ?: @"", @"scope":@"real 2560x1440 controlled source, Lanczos to 1920x1080 then VT low latency; no window or physical FPS" };
}

+ (NSDictionary<NSString *, id> *)runLowLatency120Smoke {
    NSError *error=nil;
    SPLowLatencyEngine *engine=[[SPLowLatencyEngine alloc] init];
    BOOL prepared=[engine prepareWidth:640 height:360 frames:1 error:&error];
    if (!prepared) return @{ @"ok":@NO, @"prepared":@NO, @"error":error.localizedDescription ?: @"low latency unavailable" };
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init]; [p adoptSourceGeneration:1];
    SPLivePlanRequest *request=[[SPLivePlanRequest alloc] init];
    request.interpolationEnabled=YES; request.engineID=@"apple.lowlatency"; request.rateKind=SPLiveRateMultiplier;
    request.multiplier=2; request.captureCapFPS=60; request.displayRefreshHz=120;
    dispatch_sync(p->_q, ^{ p->_width=640; p->_height=360; p->_testCapturePlayout=YES;
        [p installRequest:request lowLatency:engine rife:nil distil:nil appleSR:nil videoSR:nil animeSR:nil cuganSR:nil]; });
    __block BOOL installed=NO; dispatch_sync(p->_q, ^{ installed=p->_sessionReady && p->_resolved.interpolationActive; });
    if (!installed) { [p stop]; return @{ @"ok":@NO, @"prepared":@YES, @"installed":@NO, @"error":p.resolvedPlan.unavailableReason ?: @"install" }; }
    CVPixelBufferRef frames[4]={};
    for (int i=0;i<4;i++) {
        frames[i]=SPCreateBuffer(640,360,kCVPixelFormatType_32BGRA);
        if (!frames[i]) { for (auto f:frames) if(f)CVPixelBufferRelease(f); [p stop]; return @{ @"ok":@NO, @"error":@"frame allocation" }; }
        CVPixelBufferLockBaseAddress(frames[i],0);
        uint8_t *base=(uint8_t *)CVPixelBufferGetBaseAddress(frames[i]); size_t stride=CVPixelBufferGetBytesPerRow(frames[i]);
        for(int y=0;y<360;y++) for(int x=0;x<640;x++) { uint8_t *px=base+y*stride+x*4; BOOL mark=x>=200+i*2&&x<260+i*2&&y>=120&&y<180; px[0]=px[1]=px[2]=mark?200:40;px[3]=255; }
        CVPixelBufferUnlockBaseAddress(frames[i],0); SPForceSDRAttachments(frames[i]);
    }
    const int count=90; int64_t start=SPHostNow();
    for(int i=0;i<count;i++) {
        SPWaitUntilHost(start+SPRationalToHost(sp::spMake(i,60)));
        [p pushPixelBuffer:frames[i%4] ptsNum:i ptsDen:60 host:SPHostNow() generation:1];
    }
    int64_t end=SPHostNow(); usleep(400000);
    __block NSMutableDictionary *report=[NSMutableDictionary dictionary];
    dispatch_sync(p->_q, ^{
        const auto &v=p->_testPlayout; int source=0,synth=0; BOOL valid=YES,ordered=YES;
        for(size_t i=0;i<v.size();i++) { __int128 ticks=(__int128)v[i].first.num*120; int64_t den=v[i].first.den;
            if(den<=0 || ticks%den!=0 || ((ticks/den)&1)!=(v[i].second?1:0)) valid=NO;
            if(i && sp::spCmp(v[i-1].first,v[i].first)>=0)ordered=NO;
            if(v[i].second)synth++; else source++; }
        NSDictionary *stats=[p currentStats];
        [report addEntriesFromDictionary:@{ @"ok":@(p->_submitted>0 && p->_syntheticOK>0 && synth>0 && valid && ordered),
            @"prepared":@YES, @"installed":@YES, @"inputCount":@(count), @"inputHzObserved":@((count-1)*1e9/(double)SPHostToNs(end-start)),
            @"scheduledPhases":@(p->_scheduledSynthetic), @"submittedPairs":@(p->_submitted), @"actualModelOutputs":@(p->_syntheticOK),
            @"modelFailures":@(p->_syntheticFail), @"deadlineDrops":@(p->_deadlineDrops), @"queueDrops":@(p->_queueDrops),
            @"playoutSources":@(source), @"playoutSynthetic":@(synth), @"ptsOn120Grid":@(valid), @"ptsOrdered":@(ordered),
            @"frcP95ms":stats[@"frcP95ms"], @"frcEwmaMs":stats[@"frcEwmaMs"], @"delayMs":stats[@"delayMs"],
            @"delayClamped":stats[@"delayClamped"], @"peakSlots":stats[@"peakSlots"], @"slotCap":stats[@"slotCap"],
            @"scope":@"real low-latency VT engine and live production queue, controlled 640x360 60fps input; no window, drawable or physical FPS" }];
    });
    for(auto f:frames) CVPixelBufferRelease(f); [p stop]; return report;
}

// Deterministic clock inputs, real scheduler and production event handlers;
// no model is submitted here. The existing output-repair smoke remains real.
+ (NSDictionary<NSString *, id> *)runSourceClockSchedulingContract {
    NSMutableArray *rates=[NSMutableArray array]; BOOL allRates=YES;
    for (int multiplier=2; multiplier<=4; ++multiplier) {
        SPLiveProcessor *p=[[SPLiveProcessor alloc] init];
        __block BOOL ordered=NO, phasePTS=NO, updateOnce=NO, beforeWasLate=NO, afterUsesB=NO, duplicateIgnored=NO;
        __block double oldFromB=0, newFromB=0, delayMs=0; __block int phaseCount=0, sourceClockCount=0;
        dispatch_sync(p->_q, ^{
            p->_request.interpolationEnabled=YES; p->_request.engineID=@"apple.frc";
            p->_request.rateKind=SPLiveRateMultiplier; p->_request.multiplier=multiplier;
            p->_testCapturePlayout=YES; [p resetSchedulerOnQueue];
            int64_t aHost=SPHostNow()+SPRationalToHost(sp::spMake(2,1));
            int64_t bHost=aHost+SPRationalToHost(sp::spMake(300,1000));
            p->_held[11].pts=sp::spMake(0,1); p->_held[11].host=aHost;
            p->_held[12].pts=sp::spMake(1,30); p->_held[12].host=bHost;
            sp::SPScheduleInput a; a.identity=11; a.pts=p->_held[11].pts; a.generation=p->_configVersion;
            auto ar=p->_scheduler.push(a); if(ar.reject==sp::SPScheduleReject::None){[p handleAcceptedInput:11 events:ar.events generation:p->_sourceGeneration];}
            sp::SPScheduleInput b; b.identity=12; b.pts=p->_held[12].pts; b.generation=p->_configVersion;
            auto br=p->_scheduler.push(b);
            if(br.reject==sp::SPScheduleReject::None){[p handleAcceptedInput:12 events:br.events generation:p->_sourceGeneration];}
            ordered=ar.reject==sp::SPScheduleReject::None && br.reject==sp::SPScheduleReject::None;
            phasePTS=YES;
            for(const auto &e:br.events) if(e.action==sp::SPScheduleAction::Interpolate) {
                ++phaseCount; sp::SPRational expected=sp::spMake(phaseCount,30*multiplier);
                if(sp::spCmp(e.pts,expected)!=0 || sp::spCmp(e.phase,sp::spMake(phaseCount,multiplier))!=0)phasePTS=NO;
            }
            phasePTS=phasePTS && phaseCount==multiplier-1;
            NSArray *trace=p->_testTimingTrace ?: @[]; NSUInteger traceCount=trace.count; NSDictionary *plan=nil;
            for(NSDictionary *entry in trace){if([entry[@"kind"] isEqual:@"sourceClock"])sourceClockCount++; if([entry[@"kind"] isEqual:@"phasePlan"])plan=entry;}
            double stepMs=1000.0/(30.0*multiplier); delayMs=[plan[@"delayMs"] doubleValue];
            oldFromB=(double)SPHostToNs(aHost+SPRationalToHost(sp::spMake(1,30*multiplier))+p->_delayHost-bHost)/1e6;
            newFromB=[plan[@"deadlineFromSourceMs"] doubleValue];
            beforeWasLate=oldFromB<0; afterUsesB=plan && [plan[@"anchorPtsNum"] longLongValue]==1 && [plan[@"anchorPtsDen"] longLongValue]==30 &&
                fabs(newFromB-(delayMs-(1000.0/30.0-stepMs)))<0.1;
            updateOnce=sourceClockCount==2 && p->_havePreviousSourcePts && sp::spCmp(p->_previousSourcePts,sp::spMake(1,30))==0 &&
                llabs(SPHostToNs(p->_intervalHost)-33333333LL)<1000;
            auto duplicate=p->_scheduler.push(b); [p observeSourceIdentity:12];
            duplicateIgnored=duplicate.reject==sp::SPScheduleReject::DuplicatePTS && p->_testTimingTrace.count==traceCount;
        });
        BOOL ok=ordered&&phasePTS&&updateOnce&&beforeWasLate&&afterUsesB&&duplicateIgnored;
        allRates=allRates&&ok;
        [rates addObject:@{ @"multiplier":@(multiplier), @"ok":@(ok), @"phases":@(phaseCount), @"clockUpdates":@(sourceClockCount),
            @"oldAnchorDeadlineFromBMs":@(oldFromB), @"updatedDeadlineFromBMs":@(newFromB), @"delayMs":@(delayMs),
            @"sourceClockUpdatedOnce":@(updateOnce), @"originalPhasePTS":@(phasePTS), @"duplicateIgnored":@(duplicateIgnored) }];
        [p stop];
    }
    SPLiveProcessor *fixed=[[SPLiveProcessor alloc] init]; __block BOOL holdOK=NO;
    dispatch_sync(fixed->_q, ^{
        fixed->_request.interpolationEnabled=YES; fixed->_request.engineID=@"apple.frc"; fixed->_request.rateKind=SPLiveRateFixedFPS;
        fixed->_request.fpsNumerator=60; fixed->_request.fpsDenominator=1; fixed->_testCapturePlayout=YES; [fixed resetSchedulerOnQueue];
        int64_t base=SPHostNow()+SPRationalToHost(sp::spMake(2,1));
        fixed->_held[21].pts=sp::spMake(0,1); fixed->_held[21].host=base;
        fixed->_held[22].pts=sp::spMake(1,30); fixed->_held[22].host=base+SPRationalToHost(sp::spMake(1,30));
        sp::SPScheduleInput a; a.identity=21; a.pts=sp::spMake(0,1); a.generation=fixed->_configVersion;
        auto ar=fixed->_scheduler.push(a); if(ar.reject==sp::SPScheduleReject::None){[fixed handleAcceptedInput:21 events:ar.events generation:fixed->_sourceGeneration];}
        sp::SPScheduleInput b; b.identity=22; b.pts=sp::spMake(1,30); b.generation=fixed->_configVersion; b.sceneCutBefore=true;
        auto br=fixed->_scheduler.push(b); if(br.reject==sp::SPScheduleReject::None){[fixed handleAcceptedInput:22 events:br.events generation:fixed->_sourceGeneration];}
        int holds=0, clocks=0; for(auto e:br.events) if(e.action==sp::SPScheduleAction::Hold && sp::spCmp(e.pts,sp::spMake(1,60))==0)holds++;
        for(NSDictionary *entry in fixed->_testTimingTrace)if([entry[@"kind"] isEqual:@"sourceClock"])clocks++;
        holdOK=holds==1 && clocks==2 && sp::spCmp(fixed->_previousSourcePts,sp::spMake(1,30))==0 && llabs(SPHostToNs(fixed->_intervalHost)-33333333LL)<1000;
    });
    [fixed stop];
    SPLiveProcessor *stale=[[SPLiveProcessor alloc] init]; __block BOOL retired=NO, lateRejected=NO, recomputedWouldBeFuture=NO, fpsReset=NO, sourceReset=NO;
    CVPixelBufferRef buffer=SPCreateBuffer(32,32,kCVPixelFormatType_32BGRA);
    dispatch_sync(stale->_q, ^{
        stale->_request.interpolationEnabled=YES; stale->_request.engineID=@"apple.frc";
        int64_t base=SPHostNow()+SPRationalToHost(sp::spMake(2,1));
        [stale noteSourceClock:sp::spMake(0,1) host:base];
        int64_t media=(int64_t)(CACurrentMediaTime()*1e9);
        stale->_fpsMeter.presented(0,media-10000000,1,false,false,true);
        stale->_fpsMeter.presented(1,media,2,false,false,true);
        BOOL hadFPS=stale->_fpsMeter.outputRate(media)>0; uint64_t fpsEpoch=stale->_fpsObservationEpoch;
        SPLiveJob *job=new SPLiveJob(); job->configVersion=stale->_configVersion; job->generation=stale->_sourceGeneration;
        job->inflightEpoch=stale->_inflightEpoch; job->clockEpoch=stale->_clockEpoch; job->count=1; job->pts[0]=sp::spMake(1,60);
        [stale noteSourceClock:sp::spMake(1,30) host:base+SPRationalToHost(sp::spMake(300,1000))];
        fpsReset=hadFPS && stale->_fpsMeter.outputRate(media)<0 && stale->_fpsObservationEpoch==fpsEpoch+1;
        SPPendingPhase pending; pending.pts=sp::spMake(1,60); pending.generation=stale->_sourceGeneration; stale->_pending.push_back(pending);
        [stale finishJob:job token:0 outputs:@[] latency:0 error:nil];
        retired=stale->_clockRetiredJobs==1 && stale->_syntheticFail==0 && stale->_pending.size()==1;
        stale->_pending.clear();
        recomputedWouldBeFuture=[stale targetHostForPTS:sp::spMake(1,10)] > SPHostNow();
        if(buffer) [stale enqueueReadyEnhanced:CVPixelBufferRetain(buffer) original:NULL pts:sp::spMake(1,10) synthetic:YES held:NO captureHost:0 generation:stale->_sourceGeneration deadlineHost:SPHostNow()-SPRationalToHost(sp::spMake(50,1000))];
        lateRejected=buffer && recomputedWouldBeFuture && stale->_lateReadyDrops==1 && stale->_slots.empty();
    });
    [stale adoptSourceGeneration:2];
    dispatch_sync(stale->_q, ^{ sourceReset=stale->_sourceGeneration==2 && !stale->_havePreviousSourcePts && !stale->_haveAnchor; });
    [stale stop]; if(buffer)CVPixelBufferRelease(buffer);
    BOOL ok=allRates && holdOK && retired && lateRejected && fpsReset && sourceReset;
    return @{ @"ok":@(ok), @"multipliers":rates, @"fixedFPSHoldUsesRealSourceClock":@(holdOK),
        @"oldClockJobRetiredWithoutTouchingNewPending":@(retired), @"lateFrozenDeadlineRejected":@(lateRejected),
        @"recomputedDeadlineWouldBeFuture":@(recomputedWouldBeFuture), @"fpsWindowResetOnReanchor":@(fpsReset), @"sourceGenerationReset":@(sourceReset),
        @"scope":@"deterministic source clock and actual scheduler/event handler with simulated completion and synthetic buffer; no real inference, capture, window or physical FPS" };
}

// Exercises the real synchronous FRC setup and the production pump. The
// presentation callbacks below are injected metadata, not physical display.
+ (NSDictionary<NSString *, id> *)runSourceSizeLifecycleContract {
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init];
    dispatch_sync(p->_q, ^{
        p->_request.interpolationEnabled=YES; p->_request.engineID=@"apple.frc";
        p->_request.rateKind=SPLiveRateMultiplier; p->_request.multiplier=2;
        p->_request.scaleEnabled=NO; p->_request.viewMode=SPLiveViewEnhanced;
    });
    NSError *error=nil; BOOL prepared=[p installSynchronouslyWidth:320 height:192 error:&error];
    CVPixelBufferRef first=SPCreateBuffer(320,192,kCVPixelFormatType_32BGRA);
    CVPixelBufferRef odd=SPCreateBuffer(321,192,kCVPixelFormatType_32BGRA);
    CVPixelBufferRef changed=SPCreateBuffer(322,192,kCVPixelFormatType_32BGRA);
    if (!prepared || !first || !odd || !changed) {
        if(first)CVPixelBufferRelease(first); if(odd)CVPixelBufferRelease(odd); if(changed)CVPixelBufferRelease(changed);
        [p stop]; return @{ @"ok":@NO, @"prepared":@(prepared), @"error":error.localizedDescription ?: @"synthetic buffer allocation failed" };
    }
    for (CVPixelBufferRef frame : {first,odd,changed}) {
        CVPixelBufferLockBaseAddress(frame,0);
        memset(CVPixelBufferGetBaseAddress(frame),64,CVPixelBufferGetBytesPerRow(frame)*CVPixelBufferGetHeight(frame));
        CVPixelBufferUnlockBaseAddress(frame,0);
    }
    __block SPFRCEngine *initialEngine=nil; __block uint64_t oldConfig=0,oldEpoch=0;
    __block BOOL initialRawUnknown=NO, firstKept=NO, firstGeometry=NO, oddChanged=NO, oddRebuilt=NO;
    __block BOOL staleRejected=NO, freshGeometry=NO, processedSizeChanged=NO;
    __block uint64_t oddConfig=0,oddEpoch=0, finalConfig=0,finalEpoch=0;
    dispatch_sync(p->_q, ^{ initialEngine=p->_engine; oldConfig=p->_configVersion; oldEpoch=p->_measurementEpoch;
        initialRawUnknown=p->_sourceWidth==0 && p->_sourceHeight==0 && initialEngine!=nil && p->_sessionReady; });
    [p pushPixelBuffer:first ptsNum:0 ptsDen:60 host:SPHostNow() generation:1];
    dispatch_sync(p->_q, ^{
        firstKept=p->_sourceWidth==320 && p->_sourceHeight==192 && p->_engine==initialEngine && p->_sessionReady &&
            p->_configVersion==oldConfig && p->_measurementEpoch==oldEpoch;
        p->_marks[9001].fpsEpoch=p->_fpsObservationEpoch;
        [p notePresented:@{ @"counts":@YES, @"generation":@1, @"configVersion":@(oldConfig), @"measurementEpoch":@(oldEpoch),
            @"endpoint":@"preview", @"windowVisible":@YES, @"occluded":@NO, @"exposed":@YES,
            @"presentedTime":@1.0, @"ptsNum":@0, @"ptsDen":@60, @"frameID":@9001, @"synthetic":@NO,
            @"width":@320, @"height":@192, @"drawableWidth":@640, @"drawableHeight":@384 }];
        NSDictionary *chain=[p sizeChainSnapshot];
        firstGeometry=[chain[@"sourceWidth"] intValue]==320 && [chain[@"drawableWidth"] intValue]==640;
    });
    [p pushPixelBuffer:odd ptsNum:1 ptsDen:60 host:SPHostNow() generation:1];
    dispatch_sync(p->_q, ^{
        oddConfig=p->_configVersion; oddEpoch=p->_measurementEpoch;
        oddChanged=p->_sourceWidth==321 && p->_sourceHeight==192 && p->_width==320 && p->_height==192 &&
            oddConfig==oldConfig+1 && oddEpoch==oldEpoch+1;
        oddRebuilt=p->_sessionReady && p->_engine && p->_engine!=initialEngine;
        NSDictionary *before=[p sizeChainSnapshot];
        [p notePresented:@{ @"counts":@YES, @"generation":@1, @"configVersion":@(oldConfig), @"measurementEpoch":@(oldEpoch),
            @"endpoint":@"preview", @"windowVisible":@YES, @"occluded":@NO, @"exposed":@YES,
            @"presentedTime":@2.0, @"ptsNum":@1, @"ptsDen":@60, @"frameID":@9002, @"synthetic":@NO,
            @"width":@320, @"height":@192, @"drawableWidth":@640, @"drawableHeight":@384 }];
        [p notePresented:@{ @"counts":@YES, @"generation":@1, @"configVersion":@(oddConfig), @"measurementEpoch":@(oldEpoch), @"endpoint":@"preview" }];
        [p notePresented:@{ @"counts":@YES, @"generation":@0, @"configVersion":@(oddConfig), @"measurementEpoch":@(oddEpoch), @"endpoint":@"preview" }];
        staleRejected=before.count==0 && [p sizeChainSnapshot].count==0 &&
            [p->_ignoredPresentedCallbacks[@"preview.configuration"] unsignedLongLongValue]>0 &&
            [p->_ignoredPresentedCallbacks[@"preview.epoch"] unsignedLongLongValue]>0 &&
            [p->_ignoredPresentedCallbacks[@"preview.generation"] unsignedLongLongValue]>0;
    });
    // A second genuine buffer gives the new scheduler its normal source pair.
    [p pushPixelBuffer:odd ptsNum:2 ptsDen:60 host:SPHostNow() generation:1];
    dispatch_sync(p->_q, ^{
        p->_marks[9003].fpsEpoch=p->_fpsObservationEpoch;
        [p notePresented:@{ @"counts":@YES, @"generation":@1, @"configVersion":@(oddConfig), @"measurementEpoch":@(oddEpoch),
            @"endpoint":@"preview", @"windowVisible":@YES, @"occluded":@NO, @"exposed":@YES,
            @"presentedTime":@3.0, @"ptsNum":@2, @"ptsDen":@60, @"frameID":@9003, @"synthetic":@NO,
            @"width":@320, @"height":@192, @"drawableWidth":@640, @"drawableHeight":@384 }];
        NSDictionary *chain=[p sizeChainSnapshot];
        freshGeometry=[chain[@"sourceWidth"] intValue]==321 && [chain[@"processingWidth"] intValue]==320 &&
            [chain[@"drawableWidth"] intValue]==640 && [chain[@"configVersion"] unsignedLongLongValue]==oddConfig;
        [p notePresented:@{ @"counts":@YES, @"generation":@1, @"configVersion":@(oldConfig), @"measurementEpoch":@(oldEpoch),
            @"endpoint":@"preview", @"windowVisible":@YES, @"occluded":@NO, @"exposed":@YES,
            @"presentedTime":@4.0, @"ptsNum":@3, @"ptsDen":@60, @"frameID":@9004, @"synthetic":@NO,
            @"width":@320, @"height":@192, @"drawableWidth":@800, @"drawableHeight":@600 }];
        NSDictionary *afterStale=[p sizeChainSnapshot];
        staleRejected=staleRejected && [afterStale[@"sourceWidth"] intValue]==321 && [afterStale[@"drawableWidth"] intValue]==640;
    });
    [p pushPixelBuffer:changed ptsNum:3 ptsDen:60 host:SPHostNow() generation:1];
    dispatch_sync(p->_q, ^{ finalConfig=p->_configVersion; finalEpoch=p->_measurementEpoch;
        processedSizeChanged=p->_sourceWidth==322 && p->_width==322 && finalConfig==oddConfig+1 && finalEpoch==oddEpoch+1 && p->_sessionReady && p->_engine!=nil; });
    [p stop]; CVPixelBufferRelease(first); CVPixelBufferRelease(odd); CVPixelBufferRelease(changed);
    BOOL ok=initialRawUnknown && firstKept && firstGeometry && oddChanged && oddRebuilt && staleRejected && freshGeometry && processedSizeChanged;
    return @{ @"ok":@(ok), @"prepared":@(prepared), @"initialRawUnknown":@(initialRawUnknown), @"firstMatchingInputKeptEngineAndEpoch":@(firstKept),
        @"initialGeometryCallbackAccepted":@(firstGeometry), @"oddRawChangeSameProcessingSizeIsolated":@(oddChanged), @"oddChangeRebuiltEngine":@(oddRebuilt),
        @"staleCallbackDidNotPolluteSizeChain":@(staleRejected), @"freshCallbackUsesNewRawSize":@(freshGeometry), @"processedSizeChangeIsolated":@(processedSizeChanged),
        @"initialConfig":@(oldConfig), @"initialEpoch":@(oldEpoch), @"oddConfig":@(oddConfig), @"oddEpoch":@(oddEpoch), @"finalConfig":@(finalConfig), @"finalEpoch":@(finalEpoch),
        @"scope":@"real FRC engine setup and production pump with 320x192, 321x192 and 322x192 synthetic BGRA buffers; injected presentation metadata, no window or physical display" };
}

+ (NSDictionary<NSString *, id> *)runOutputRepairContractWithBundle:(NSBundle *)bundle {
    // A real GPU command and a real RIFE inference, but no drawable/window.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:8 height:8 mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    [[cmd renderCommandEncoderWithDescriptor:pass] endEncoding];
    [cmd commit]; [cmd waitUntilCompleted];
    BOOL gpuOK = cmd.status == MTLCommandBufferStatusCompleted;
    SPLiveProcessor *p = [[SPLiveProcessor alloc] init];
    __block SPLivePreviewView *output = nil;
    auto reveals = std::make_shared<std::atomic<int>>(0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        output = [[SPLivePreviewView alloc] initWithFrame:NSMakeRect(0,0,320,192)];
        p.outputPreview = output;
        p.outputSurfaceHandler = ^(uint64_t generation, uint64_t config, uint64_t token) {
            if (generation == 1 && config == 7 && token == 42) reveals->fetch_add(1);
        };
        [p installPresentationHooks];
    });
    dispatch_sync(p->_q, ^{ p->_sourceGeneration=1; p->_configVersion=7; p->_measurementEpoch=9;
        p->_resolved.committed=YES; p->_resolved.scaleActive=YES; });
    [p awaitOutputSurfaceWithToken:42];
    dispatch_sync(p->_q, ^{});
    NSDictionary *(^readyInfo)(uint64_t,uint64_t,uint64_t,uint64_t,BOOL,BOOL) = ^NSDictionary *(uint64_t generation,uint64_t config,uint64_t epoch,uint64_t token,BOOL ok,BOOL visible) {
        return @{ @"generation":@(generation), @"configVersion":@(config), @"measurementEpoch":@(epoch),
            @"surfaceToken":@(token), @"counts":@YES, @"windowVisible":@(visible), @"gpuCompleted":@(ok) };
    };
    output.surfaceReady(readyInfo(0,7,9,42,YES,YES));
    output.surfaceReady(readyInfo(1,6,9,42,YES,YES));
    output.surfaceReady(readyInfo(1,7,8,42,YES,YES));
    output.surfaceReady(readyInfo(1,7,9,41,YES,YES));
    output.surfaceReady(readyInfo(1,7,9,42,NO,YES));
    output.surfaceReady(readyInfo(1,7,9,42,YES,NO));
    dispatch_sync(p->_q, ^{});
    BOOL rejectsStale = reveals->load()==0;
    output.surfaceReady(readyInfo(1,7,9,42,gpuOK,YES));
    for (int i=0;i<100 && reveals->load()==0;i++) usleep(10000);
    BOOL readyOnce = reveals->load()==1;
    output.surfaceReady(readyInfo(1,7,9,42,gpuOK,YES));
    dispatch_sync(p->_q, ^{});
    usleep(20000);
    readyOnce = readyOnce && reveals->load()==1;
    dispatch_sync(p->_q, ^{ for (uint64_t id : {91ull,92ull,93ull}) p->_marks[id].fpsEpoch=p->_fpsObservationEpoch; });
    NSDictionary *(^presentInfo)(uint64_t,BOOL) = ^NSDictionary *(uint64_t id,BOOL exposed) {
        return @{ @"generation":@1, @"configVersion":@7, @"measurementEpoch":@9,
            @"counts":@YES, @"windowVisible":@YES, @"occluded":@NO, @"exposed":@(exposed),
            @"presentedTime":@1.0, @"ptsNum":@10, @"ptsDen":@1, @"frameID":@(id), @"synthetic":@YES };
    };
    output.presented(presentInfo(91,NO));
    dispatch_sync(p->_q, ^{});
    __block BOOL physicalGate=NO;
    dispatch_sync(p->_q, ^{ physicalGate=p->_epochPhysicalSynthetic==0; });
    output.presented(presentInfo(92,YES)); output.presented(presentInfo(93,YES));
    dispatch_sync(p->_q, ^{ physicalGate=physicalGate && p->_epochPhysicalSynthetic==1; });

    NSError *error=nil;
    SPRifeBridge *rife = [[SPRifeBridge alloc] initWithResourceBundle:bundle];
    int64_t rifePrepareStart=SPHostNow();
    BOOL prepared = [rife prepareModelID:@"rife-v4.26" quality:@"fast" width:320 height:192 error:&error];
    double rifePrepareMs=(double)SPHostToNs(SPHostNow()-rifePrepareStart)/1e6;
    SPSpatialScaler *scaler = [[SPSpatialScaler alloc] initWithDevice:device inputW:320 inputH:192 outputW:640 outputH:384 engine:SPLiveScaleLanczos error:&error];
    CVPixelBufferRef frame = SPCreateBuffer(320,192,kCVPixelFormatType_32BGRA);
    if (!prepared || !scaler || !frame) { [p stop]; if(frame) CVPixelBufferRelease(frame); return @{ @"ok":@NO, @"reason":error.localizedDescription ?: @"prepare" }; }
    CVPixelBufferLockBaseAddress(frame,0);
    memset(CVPixelBufferGetBaseAddress(frame), 64, CVPixelBufferGetBytesPerRow(frame)*192);
    CVPixelBufferUnlockBaseAddress(frame,0);
    __block BOOL sourceHeld=NO, bounded=NO, latestPair=NO;
    int64_t past=SPHostNow()-SPRationalToHost(sp::spMake(1,1));
    dispatch_sync(p->_q, ^{
        p->_rife=rife; p->_scaler=scaler; p->_request.interpolationEnabled=YES;
        p->_request.engineID=@"rife.metal"; p->_request.scaleEnabled=YES;
        p->_rifeSlowMode=YES;
        p->_sessionReady=YES; p->_resolved.interpolationActive=YES; p->_resolved.scaleActive=YES;
        for (int i=0;i<4;i++) { p->_held[11+i].source=CVPixelBufferRetain(frame); p->_held[11+i].pts=sp::spMake(300+i,30); p->_held[11+i].host=past; }
        [p enqueueSourceIdentity:11 pts:sp::spMake(10,1) host:past generation:1 force:NO];
        sp::SPScheduleOutput a; a.action=sp::SPScheduleAction::Interpolate; a.frameA=11; a.frameB=12; a.pts=sp::spMake(601,60); a.phase=sp::spMake(1,2);
        [p submitEventGroup:{a} generation:1];
        [p enqueueSourceIdentity:12 pts:sp::spMake(301,30) host:past generation:1 force:NO];
        sourceHeld=p->_lastEnhanced && sp::spCmp(p->_lastRedrawPts,sp::spMake(10,1))==0;
        auto b=a; b.frameA=12; b.frameB=13; b.pts=sp::spMake(603,60); [p submitEventGroup:{b} generation:1];
        auto c=a; c.frameA=13; c.frameB=14; c.pts=sp::spMake(605,60); [p submitEventGroup:{c} generation:1];
        bounded=p->_inflight==1 && p->_rifePending.size()==1;
        latestPair=bounded && p->_rifePending.front().frameA==13 && p->_rifePending.front().frameB==14;
    });
    __block BOOL actualOutput=NO, correctSize=NO;
    for(int i=0;i<500 && !actualOutput;i++) { usleep(10000); dispatch_sync(p->_q, ^{
        actualOutput=p->_syntheticOK>=2 && p->_lastSynthetic && sp::spCmp(p->_lastRedrawPts,sp::spMake(605,60))==0;
        correctSize=p->_lastEnhanced && CVPixelBufferGetWidth(p->_lastEnhanced)==640 && CVPixelBufferGetHeight(p->_lastEnhanced)==384;
    }); }
    // Fast-mode scheduling must retain source, midpoint and next source in
    // their actual PTS order; no drawable or physical-FPS claim is made here.
    SPLiveProcessor *fast=[[SPLiveProcessor alloc] init];
    __block int64_t fastSourceStart=0; NSMutableArray *fastInputTrace=[NSMutableArray array];
    dispatch_sync(fast->_q, ^{
        fast->_sourceGeneration=1; fast->_configVersion=1; fast->_request.interpolationEnabled=YES;
        fast->_request.engineID=@"rife.metal"; fast->_request.rateKind=SPLiveRateMultiplier; fast->_request.multiplier=2;
        fast->_rifeSlowMode=NO; fast->_testCapturePlayout=YES;
        fast->_rife=rife; fast->_sessionReady=YES; fast->_resolved.interpolationActive=YES;
        int64_t now=SPHostNow(); fastSourceStart=now;
        fast->_held[31].source=CVPixelBufferRetain(frame); fast->_held[31].pts=sp::spMake(10,1); fast->_held[31].host=now;
        fast->_held[32].source=CVPixelBufferRetain(frame); fast->_held[32].pts=sp::spMake(301,30); fast->_held[32].host=now+SPRationalToHost(sp::spMake(1,30));
        fast->_haveAnchor=YES; fast->_anchorPts=sp::spMake(10,1);
        fast->_anchorHost=now;
        fast->_haveInterval=YES; fast->_intervalHost=SPRationalToHost(sp::spMake(1,30));
        fast->_frcEwmaSec=0.001; fast->_scaleEwmaSec=0.001; fast->_delayHost=SPRationalToHost(sp::spMake(9,100));
        [fast enqueueSourceIdentity:31 pts:sp::spMake(10,1) host:now generation:1 force:NO];
    });
    // The second source arrives at the actual 30 fps interval; a future
    // captured frame must not be delivered to the processor early.
    usleep(33333);
    int64_t fastBHost=SPHostNow();
    dispatch_sync(fast->_q, ^{
        fast->_held[32].host=fastBHost;
        [fastInputTrace addObject:@{ @"frame":@1, @"actualFromStartMs":@((double)SPHostToNs(fastBHost-fastSourceStart)/1e6),
            @"plannedFromStartMs":@(1000.0/30.0), @"dispatchWaitMs":@((double)SPHostToNs(SPHostNow()-fastBHost)/1e6) }];
        sp::SPScheduleOutput midpoint; midpoint.action=sp::SPScheduleAction::Interpolate; midpoint.frameA=31; midpoint.frameB=32;
        midpoint.pts=sp::spMake(601,60); midpoint.phase=sp::spMake(1,2);
        [fast submitEventGroup:{midpoint} generation:1];
        [fast enqueueSourceIdentity:32 pts:sp::spMake(301,30) host:fast->_held[32].host generation:1 force:NO];
    });
    for (int step=1;step<=4;step++) {
        usleep(33333);
        int64_t inputHost=SPHostNow();
        dispatch_sync(fast->_q, ^{
            uint64_t a=31+step, b=32+step;
            int64_t now=inputHost;
            [fastInputTrace addObject:@{ @"frame":@(step+1), @"actualFromStartMs":@((double)SPHostToNs(now-fastSourceStart)/1e6),
                @"plannedFromStartMs":@((step+1)*1000.0/30.0), @"dispatchWaitMs":@((double)SPHostToNs(SPHostNow()-inputHost)/1e6) }];
            fast->_held[b].source=CVPixelBufferRetain(frame);
            fast->_held[b].pts=sp::spMake(301+step,30); fast->_held[b].host=now;
            sp::SPScheduleOutput midpoint; midpoint.action=sp::SPScheduleAction::Interpolate; midpoint.frameA=a; midpoint.frameB=b;
            midpoint.pts=sp::spMake(601+step*2,60); midpoint.phase=sp::spMake(1,2);
            [fast submitEventGroup:{midpoint} generation:1];
            [fast enqueueSourceIdentity:b pts:sp::spMake(301+step,30) host:now generation:1 force:NO];
        });
    }
    usleep(300000);
    __block BOOL fastOrder=NO;
    __block NSMutableArray *fastTrace=[NSMutableArray array];
    __block double fastModelEwma=0; __block BOOL fastClamped=NO, fastSlowMode=NO;
    __block NSArray *fastTimingTrace=@[], *fastPendingTrace=@[];
    for(int i=0;i<100 && !fastOrder;i++) { usleep(10000); dispatch_sync(fast->_q, ^{
        const auto &v=fast->_testPlayout;
        fastModelEwma=fast->_frcEwmaSec; fastClamped=fast->_delayClamped; fastSlowMode=fast->_rifeSlowMode;
        fastTimingTrace=[fast->_testTimingTrace copy] ?: @[]; fastPendingTrace=[fast->_testPendingTrace copy] ?: @[];
        [fastTrace removeAllObjects];
        for (const auto &item : v) [fastTrace addObject:@{ @"num":@(item.first.num), @"den":@(item.first.den), @"synthetic":@(item.second) }];
        int sources=0, synthetic=0; bool ordered=true;
        for(size_t j=0;j<v.size();j++) { if(v[j].second) synthetic++; else sources++;
            if(j && sp::spCmp(v[j-1].first,v[j].first)>=0) ordered=false; }
        fastOrder=ordered && sources>=2 && synthetic>=2 && !fast->_rifeSlowMode && fast->_syntheticOK>=2;
    }); }
    __block BOOL clampedEntersSlow=NO;
    dispatch_sync(fast->_q, ^{
        SPLiveJob *late=new SPLiveJob(); late->generation=1; late->configVersion=1; late->inflightEpoch=0;
        late->count=1; late->pts[0]=sp::spMake(700,60); late->clockEpoch=fast->_clockEpoch; fast->_frcEwmaSec=0.08;
        SPOwnedPixelBuffer *box=[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:CVPixelBufferRetain(frame)];
        [fast finishJob:late token:0 outputs:@[box] latency:0.5 error:nil];
        clampedEntersSlow=fast->_delayClamped && fast->_rifeSlowMode;
    });
    [fast stop];
    [p adoptSourceGeneration:2];
    __block BOOL staleJobRejected=NO;
    dispatch_sync(p->_q, ^{
        SPLiveJob *stale=new SPLiveJob(); stale->generation=1; stale->configVersion=7; stale->inflightEpoch=0;
        stale->count=1; stale->pts[0]=sp::spMake(607,60);
        p->_rifeSlowMode=NO; p->_frcEwmaSec=0.01;
        size_t previousSamples=p->_frcNs.size();
        SPPendingPhase current; current.pts=stale->pts[0]; current.generation=2; p->_pending.push_back(current);
        SPOwnedPixelBuffer *box=[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:CVPixelBufferRetain(frame)];
        [p finishJob:stale token:0 outputs:@[box] latency:0.7 error:nil];
        staleJobRejected=p->_sourceGeneration==2 && !p->_lastEnhanced && p->_rifePending.empty() &&
            !p->_rifeSlowMode && p->_frcEwmaSec==0.01 && p->_frcNs.size()==previousSamples && p->_pending.size()==1;
    });
    SPLiveProcessor *frc=[[SPLiveProcessor alloc] init];
    dispatch_sync(frc->_q, ^{ frc->_request.interpolationEnabled=YES; frc->_request.engineID=@"apple.frc";
        frc->_request.rateKind=SPLiveRateMultiplier; frc->_request.multiplier=2; frc->_request.fpsNumerator=60; frc->_request.fpsDenominator=1;
        frc->_request.captureCapFPS=60; frc->_request.displayRefreshHz=120; frc->_sourceGeneration=1; frc->_testCapturePlayout=YES; });
    NSError *frcError=nil;
    int64_t frcPrepareStart=SPHostNow();
    BOOL frcPrepared=[frc installSynchronouslyWidth:320 height:192 error:&frcError];
    double frcPrepareMs=(double)SPHostToNs(SPHostNow()-frcPrepareStart)/1e6;
    int64_t frcStart=SPHostNow(), frcLast=frcStart;
    NSMutableArray *frcInputTrace=[NSMutableArray array];
    if (frcPrepared) for(int i=0;i<30;i++) {
        int64_t planned=frcStart+SPRationalToHost(sp::spMake(i,60));
        SPWaitUntilHost(planned);
        frcLast=SPHostNow();
        [frc pushPixelBuffer:frame ptsNum:i ptsDen:60 host:frcLast generation:1];
        int64_t pushed=SPHostNow();
        [frcInputTrace addObject:@{ @"frame":@(i), @"plannedFromStartMs":@((double)SPHostToNs(planned-frcStart)/1e6),
            @"actualFromStartMs":@((double)SPHostToNs(frcLast-frcStart)/1e6), @"pushDurationMs":@((double)SPHostToNs(pushed-frcLast)/1e6) }];
    }
    usleep(300000);
    __block int frcSources=0,frcSynthetic=0; __block BOOL frcOrdered=YES, frcRateIdentity=NO, frcMidpoints=YES;
    __block NSDictionary *frcDiagnostics=@{};
    dispatch_sync(frc->_q, ^{
        const auto &v=frc->_testPlayout;
        for(size_t i=0;i<v.size();i++) { if(v[i].second) {
                frcSynthetic++; __int128 ticks=(__int128)v[i].first.num*120;
                if(v[i].first.den<=0 || ticks%v[i].first.den!=0 || ((ticks/v[i].first.den)&1)==0) frcMidpoints=NO;
            } else frcSources++;
            if(i && sp::spCmp(v[i-1].first,v[i].first)>=0) frcOrdered=NO; }
        NSDictionary *stats=[frc currentStats];
        frcRateIdentity=[stats[@"rateKind"] isEqual:@"multiplier"] && [stats[@"rateMultiplier"] intValue]==2 &&
            [stats[@"captureCapFPS"] intValue]==60 && [stats[@"displayRefreshHz"] intValue]==120;
        frcDiagnostics=@{ @"inputHzObserved":@((29)*1e9/(double)SPHostToNs(frcLast-frcStart)), @"scheduled":stats[@"scheduledSynthetic"], @"submitted":stats[@"submitted"],
            @"modelOutputs":stats[@"syntheticOK"], @"modelFailures":stats[@"syntheticFail"],
            @"engineUnavailableDropsLifetime":stats[@"engineUnavailableDropsLifetime"], @"inflightLimitDropsLifetime":stats[@"inflightLimitDropsLifetime"],
            @"engineSubmissionRejectedDropsLifetime":stats[@"engineSubmissionRejectedDropsLifetime"],
            @"clockRetiredJobsLifetime":stats[@"clockRetiredJobsLifetime"], @"clockRetiredModelOutputsLifetime":stats[@"clockRetiredModelOutputsLifetime"],
            @"clockRetiredPhaseDropsLifetime":stats[@"clockRetiredPhaseDropsLifetime"],
            @"deadlineDrops":stats[@"deadlineDrops"], @"queueDrops":stats[@"queueDrops"],
            @"delayClamped":stats[@"delayClamped"], @"frcP95ms":stats[@"frcP95ms"],
            @"frcEwmaMs":stats[@"frcEwmaMs"], @"delayMs":stats[@"delayMs"],
            @"lateReadyDrops":stats[@"lateReadyDrops"], @"staleReadyDrops":stats[@"staleReadyDrops"],
            @"dueMergeDrops":stats[@"dueMergeDrops"], @"pendingExpiredDrops":stats[@"pendingExpiredDrops"],
            @"slotEvictionDrops":stats[@"slotEvictionDrops"], @"captureToModelReadyP95ms":stats[@"captureToModelReadyP95ms"],
            @"captureToOutputReadyP95ms":stats[@"captureToOutputReadyP95ms"], @"transferP95ms":stats[@"transferP95ms"],
            @"pendingTrace":frc->_testPendingTrace ?: @[], @"timingTrace":frc->_testTimingTrace ?: @[],
            @"initialPrepareMs":@(frcPrepareMs), @"inputTrace":frcInputTrace, @"scope":@"FRC 320x192 real buffers, setup and monotonic host clock instrumentation; not physical display",
            @"peakSlots":stats[@"peakSlots"], @"slotCap":stats[@"slotCap"] };
    });
    [frc stop]; CVPixelBufferRelease(frame); [p stop];
    BOOL frcSmoke=frcPrepared && frcSources>0 && frcSynthetic>0 && frcOrdered && frcRateIdentity && frcMidpoints;
    SPLiveProcessor *rateCheck=[[SPLiveProcessor alloc] init]; __block BOOL activeTarget=NO;
    dispatch_sync(rateCheck->_q, ^{
        auto *q=rateCheck; int64_t now=(int64_t)(CACurrentMediaTime()*1e9);
        q->_request.interpolationEnabled=YES; q->_request.rateKind=SPLiveRateMultiplier; q->_request.multiplier=2;
        q->_request.captureCapFPS=30; q->_request.displayRefreshHz=60;
        q->_fpsMeter.input(0,now-17000000); q->_fpsMeter.input(16666667,now-1);
        q->_resolved.committed=NO; q->_resolved.interpolationActive=YES;
        BOOL pendingHidden=[[q currentStats][@"estimatedRequestedFPS"] doubleValue] < 0;
        q->_resolved.committed=YES;
        double x2=[[q currentStats][@"estimatedRequestedFPS"] doubleValue];
        q->_request.rateKind=SPLiveRateFixedFPS; q->_request.fpsNumerator=60; q->_request.fpsDenominator=1;
        double fixed=[[q currentStats][@"estimatedRequestedFPS"] doubleValue];
        activeTarget=pendingHidden && x2>119 && x2<121 && fixed==60;
    });
    [rateCheck stop];
    BOOL ok=gpuOK && rejectsStale && readyOnce && physicalGate && prepared && sourceHeld && bounded && latestPair && actualOutput && correctSize && fastOrder && staleJobRejected && clampedEntersSlow && frcSmoke && activeTarget;
    return @{ @"ok":@(ok), @"gpuCommandCompleted":@(gpuOK), @"warmupStaleFailedHiddenRejected":@(rejectsStale),
        @"warmupAcceptedOnce":@(readyOnce), @"physicalFPSExcludesWarmAndDuplicates":@(physicalGate), @"realRifePrepared":@(prepared), @"sourceHeld":@(sourceHeld),
        @"oneInflightOnePending":@(bounded), @"latestPair":@(latestPair), @"actualRifeLateOutputPTS":@(actualOutput),
        @"lanczosOutputSize":@(correctSize), @"fast30to60OrderedSourceAndSynthetic":@(fastOrder), @"fastPlayout":fastTrace,
        @"fastModelEwmaMs":@(fastModelEwma*1000), @"fastDelayClamped":@(fastClamped), @"fastSlowMode":@(fastSlowMode),
        @"fastDiagnostics":@{ @"rifePrepareMs":@(rifePrepareMs), @"input":@"same synthetic 320x192 BGRA frame; manually submitted source and midpoint events at 30 fps", @"manualAnchor":@YES,
            @"pendingTrace":fastPendingTrace, @"timingTrace":fastTimingTrace, @"inputTrace":fastInputTrace, @"scope":@"test-only instrumentation; RIFE inference and scheduling, no physical display" },
        @"budgetClampEntersSlow":@(clampedEntersSlow), @"staleGenerationJobRejected":@(staleJobRejected),
        @"frc60to120ProductionSmoke":@(frcSmoke), @"frcSourceOutputs":@(frcSources), @"frcSyntheticOutputs":@(frcSynthetic), @"frcMidpointsOn120Grid":@(frcMidpoints), @"frcDiagnostics":frcDiagnostics, @"frcError":frcError.localizedDescription ?: @"", @"activeTargetExcludesPendingAndCap":@(activeTarget),
        @"scope":@"offscreen GPU command, simulated warmup callback metadata, fast production queue and real slow RIFE/Lanczos scheduling; no window, drawable, physical presentation or GUI" };
}

+ (NSDictionary<NSString *, id> *)runEngineProbe {
    @autoreleasepool {
        NSDictionary *low = [SPLowLatencyEngine probePhases];
        NSDictionary *rife = [SPRifeBridge probe];
        NSDictionary *frcPTS = [self runFRCPTSProbe];
        NSDictionary *appleLowSR = [self runAppleLowSRProbe];
        BOOL lowOK = [low[@"ok"] boolValue];
        BOOL rifeOK = [rife[@"ok"] boolValue];
        BOOL frcOK = [frcPTS[@"processed"] boolValue] && [frcPTS[@"duplicatePTSRejected"] boolValue] && [frcPTS[@"fileMidpointProcessed"] boolValue];
        NSMutableDictionary *report = [@{
            @"ok": @(lowOK && rifeOK && frcOK),
            @"lowLatency": low ?: @{},
            @"rife": rife ?: @{},
            @"frcPTS": frcPTS ?: @{},
        } mutableCopy];
        BOOL srOK = ![appleLowSR[@"candidateSupported"] boolValue] || [appleLowSR[@"processed"] boolValue];
        report[@"ok"] = @(lowOK && rifeOK && frcOK && srOK);
        report[@"appleLowSR"] = appleLowSR ?: @{};
        return report;
    }
}

+ (NSDictionary<NSString *, id> *)runAnimationPipelineContract:(SPLiveScaleEngine)engine variant:(NSString *)variant {
    SPLiveProcessor *p=[[SPLiveProcessor alloc] init];
    int width=engine==SPLiveScaleRealCUGAN?240:160, height=engine==SPLiveScaleRealCUGAN?128:96;
    CVPixelBufferRef input=SPCreateBuffer(width,height,kCVPixelFormatType_32BGRA);
    if(!input)return @{ @"ok":@NO, @"reason":@"source allocation" };
    CVPixelBufferLockBaseAddress(input,0);
    uint8_t *base=(uint8_t *)CVPixelBufferGetBaseAddress(input);size_t pitch=CVPixelBufferGetBytesPerRow(input);
    for(int y=0;y<height;y++)for(int x=0;x<width;x++){uint8_t *pixel=base+y*pitch+x*4;uint8_t v=((x/9+y/9)%2)?220:30;pixel[0]=pixel[1]=pixel[2]=v;pixel[3]=255;}
    CVPixelBufferUnlockBaseAddress(input,0);
    [p adoptSourceGeneration:1];dispatch_sync(p->_q,^{p->_width=width;p->_height=height;});
    SPLivePlanRequest *request=[[SPLivePlanRequest alloc] init];request.scaleEnabled=YES;request.scaleEngine=engine;request.scaleQualityID=variant;request.outputWidth=0;request.outputHeight=0;request.viewMode=SPLiveViewCompare;
    [p updateRequest:request];__block BOOL ready=NO;
    for(int i=0;i<400&&!ready;i++){usleep(50000);dispatch_sync(p->_q,^{ready=p->_sessionReady&&(engine==SPLiveScaleAnime4K ? p->_animeSR!=nil : p->_cuganSR!=nil)&&p->_resolved.scaleActive&&p->_resolved.outputWidth==width*2&&p->_resolved.outputHeight==height*2;});}
    if(!ready){CVPixelBufferRelease(input);NSDictionary *stats=[p stats];[p stop];return @{ @"ok":@NO,@"reason":@"animation scale prepare",@"stats":stats };}
    // The source and a simulated interpolated frame both take the real shader
    // path. Its target is deliberately in the past: slow-mode output must
    // still be presented rather than discarded by the interactive deadline.
    int64_t past=SPHostNow()-SPRationalToHost(sp::spMake(1,1));
    dispatch_sync(p->_q,^{
        p->_held[11].source=CVPixelBufferRetain(input);p->_held[11].host=past;p->_held[11].pts=sp::spMake(10,1);
        [p enqueueSourceIdentity:11 pts:sp::spMake(10,1) host:past generation:1 force:NO];
    });
    __block BOOL sourceOutput=NO,compare=NO,content=NO;
    for(int i=0;i<400&&!sourceOutput;i++){usleep(50000);dispatch_sync(p->_q,^{sourceOutput=p->_lastEnhanced&&CVPixelBufferGetWidth(p->_lastEnhanced)==width*2&&CVPixelBufferGetHeight(p->_lastEnhanced)==height*2&&sp::spCmp(p->_lastRedrawPts,sp::spMake(10,1))==0;compare=p->_lastOriginal&&CVPixelBufferGetWidth(p->_lastOriginal)==width*2;if(sourceOutput)content=SPWhiteCenterX(p->_lastEnhanced)>=0;});}
    dispatch_sync(p->_q,^{
        SPLiveJob *job=new SPLiveJob();job->configVersion=p->_configVersion;job->generation=1;job->inflightEpoch=p->_inflightEpoch;job->clockEpoch=p->_clockEpoch;job->captureHost=past;job->frameA=11;job->count=1;job->pts[0]=sp::spMake(601,60);
        SPOwnedPixelBuffer *box=[[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:CVPixelBufferRetain(input)];[p finishJob:job token:1 outputs:@[box] latency:0 error:nil];
    });
    __block BOOL syntheticOutput=NO;
    for(int i=0;i<400&&!syntheticOutput;i++){usleep(50000);dispatch_sync(p->_q,^{syntheticOutput=p->_lastSynthetic&&p->_lastEnhanced&&sp::spCmp(p->_lastRedrawPts,sp::spMake(601,60))==0;});}
    __block BOOL bounded=YES,latest=YES,replacementCounted=YES;
    if(engine==SPLiveScaleAnime4K || [variant isEqualToString:@"none"]) {
        __block uint64_t before=0;
        dispatch_sync(p->_q,^{
            before=p->_queueDrops;
            for(int i=0;i<6;i++){
                CVPixelBufferRef baseline=[p scaleBuffer:input with:p->_baselineScaler];
                [p enqueueAsyncScale:CVPixelBufferRetain(input) original:baseline pts:sp::spMake(330+i,30) synthetic:NO held:NO captureHost:past generation:1 deadlineHost:0];
            }
            // An older interpolation completion must not replace a newer
            // queued source just because it arrived later on the queue.
            CVPixelBufferRef olderBaseline=[p scaleBuffer:input with:p->_baselineScaler];
            [p enqueueAsyncScale:CVPixelBufferRetain(input) original:olderBaseline pts:sp::spMake(331,30) synthetic:YES held:NO captureHost:past generation:1 deadlineHost:0];
            bounded=p->_srPending.size()<=1 && !p->_srPending.empty() && sp::spCmp(p->_srPending.front()->pts,sp::spMake(335,30))==0;
            replacementCounted=p->_queueDrops>=before+5;
        });
        latest=NO;
        for(int i=0;i<400&&!latest;i++){usleep(50000);dispatch_sync(p->_q,^{latest=p->_lastEnhanced&&sp::spCmp(p->_lastRedrawPts,sp::spMake(335,30))==0;});}
    }
    CVPixelBufferRelease(input);[p stop];
    return @{ @"ok":@(ready&&sourceOutput&&syntheticOutput&&bounded&&compare&&content&&latest&&replacementCounted),@"prepared":@(ready),@"sourceOutput":@(sourceOutput),@"nonblankContent":@(content),@"syntheticOutputAfterDeadline":@(syntheticOutput),@"pendingAtMostOne":@(bounded),@"newestPresented":@(latest),@"replacementsCounted":@(replacementCounted),@"compareBaseline":@(compare),@"note":@"Synthetic source and simulated interpolation only; real capture, actual model combination, saved UI config, color and performance unverified." };
}

+ (NSDictionary<NSString *, id> *)runAnime4KPipelineContract { return [self runAnimationPipelineContract:SPLiveScaleAnime4K variant:@"none"]; }
+ (NSDictionary<NSString *, id> *)runRealCUGANPipelineContract {
    NSMutableDictionary *variants=[NSMutableDictionary dictionary];BOOL ok=YES;
    for(NSString *name in @[@"none",@"light",@"medium",@"strong"]) {
        NSDictionary *result=[self runAnimationPipelineContract:SPLiveScaleRealCUGAN variant:name];variants[name]=result;ok=ok&&[result[@"ok"] boolValue];
    }
    return @{ @"ok":@(ok),@"variants":variants,@"note":@"All four models were called on a synthetic 240×128 source, including tiled processing; real sources, quality and UI persistence remain unverified." };
}

+ (NSDictionary<NSString *, id> *)runVideoSRPipelineContract {
    SPLiveProcessor *p = [[SPLiveProcessor alloc] init];
    CVPixelBufferRef input = SPCreateBuffer(480, 270, kCVPixelFormatType_32BGRA);
    if (!input) return @{ @"ok": @NO, @"reason": @"source allocation" };
    CVPixelBufferLockBaseAddress(input, 0);
    memset(CVPixelBufferGetBaseAddress(input), 80, CVPixelBufferGetBytesPerRow(input) * CVPixelBufferGetHeight(input));
    CVPixelBufferUnlockBaseAddress(input, 0);
    [p adoptSourceGeneration:1];
    dispatch_sync(p->_q, ^{ p->_width=480; p->_height=270; });
    SPLivePlanRequest *request=[[SPLivePlanRequest alloc] init];
    request.scaleEnabled=YES; request.scaleEngine=SPLiveScaleAppleVideoSR;
    request.outputWidth=1920; request.outputHeight=1080; request.viewMode=SPLiveViewCompare;
    [p updateRequest:request];
    __block BOOL ready=NO;
    for (int i=0;i<400&&!ready;i++) { usleep(50000); dispatch_sync(p->_q, ^{ready=p->_sessionReady && p->_videoSR && p->_resolved.scaleActive;}); }
    if (!ready) { CVPixelBufferRelease(input); [p stop]; return @{ @"ok":@NO, @"reason":@"video SR prepare", @"stats":[p stats] }; }
    __block uint64_t config=0; dispatch_sync(p->_q, ^{config=p->_configVersion;});
    SPLivePlanRequest *bad=[request copy]; bad.interpolationEnabled=YES; bad.engineID=@"apple.frc"; bad.multiplier=2;
    [p updateRequest:bad];
    __block BOOL rejectedWithoutReplacing=NO;
    dispatch_sync(p->_q, ^{rejectedWithoutReplacing=p->_configVersion==config && p->_videoSR && p->_sessionReady && !p->_request.interpolationEnabled;});
    int64_t future=SPHostNow()+SPRationalToHost(sp::spMake(20,1));
    dispatch_sync(p->_q, ^{
        for (int i=0;i<3;i++) {
            uint64_t id=11+i;
            p->_held[id].source=CVPixelBufferRetain(input);p->_held[id].host=future+SPRationalToHost(sp::spMake(i,30));p->_held[id].pts=sp::spMake(i,30);
            [p enqueueSourceIdentity:id pts:sp::spMake(i,30) host:p->_held[id].host generation:1 force:NO];
        }
    });
    __block int observed=0; __block BOOL sizes=YES, comparison=YES;
    for (int i=0;i<400&&observed<3;i++) {usleep(50000);dispatch_sync(p->_q, ^{
        observed=0;for(const SPPlaySlot &slot:p->_slots){
            if(slot.sourceGeneration!=1 || slot.synthetic)continue;
            if(sp::spCmp(slot.pts,sp::spMake(0,1))>=0 && sp::spCmp(slot.pts,sp::spMake(2,30))<=0)observed++;
            sizes=sizes && CVPixelBufferGetWidth(slot.enhanced)==1920 && CVPixelBufferGetHeight(slot.enhanced)==1080 && CVPixelBufferGetPixelFormatType(slot.enhanced)==kCVPixelFormatType_32BGRA;
            comparison=comparison && slot.original && CVPixelBufferGetWidth(slot.original)==1920;
        }
    });}
    [p adoptSourceGeneration:2];dispatch_sync(p->_q,^{});
    [p pushPixelBuffer:input ptsNum:1 ptsDen:1 host:future generation:2];
    __block BOOL secondReady=NO;
    for(int i=0;i<400&&!secondReady;i++){usleep(50000);dispatch_sync(p->_q,^{secondReady=p->_sourceGeneration==2 && p->_sessionReady && p->_videoSR && p->_resolved.scaleActive;});}
    [p pushPixelBuffer:input ptsNum:31 ptsDen:30 host:future+SPRationalToHost(sp::spMake(1,30)) generation:2];
    __block BOOL newOutput=NO,oldOutput=NO;
    for(int i=0;i<400&&!newOutput;i++){usleep(50000);dispatch_sync(p->_q,^{for(const SPPlaySlot &slot:p->_slots){if(slot.sourceGeneration!=2)oldOutput=YES;if(slot.sourceGeneration==2&&sp::spCmp(slot.pts,sp::spMake(31,30))==0&&CVPixelBufferGetWidth(slot.enhanced)==1920)newOutput=YES;}});}
    CVPixelBufferRelease(input);[p stop];
    BOOL ok=ready&&rejectedWithoutReplacing&&observed==3&&sizes&&comparison&&secondReady&&newOutput&&!oldOutput;
    return @{ @"ok":@(ok), @"prepared":@(ready), @"outputFramesWithOriginalPTS":@(observed), @"outputBGRAAndSize":@(sizes), @"compareBaseline":@(comparison), @"unverifiedCombinationRejectedAndOldPlanKept":@(rejectedWithoutReplacing), @"newGenerationSession":@(secondReady), @"newGenerationOutput":@(newOutput), @"oldGenerationOutput":@(oldOutput), @"note":@"Synthetic sources only; real capture, visual quality, UI persistence and performance remain unverified." };
}

+ (NSDictionary<NSString *, id> *)runSRPipelineContract {
    SPLiveProcessor *p = [[SPLiveProcessor alloc] init];
    CVPixelBufferRef source = [self syntheticFrame:0];
    if (!source) return @{ @"ok": @NO, @"reason": @"source allocation" };
    [p adoptSourceGeneration:1];
    dispatch_sync(p->_q, ^{ p->_width = 1280; p->_height = 720; });
    SPLivePlanRequest *request = [[SPLivePlanRequest alloc] init];
    request.scaleEnabled = YES; request.scaleEngine = SPLiveScaleAppleLowLatencySR;
    request.outputWidth = 1920; request.outputHeight = 1080; request.viewMode = SPLiveViewCompare;
    [p updateRequest:request];
    __block BOOL ready = NO;
    for (int i = 0; i < 400 && !ready; ++i) {
        usleep(50000);
        dispatch_sync(p->_q, ^{ ready = p->_sessionReady && p->_resolved.scaleActive && p->_appleSR != nil; });
    }
    if (!ready) { CVPixelBufferRelease(source); [p stop]; return @{ @"ok": @NO, @"reason": @"SR prepare", @"stats": [p stats] }; }
    __block uint64_t originalConfig = 0;
    dispatch_sync(p->_q, ^{ originalConfig = p->_configVersion; });
    SPLivePlanRequest *bad = [request copy]; bad.outputWidth = 1600; bad.outputHeight = 900;
    [p updateRequest:bad];
    __block BOOL prepareFinished = NO, preserved = NO;
    for (int i = 0; i < 400 && !prepareFinished; ++i) {
        usleep(50000);
        dispatch_sync(p->_q, ^{ prepareFinished = !p->_preparing; preserved = p->_sessionReady && p->_resolved.scaleActive && p->_configVersion == originalConfig && p->_appleSR != nil; });
    }
    int64_t future = SPHostNow() + SPRationalToHost(sp::spMake(20, 1));
    dispatch_sync(p->_q, ^{
        p->_held[11].source = CVPixelBufferRetain(source);
        p->_held[11].host = future;
        p->_held[11].pts = sp::spMake(10, 1);
        [p enqueueSourceIdentity:11 pts:sp::spMake(10, 1) host:future generation:1 force:NO];
        SPLiveJob *job = new SPLiveJob();
        job->configVersion = p->_configVersion; job->generation = 1; job->inflightEpoch = p->_inflightEpoch; job->clockEpoch = p->_clockEpoch;
        job->captureHost = future; job->frameA = 11; job->count = 1; job->pts[0] = sp::spMake(601, 60);
        SPOwnedPixelBuffer *output = [[SPOwnedPixelBuffer alloc] initWithBufferNoCopy:CVPixelBufferRetain(source)];
        [p finishJob:job token:1 outputs:@[output] latency:0 error:nil];
    });
    __block BOOL sourceOK = NO, syntheticOK = NO, dimensionsOK = NO, compareOK = NO;
    for (int i = 0; i < 400 && !(sourceOK && syntheticOK); ++i) {
        usleep(50000);
        dispatch_sync(p->_q, ^{
            for (const SPPlaySlot &slot : p->_slots) {
                BOOL shape = CVPixelBufferGetWidth(slot.enhanced) == 1920 && CVPixelBufferGetHeight(slot.enhanced) == 1080 && CVPixelBufferGetPixelFormatType(slot.enhanced) == kCVPixelFormatType_32BGRA;
                dimensionsOK |= shape;
                compareOK |= slot.original && CVPixelBufferGetWidth(slot.original) == 1920;
                if (!slot.synthetic && sp::spCmp(slot.pts, sp::spMake(10, 1)) == 0 && shape) sourceOK = YES;
                if (slot.synthetic && sp::spCmp(slot.pts, sp::spMake(601, 60)) == 0 && shape) syntheticOK = YES;
            }
        });
    }
    // Replace the source after work was queued. The next frame must rebuild a
    // fresh SR session rather than submitting into the invalidated one.
    [p adoptSourceGeneration:2];
    dispatch_sync(p->_q, ^{});
    [p pushPixelBuffer:source ptsNum:20 ptsDen:1 host:future generation:2];
    __block BOOL secondReady = NO;
    for (int i = 0; i < 400 && !secondReady; ++i) {
        usleep(50000);
        dispatch_sync(p->_q, ^{ secondReady = p->_sourceGeneration == 2 && p->_sessionReady && p->_appleSR && p->_resolved.scaleActive; });
    }
    [p pushPixelBuffer:source ptsNum:21 ptsDen:1 host:future generation:2];
    __block BOOL newGenerationOutput = NO, oldGenerationOutput = NO;
    for (int i = 0; i < 400 && !newGenerationOutput; ++i) {
        usleep(50000);
        dispatch_sync(p->_q, ^{
            for (const SPPlaySlot &slot : p->_slots) {
                if (slot.sourceGeneration != 2) oldGenerationOutput = YES;
                if (slot.sourceGeneration == 2 && sp::spCmp(slot.pts, sp::spMake(21, 1)) == 0 && CVPixelBufferGetWidth(slot.enhanced) == 1920) newGenerationOutput = YES;
            }
        });
    }
    CVPixelBufferRelease(source);
    [p stop];
    return @{ @"ok": @(ready && prepareFinished && preserved && sourceOK && syntheticOK && dimensionsOK && compareOK && secondReady && newGenerationOutput && !oldGenerationOutput),
              @"ready": @(ready), @"failedPreparePreservesPlan": @(prepareFinished && preserved),
              @"sourcePTSAndBGRA": @(sourceOK), @"syntheticPTSAndBGRA": @(syntheticOK),
              @"newGenerationReady": @(secondReady), @"newGenerationOutput": @(newGenerationOutput), @"oldGenerationOutput": @(oldGenerationOutput),
              @"compareBaseline": @(compareOK), @"note": @"No GUI: synthetic input and simulated interpolation output; real capture and actual interpolation remain independently unverified." };
}

+ (NSDictionary<NSString *, id> *)runSessionContract {
    int schedule = spRunRateScheduleTests();
    SPLiveProcessor *processor = [[SPLiveProcessor alloc] init];
    CVPixelBufferRef frame = SPCreateBuffer(32, 32, kCVPixelFormatType_32BGRA);
    if (!frame) return @{@"ok": @NO, @"reason": @"buffer", @"scheduleFailures": @(schedule)};
    CVPixelBufferLockBaseAddress(frame, 0);
    memset(CVPixelBufferGetBaseAddress(frame), 40, CVPixelBufferGetBytesPerRow(frame) * 32);
    CVPixelBufferUnlockBaseAddress(frame, 0);
    const int64_t pts = 336876423129125LL;
    const int64_t den = 1000000000LL;
    [processor adoptSourceGeneration:1];
    dispatch_sync(processor->_q, ^{});
    [processor pushPixelBuffer:frame ptsNum:pts ptsDen:den host:SPHostNow() generation:1];
    dispatch_sync(processor->_q, ^{});
    NSDictionary *running = [processor stats];
    [processor stop];
    NSDictionary *stopped = [processor stats];
    [processor pushPixelBuffer:frame ptsNum:pts + 33333333 ptsDen:den host:SPHostNow() generation:1];
    dispatch_sync(processor->_q, ^{});
    NSDictionary *whileStopped = [processor stats];
    [processor adoptSourceGeneration:1];
    dispatch_sync(processor->_q, ^{});
    [processor pushPixelBuffer:frame ptsNum:pts + 66666666 ptsDen:den host:SPHostNow() generation:1];
    dispatch_sync(processor->_q, ^{});
    NSDictionary *rebound = [processor stats];
    [processor adoptSourceGeneration:2];
    dispatch_sync(processor->_q, ^{});
    [processor pushPixelBuffer:frame ptsNum:pts + 100000000 ptsDen:den host:SPHostNow() generation:1];
    dispatch_sync(processor->_q, ^{});
    NSDictionary *oldGeneration = [processor stats];
    [processor pushPixelBuffer:frame ptsNum:pts + 133333333 ptsDen:den host:SPHostNow() generation:2];
    dispatch_sync(processor->_q, ^{});
    NSDictionary *newGeneration = [processor stats];
    CVPixelBufferRelease(frame);
    BOOL firstAccepted = [running[@"stoppedDrops"] unsignedLongLongValue] == 0 &&
        [running[@"generationDrops"] unsignedLongLongValue] == 0;
    BOOL generationHeld = [stopped[@"sourceGeneration"] unsignedLongLongValue] == 1 && [stopped[@"stopped"] boolValue];
    BOOL droppedWhileStopped = [whileStopped[@"stoppedDrops"] unsignedLongLongValue] >= 1;
    BOOL resumed = [rebound[@"stopped"] boolValue] == NO &&
        [rebound[@"stoppedDrops"] unsignedLongLongValue] == 0 &&
        [rebound[@"sourceGeneration"] unsignedLongLongValue] == 1;
    BOOL oldRejected = [oldGeneration[@"generationDrops"] unsignedLongLongValue] >= 1 &&
        [oldGeneration[@"sourceGeneration"] unsignedLongLongValue] == 2;
    BOOL acceptedNew = [newGeneration[@"generationDrops"] unsignedLongLongValue] == [oldGeneration[@"generationDrops"] unsignedLongLongValue] &&
        [newGeneration[@"stopped"] boolValue] == NO;
    SPLiveProcessor *startOrder = [[SPLiveProcessor alloc] init];
    [startOrder adoptSourceGeneration:1];
    __block BOOL sourceOnlyPreview = NO;
    dispatch_sync(startOrder->_q, ^{ sourceOnlyPreview = !startOrder->_request.interpolationEnabled && !startOrder->_request.scaleEnabled; });
    [startOrder stop];
    SPLivePlanRequest *explicitStart = [[SPLivePlanRequest alloc] init];
    explicitStart.interpolationEnabled = YES;
    explicitStart.scaleEnabled = YES;
    explicitStart.engineID = @"rife.metal";
    explicitStart.modelID = @"rife-v4.25";
    explicitStart.rateKind = SPLiveRateMultiplier;
    explicitStart.multiplier = 2;
    // The UI queues generation before Start; the following queued callback
    // deliberately arrives late with the same generation, then an older one.
    [startOrder adoptSourceGeneration:2];
    [startOrder updateRequest:explicitStart];
    __block uint64_t pendingToken = 0;
    dispatch_sync(startOrder->_q, ^{ startOrder->_preparing = YES; pendingToken = startOrder->_prepareToken; });
    [startOrder adoptSourceGeneration:2];
    [startOrder adoptSourceGeneration:1];
    __block BOOL explicitIntentKept = NO, lateSameKept = NO, olderIgnored = NO;
    dispatch_sync(startOrder->_q, ^{
        explicitIntentKept = startOrder->_request.interpolationEnabled && startOrder->_request.scaleEnabled &&
            [startOrder->_request.engineID isEqualToString:@"rife.metal"] && !startOrder->_stopped;
        lateSameKept = startOrder->_preparing && startOrder->_prepareToken == pendingToken;
        olderIgnored = startOrder->_sourceGeneration == 2;
    });
    [startOrder stop];
    BOOL ok = schedule == 0 && firstAccepted && generationHeld && droppedWhileStopped && resumed && oldRejected && acceptedNew &&
        sourceOnlyPreview && explicitIntentKept && lateSameKept && olderIgnored;
    return @{
        @"ok": @(ok),
        @"scheduleFailures": @(schedule),
        @"firstAccepted": @(firstAccepted),
        @"generationHeldAcrossStop": @(generationHeld),
        @"droppedWhileStopped": @(droppedWhileStopped),
        @"sameGenerationRestart": @(resumed),
        @"oldGenerationRejected": @(oldRejected),
        @"newGenerationAccepted": @(acceptedNew),
        @"sourceOnlyPreview": @(sourceOnlyPreview),
        @"explicitStartIntentKept": @(explicitIntentKept),
        @"lateSameGenerationKeepsPendingPrepare": @(lateSameKept),
        @"olderGenerationNotificationIgnored": @(olderIgnored),
        @"startOrderTestNote": @"Simulated pending-prepare state; real engine restart still needs window capture verification.",
        @"stoppedGeneration": stopped[@"sourceGeneration"] ?: @0,
        @"reboundGeneration": rebound[@"sourceGeneration"] ?: @0,
    };
}

- (void)openProbeWindowMinNum:(int64_t)num den:(int64_t)den aggregate:(BOOL)aggregate {
    dispatch_sync(_q, ^{
        self->_probeWindowOpen = YES;
        self->_probeMinPts = sp::spMake(num, den);
        self->_probeAggregateOnly = aggregate;
        self->_probeMonotonic = YES;
        self->_probeSizeOK = YES;
        self->_probeHaveLast = NO;
        self->_measuredScheduled = 0;
        self->_presentedSource = 0;
        self->_presentedSynthetic = 0;
        self->_presentedCallbacks = 0;
        self->_scheduledSynthetic = 0;
        self->_deadlineDrops = 0;
        self->_queueDrops = 0;
        self->_renderDrops = 0;
        self->_syntheticOK = 0;
        self->_syntheticFail = 0;
        self->_submitted = 0;
        self->_peakSlots = 0;
        self->_centerSamples = 0;
        self->_centerSampleNs = 0;
        self->_latencyNs.clear();
        self->_frcNs.clear();
        self->_scaleNs.clear();
        self->_transferNs.clear();
        self->_queueNs.clear();
        self->_playheadNs.clear();
        [self->_probeOutputs removeAllObjects];
        self->_windowStart = SPHostNow();
    });
}

+ (NSDictionary<NSString *, id> *)runProbe {
    NSMutableDictionary *report = [NSMutableDictionary dictionary];
    int schedule = spRunRateScheduleTests();
    report[@"scheduleFailures"] = @(schedule);
    report[@"frcAvailable"] = @([SPFRCEngine isAvailable]);
    NSMutableDictionary *capability = [NSMutableDictionary dictionary];
    if (@available(macOS 26.0, *)) {
        capability[@"lowLatencySupported"] = @(VTLowLatencyFrameInterpolationConfiguration.isSupported);
        id temporal1 = [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:1280 frameHeight:720 numberOfInterpolatedFrames:1];
        id temporal2 = [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:1280 frameHeight:720 numberOfInterpolatedFrames:2];
        id spatial = [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:1280 frameHeight:720 spatialScaleFactor:2];
        capability[@"lowLatencyTemporal1"] = @(temporal1 != nil);
        capability[@"lowLatencyTemporal2"] = @(temporal2 != nil);
        capability[@"lowLatencySpatial2x"] = @(spatial != nil);
        capability[@"lowLatencyNote"] = @"低延迟接口未接入实时路径。X3 的 1/3、2/3 不在它的等距相位集合里。";
        if (@available(macOS 27.0, *)) {
            capability[@"lowLatencyMaxDimensionScale1"] = @([VTLowLatencyFrameInterpolationConfiguration maximumDimensionForSpatialScaleFactor:1]);
        }
        capability[@"superResolutionScaleFactors"] = VTSuperResolutionScalerConfiguration.supportedScaleFactors ?: @[];
        VTSuperResolutionScalerConfiguration *superConfig = [[VTSuperResolutionScalerConfiguration alloc]
            initWithFrameWidth:1280 frameHeight:720 scaleFactor:2
            inputType:VTSuperResolutionScalerConfigurationInputTypeVideo usePrecomputedFlow:NO
            qualityPrioritization:VTSuperResolutionScalerConfigurationQualityPrioritizationNormal
            revision:VTSuperResolutionScalerConfigurationRevision1];
        capability[@"superResolutionConfig"] = @(superConfig != nil);
        if (superConfig) capability[@"superResolutionModelStatus"] = @(superConfig.configurationModelStatus);
        capability[@"superResolutionNote"] = @"Apple 视频超分未接入本轮。";
    }
    capability[@"metalFXDevice"] = @([MTLFXSpatialScalerDescriptor supportsDevice:MTLCreateSystemDefaultDevice()]);
    report[@"capability"] = capability;
    if (![SPFRCEngine isAvailable]) {
        report[@"combination"] = @{@"ok": @NO, @"reason": @"FRC unavailable"};
        return report;
    }
    SPLiveProcessor *processor = [[SPLiveProcessor alloc] init];
    processor->_probeOutputs = [NSMutableArray array];
    processor->_probeGate = dispatch_semaphore_create(0);
    processor->_probeSyntheticGoal = 20;
    SPLivePlanRequest *request = [[SPLivePlanRequest alloc] init];
    request.interpolationEnabled = YES;
    request.quality = SPFRCQualityNormal;
    request.rateKind = SPLiveRateMultiplier;
    request.multiplier = 2;
    request.scaleEnabled = YES;
    request.scaleEngine = SPLiveScaleLanczos;
    request.outputWidth = 1920;
    request.outputHeight = 1080;
    request.viewMode = SPLiveViewCompare;
    request.displayRefreshHz = 60;
    processor->_request = request;
    NSError *error = nil;
    BOOL ready = [processor installSynchronouslyWidth:1280 height:720 error:&error];
    report[@"sessionReady"] = @(ready);
    if (!ready) {
        report[@"combination"] = @{@"ok": @NO, @"reason": error.localizedDescription ?: @"session"};
        return report;
    }
    __block SPLivePreviewView *probeView = nil;
    __block NSWindow *probeWindow = nil;
    void (^makeWindow)(void) = ^{
        probeView = [[SPLivePreviewView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)];
        probeWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, 640, 360)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered defer:NO];
        probeWindow.title = @"Khua presentation probe";
        probeWindow.contentView = probeView;
        [probeWindow orderFrontRegardless];
        [probeView refreshVisibilitySnapshot];
        processor.preview = probeView;
        [processor installPresentationHooks];
    };
    if ([NSThread isMainThread]) makeWindow();
    else dispatch_sync(dispatch_get_main_queue(), makeWindow);
    [probeView setGeneration:processor->_sourceGeneration];
    uint64_t probeGeneration = processor->_sourceGeneration;
    const int warmup = 30;
    const int measured = 300;
    const int total = warmup + measured;
    CVPixelBufferRef ring[20];
    for (int i = 0; i < 20; ++i) ring[i] = [self syntheticFrame:i];
    int64_t interval = SPRationalToHost(sp::spMake(1, 30));
    int64_t t0 = SPHostNow() + interval;
    NSMutableArray<NSNumber *> *jitter = [NSMutableArray array];
    int64_t firstHost = 0, lastHost = 0;
    for (int i = 0; i < total; ++i) {
        if (i == warmup) [processor openProbeWindowMinNum:warmup den:30 aggregate:NO];
        int64_t deadline = t0 + (int64_t)i * interval;
        SPWaitUntilHost(deadline);
        int64_t host = SPHostNow();
        if (i >= warmup) {
            [jitter addObject:@(SPHostToNs(host - deadline))];
            if (i == warmup) firstHost = host;
            lastHost = host;
        }
        [processor pushPixelBuffer:ring[i % 20] ptsNum:i ptsDen:30 host:host generation:probeGeneration];
    }
    for (int wait = 0; wait < 150; ++wait) {
        __block int inflight = 1;
        __block int slots = 1;
        dispatch_sync(processor->_q, ^{
            inflight = processor->_inflight;
            slots = (int)processor->_slots.size() + (int)processor->_pending.size();
        });
        if (inflight == 0 && slots == 0) break;
        usleep(20000);
    }
    usleep(150000);
    NSArray *outputs = [processor->_probeOutputs copy];
    NSDictionary *liveStats = [processor stats];
    BOOL monotonic = YES;
    int syntheticCount = 0;
    BOOL compareDiffers = NO;
    NSDictionary *mid = nil;
    long long previousNum = 0, previousDen = 1;
    BOOL havePrevious = NO;
    std::vector<double> latencies;
    for (NSDictionary *item in outputs) {
        long long num = [item[@"ptsNum"] longLongValue];
        long long den = [item[@"ptsDen"] longLongValue];
        if (havePrevious) {
            __int128 leftPts = (__int128)previousNum * den;
            __int128 rightPts = (__int128)num * previousDen;
            if (leftPts >= rightPts) monotonic = NO;
        }
        previousNum = num;
        previousDen = den;
        havePrevious = YES;
        double latencyMs = [item[@"latencyMs"] doubleValue];
        if (latencyMs >= 0) latencies.push_back(latencyMs);
        if ([item[@"synthetic"] boolValue]) {
            syntheticCount += 1;
            if (!mid) mid = item;
            double enhancedCenter = [item[@"enhancedCenter"] doubleValue];
            double originalCenter = [item[@"originalCenter"] doubleValue];
            if (enhancedCenter >= 0 && originalCenter >= 0 && fabs(enhancedCenter - originalCenter) > 2.0) compareDiffers = YES;
        }
    }
    std::sort(latencies.begin(), latencies.end());
    double p95 = latencies.empty() ? -1 : latencies[(latencies.size() - 1) * 95 / 100];
    BOOL sizeOK = outputs.count > 0;
    for (NSDictionary *item in outputs) {
        if ([item[@"width"] intValue] != 1920 || [item[@"height"] intValue] != 1080) sizeOK = NO;
    }
    double mediaSec = (double)(measured - 1) / 30.0;
    double spanSec = firstHost > 0 && lastHost > firstHost ? (double)SPHostToNs(lastHost - firstHost) / 1e9 : 0;
    double inputFps = spanSec > 0 ? (double)(measured - 1) / spanSec : 0;
    double driftMs = (spanSec - mediaSec) * 1000.0;
    std::vector<int64_t> jitterAbs;
    for (NSNumber *value in jitter) {
        int64_t sample = value.longLongValue;
        jitterAbs.push_back(sample < 0 ? -sample : sample);
    }
    BOOL clockOK = inputFps >= 29.5 && inputFps <= 30.5 && fabs(driftMs) < 80.0;
    uint64_t scheduled = [liveStats[@"measuredScheduled"] unsignedLongLongValue];
    double coverage = scheduled > 0 ? (double)syntheticCount / (double)scheduled : 0;
    BOOL performanceOK = clockOK && scheduled > 0 && coverage >= 0.95 && p95 >= 0 && p95 <= 100.0;
    BOOL functionalOK = ready && sizeOK && monotonic && compareDiffers && syntheticCount > 0;
    NSString *bottleneck = @"none";
    if (!performanceOK) {
        double frcP95 = [liveStats[@"frcP95ms"] doubleValue];
        double scaleP95 = [liveStats[@"scaleP95ms"] doubleValue];
        double transferP95 = [liveStats[@"transferP95ms"] doubleValue];
        double queueP95 = [liveStats[@"queueP95ms"] doubleValue];
        double playheadP95 = [liveStats[@"playheadP95ms"] doubleValue];
        if (!clockOK) bottleneck = @"probe-clock";
        else if (frcP95 >= scaleP95 && frcP95 >= transferP95 && frcP95 >= 25.0) bottleneck = @"frc";
        else if (scaleP95 + transferP95 >= 20.0) bottleneck = @"scale-or-transfer";
        else if ([liveStats[@"queueDrops"] unsignedLongLongValue] > 0 || queueP95 > 40.0) bottleneck = @"queue";
        else if (playheadP95 > 20.0) bottleneck = @"playhead";
        else if (p95 > 100.0) bottleneck = @"capture-to-present";
        else bottleneck = @"coverage";
    }
    NSMutableArray *sample = [NSMutableArray array];
    for (NSDictionary *item in outputs) {
        if ([item[@"enhancedCenter"] doubleValue] >= 0 || sample.count < 4) [sample addObject:item];
        if (sample.count >= 16) break;
    }
    NSDictionary *clock = @{
        @"warmupFrames": @(warmup),
        @"measuredFrames": @(measured),
        @"inputFps": @(inputFps),
        @"hostSpanSec": @(spanSec),
        @"mediaSpanSec": @(mediaSec),
        @"driftMs": @(driftMs),
        @"jitterP95ms": @(SPPercentileMs(jitterAbs)),
        @"absoluteGrid": @YES,
        @"clockOK": @(clockOK),
    };
    report[@"clock"] = clock;
    report[@"liveStats"] = liveStats;
    report[@"outputSample"] = sample;
    report[@"stages"] = @{
        @"frcP95ms": liveStats[@"frcP95ms"] ?: @(-1),
        @"scaleP95ms": liveStats[@"scaleP95ms"] ?: @(-1),
        @"transferP95ms": liveStats[@"transferP95ms"] ?: @(-1),
        @"queueP95ms": liveStats[@"queueP95ms"] ?: @(-1),
        @"playheadP95ms": liveStats[@"playheadP95ms"] ?: @(-1),
        @"presentP95ms": @(p95),
        @"delayMs": liveStats[@"delayMs"] ?: @(-1),
        @"delayClamped": liveStats[@"delayClamped"] ?: @NO,
        @"slotCap": liveStats[@"slotCap"] ?: @0,
        @"peakSlots": liveStats[@"peakSlots"] ?: @0,
        @"centerSampleMs": liveStats[@"centerSampleMs"] ?: @0,
        @"centerSamples": liveStats[@"centerSamples"] ?: @0,
        @"bottleneck": bottleneck,
    };
    BOOL fiveMinuteOK = YES;
    if (performanceOK) {
        const int longFrames = 30 * 60 * 5;
        int64_t longT0 = SPHostNow() + interval;
        int64_t longFirst = 0, longLast = 0;
        NSMutableArray<NSNumber *> *longJitter = [NSMutableArray array];
        [processor openProbeWindowMinNum:total den:30 aggregate:YES];
        for (int i = 0; i < longFrames; ++i) {
            int64_t deadline = longT0 + (int64_t)i * interval;
            SPWaitUntilHost(deadline);
            int64_t host = SPHostNow();
            if (i == 0) longFirst = host;
            longLast = host;
            [longJitter addObject:@(SPHostToNs(host - deadline))];
            int frameIndex = total + i;
            [processor pushPixelBuffer:ring[frameIndex % 20] ptsNum:frameIndex ptsDen:30 host:host generation:probeGeneration];
        }
        for (int wait = 0; wait < 150; ++wait) {
            __block int inflight = 1;
            __block int slots = 1;
            dispatch_sync(processor->_q, ^{
                inflight = processor->_inflight;
                slots = (int)processor->_slots.size() + (int)processor->_pending.size();
            });
            if (inflight == 0 && slots == 0) break;
            usleep(20000);
        }
        usleep(150000);
        NSDictionary *longStats = [processor stats];
        double longMedia = (double)(longFrames - 1) / 30.0;
        double longSpan = longLast > longFirst ? (double)SPHostToNs(longLast - longFirst) / 1e9 : 0;
        double longFps = longSpan > 0 ? (double)(longFrames - 1) / longSpan : 0;
        double longDrift = (longSpan - longMedia) * 1000.0;
        std::vector<int64_t> longAbs;
        for (NSNumber *value in longJitter) {
            int64_t sampleValue = value.longLongValue;
            longAbs.push_back(sampleValue < 0 ? -sampleValue : sampleValue);
        }
        BOOL longClockOK = longFps >= 29.5 && longFps <= 30.5 && fabs(longDrift) < 250.0;
        uint64_t longScheduled = [longStats[@"measuredScheduled"] unsignedLongLongValue];
        uint64_t longPresented = [longStats[@"presentedSynthetic"] unsignedLongLongValue];
        double longCoverage = longScheduled > 0 ? (double)longPresented / (double)longScheduled : 0;
        double longP95 = [longStats[@"p95ms"] doubleValue];
        __block BOOL longMonotonic = NO;
        __block BOOL longSize = NO;
        dispatch_sync(processor->_q, ^{
            longMonotonic = processor->_probeMonotonic;
            longSize = processor->_probeSizeOK && processor->_presentedCallbacks > 0;
        });
        fiveMinuteOK = longClockOK && longMonotonic && longSize && longScheduled > 0 && longCoverage >= 0.95 && longP95 >= 0 && longP95 <= 100.0;
        report[@"fiveMinute"] = @{
            @"ran": @YES,
            @"frames": @(longFrames),
            @"inputFps": @(longFps),
            @"hostSpanSec": @(longSpan),
            @"mediaSpanSec": @(longMedia),
            @"driftMs": @(longDrift),
            @"jitterP95ms": @(SPPercentileMs(longAbs)),
            @"coverage": @(longCoverage),
            @"scheduledSynthetic": @(longScheduled),
            @"presentedSynthetic": @(longPresented),
            @"p95ms": @(longP95),
            @"monotonic": @(longMonotonic),
            @"size": @(longSize),
            @"ok": @(fiveMinuteOK),
            @"liveStats": longStats,
        };
    } else {
        fiveMinuteOK = NO;
        report[@"fiveMinute"] = @{@"ran": @NO, @"reason": @"300-frame performance not met"};
    }
    for (int i = 0; i < 20; ++i) CVPixelBufferRelease(ring[i]);
    BOOL staleIgnored = YES;
    report[@"combination"] = @{
        @"functionalOK": @(functionalOK),
        @"performanceOK": @(performanceOK),
        @"fiveMinuteOK": @(fiveMinuteOK),
        @"ok": @(functionalOK && performanceOK && fiveMinuteOK),
        @"coverage": @(coverage),
        @"scheduledSynthetic": @(scheduled),
        @"outputCount": @(outputs.count),
        @"syntheticPresented": @(syntheticCount),
        @"p95ms": @(p95),
        @"monotonic": @(monotonic),
        @"compareDiffers": @(compareDiffers),
        @"staleIgnored": @(staleIgnored),
        @"mid": mid ?: @{},
        @"midpointBetween": @(compareDiffers),
        @"size": @(sizeOK),
        @"clockOK": @(clockOK),
        @"bottleneck": bottleneck,
        @"colorPath": @"sdr.bt709.8bit",
        @"presentationEndpoint": @"preview",
        @"realWindowCapture": @NO,
        @"note": @"可见预览窗口上的合成运动呈现。不是系统选窗验收。迟到帧仍留在覆盖率分母里。",
    };

    for (int wait = 0; wait < 40 && processor->_inflight > 0; ++wait) usleep(25000);
    CVPixelBufferRef a = [self syntheticFrame:0];
    CVPixelBufferRef b = [self syntheticFrame:1];
    __block CVPixelBufferRef yuvA = NULL;
    __block CVPixelBufferRef yuvB = NULL;
    dispatch_sync(processor->_q, ^{
        yuvA = [processor transfer:a format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
        yuvB = [processor transfer:b format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
    });
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    __block NSUInteger x3Count = 0, x4Count = 0;
    __block BOOL x3Distinct = NO, x4Distinct = NO;
    __block double x3a = -1, x3b = -1, x4a = -1, x4b = -1;
    [processor->_engine submitPhasesWithFrameA:yuvA frameB:yuvB phases:@[@(1.f / 3.f), @(2.f / 3.f)] sequential:NO token:3
                                     completion:^(uint64_t token, NSArray<SPOwnedPixelBuffer *> *outputs3, double latency, NSError *phaseError) {
        (void)token; (void)latency;
        dispatch_async(processor->_q, ^{
            x3Count = phaseError ? 0 : outputs3.count;
            if (outputs3.count == 2) {
                CVPixelBufferRef d0 = [processor transfer:outputs3[0].buffer format:kCVPixelFormatType_32BGRA];
                CVPixelBufferRef d1 = [processor transfer:outputs3[1].buffer format:kCVPixelFormatType_32BGRA];
                x3a = SPWhiteCenterX(d0);
                x3b = SPWhiteCenterX(d1);
                x3Distinct = fabs(x3a - x3b) > 1.0;
                if (d0) CVPixelBufferRelease(d0);
                if (d1) CVPixelBufferRelease(d1);
            }
            [processor->_engine submitPhasesWithFrameA:yuvA frameB:yuvB phases:@[@0.25f, @0.5f, @0.75f] sequential:NO token:4
                                             completion:^(uint64_t token4, NSArray<SPOwnedPixelBuffer *> *outputs4, double latency4, NSError *error4) {
                (void)token4; (void)latency4;
                dispatch_async(processor->_q, ^{
                    x4Count = error4 ? 0 : outputs4.count;
                    if (outputs4.count == 3) {
                        CVPixelBufferRef d0 = [processor transfer:outputs4[0].buffer format:kCVPixelFormatType_32BGRA];
                        CVPixelBufferRef d2 = [processor transfer:outputs4[2].buffer format:kCVPixelFormatType_32BGRA];
                        x4a = SPWhiteCenterX(d0);
                        x4b = SPWhiteCenterX(d2);
                        x4Distinct = fabs(x4a - x4b) > 1.0;
                        if (d0) CVPixelBufferRelease(d0);
                        if (d2) CVPixelBufferRelease(d2);
                    }
                    dispatch_semaphore_signal(gate);
                });
            }];
        });
    }];
    dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
    report[@"phases"] = @{
        @"x3Count": @(x3Count), @"x3Distinct": @(x3Distinct), @"x3Centers": @[@(x3a), @(x3b)],
        @"x4Count": @(x4Count), @"x4Distinct": @(x4Distinct), @"x4Centers": @[@(x4a), @(x4b)],
    };
    CVPixelBufferRelease(a);
    CVPixelBufferRelease(b);
    if (yuvA) CVPixelBufferRelease(yuvA);
    if (yuvB) CVPixelBufferRelease(yuvB);

    CVPixelBufferRef dot = SPCreateBuffer(1280, 720, kCVPixelFormatType_32BGRA);
    CVPixelBufferLockBaseAddress(dot, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(dot);
    size_t stride = CVPixelBufferGetBytesPerRow(dot);
    memset(base, 0, stride * 720);
    uint8_t *pixel = base + 100 * stride + 100 * 4;
    pixel[0] = pixel[1] = pixel[2] = 255;
    pixel[3] = 255;
    CVPixelBufferUnlockBaseAddress(dot, 0);
    __block CVPixelBufferRef halo = NULL;
    dispatch_sync(processor->_q, ^{
        halo = [processor->_scaler scaleBuffer:dot error:NULL];
    });
    int nonzero = 0;
    if (halo) {
        CVPixelBufferLockBaseAddress(halo, kCVPixelBufferLock_ReadOnly);
        uint8_t *out = (uint8_t *)CVPixelBufferGetBaseAddress(halo);
        size_t outStride = CVPixelBufferGetBytesPerRow(halo);
        for (int y = 140; y < 170; ++y) {
            uint8_t *row = out + y * outStride;
            for (int x = 140; x < 170; ++x) if (row[x * 4] > 8) nonzero += 1;
        }
        CVPixelBufferUnlockBaseAddress(halo, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(halo);
    }
    report[@"lanczos"] = @{@"nonzeroNeighborhood": @(nonzero), @"spread": @(nonzero >= 4)};
    CVPixelBufferRelease(dot);

    NSError *fxError = nil;
    SPSpatialScaler *fx = [[SPSpatialScaler alloc] initWithDevice:MTLCreateSystemDefaultDevice() inputW:1280 inputH:720
                                                         outputW:1920 outputH:1080 engine:SPLiveScaleMetalFX error:&fxError];
    CVPixelBufferRef fxFrame = [self syntheticFrame:2];
    CVPixelBufferRef fxOut = [fx scaleBuffer:fxFrame error:&fxError];
    report[@"metalFX"] = @{
        @"created": @(fx != nil),
        @"outputWidth": @(fxOut ? (int)CVPixelBufferGetWidth(fxOut) : 0),
        @"outputHeight": @(fxOut ? (int)CVPixelBufferGetHeight(fxOut) : 0),
        @"error": fxError.localizedDescription ?: @"",
    };
    if (fxOut) CVPixelBufferRelease(fxOut);
    CVPixelBufferRelease(fxFrame);
    dispatch_sync(processor->_q, ^{
        processor->_probeAggregateOnly = NO;
        processor->_probeWindowOpen = NO;
        [processor->_probeOutputs removeAllObjects];
    });
    NSUInteger beforeStop = processor->_probeOutputs.count;
    [processor stop];
    CVPixelBufferRef stale = [self syntheticFrame:3];
    [processor pushPixelBuffer:stale ptsNum:0 ptsDen:30 host:SPHostNow() generation:probeGeneration];
    CVPixelBufferRelease(stale);
    usleep(200000);
    BOOL staleOK = processor->_probeOutputs.count == beforeStop;
    report[@"staleIgnored"] = @(staleOK);
    NSMutableDictionary *combination = [report[@"combination"] mutableCopy];
    combination[@"staleIgnored"] = @(staleOK);
    combination[@"ok"] = @([combination[@"ok"] boolValue] && staleOK);
    report[@"combination"] = combination;
    if (probeWindow) {
        dispatch_async(dispatch_get_main_queue(), ^{ [probeWindow orderOut:nil]; });
    }
    return report;
}

@end
