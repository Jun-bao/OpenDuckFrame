#import "SPAppleVideoSR.h"
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor_SuperResolutionScaler.h>

static NSError *SPVideoSRError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"app.openduckframe.apple-video-sr" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static CVPixelBufferRef SPVideoSRBuffer(int width, int height, OSType format, NSDictionary *required) {
    NSDictionary *local=@{(id)kCVPixelBufferWidthKey:@(width),(id)kCVPixelBufferHeightKey:@(height),
      (id)kCVPixelBufferPixelFormatTypeKey:@(format),(id)kCVPixelBufferIOSurfacePropertiesKey:@{},
      (id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CFDictionaryRef attrs=NULL;
    if (CVPixelBufferCreateResolvedAttributesDictionary(NULL,(__bridge CFArrayRef)@[required,local],&attrs)!=kCVReturnSuccess || !attrs) return NULL;
    CVPixelBufferRef result=NULL; CVReturn code=CVPixelBufferCreate(NULL,width,height,format,attrs,&result); CFRelease(attrs);
    return code==kCVReturnSuccess ? result : NULL;
}
static OSType SPVideoSRFormat(NSDictionary *attrs, NSArray<NSNumber *> *fallback) {
    id value=attrs[(id)kCVPixelBufferPixelFormatTypeKey];
    NSArray *formats=[value isKindOfClass:NSNumber.class] ? @[value] : ([value isKindOfClass:NSArray.class] ? value : fallback);
    for (NSNumber *item in formats) if (item.unsignedIntValue==kCVPixelFormatType_64RGBAHalf) return kCVPixelFormatType_64RGBAHalf;
    return 0;
}
static void SPVideoSREnd(id processor) { if (@available(macOS 15.4,*)) [(VTFrameProcessor *)processor endSession]; }

@implementation SPAppleVideoSR {
    dispatch_queue_t _queue;
    id _processor;
    NSDictionary *_sourceAttributes, *_destinationAttributes;
    VTPixelTransferSessionRef _transfer;
    CVPixelBufferRef _previousSource, _previousOutput;
    CMTime _previousPTS;
    OSType _sourceFormat, _destinationFormat;
    int _width,_height,_outWidth,_outHeight;
    BOOL _inflight;
    uint64_t _epoch, _randomSubmissions, _sequentialSubmissions;
    BOOL _hasPublishedHistory, _lastHadPrevious, _lastHadPreviousOutput;
}
- (instancetype)init {
    if (!(self=[super init])) return nil;
    _queue=dispatch_queue_create("app.openduckframe.apple-video-sr",DISPATCH_QUEUE_SERIAL);
    _previousPTS=kCMTimeInvalid;
    return self;
}
- (void)dealloc {
    if (_previousSource) CVPixelBufferRelease(_previousSource);
    if (_previousOutput) CVPixelBufferRelease(_previousOutput);
    if (_transfer) CFRelease(_transfer);
}
+ (BOOL)isReadyForWidth:(int)width height:(int)height scale:(int)scale {
    if (width<2 || height<2 || scale<=1 || (int64_t)width*scale>3840 || (int64_t)height*scale>2160) return NO;
    if (@available(macOS 26.0,*)) {
        if (!VTSuperResolutionScalerConfiguration.supported || ![VTSuperResolutionScalerConfiguration.supportedScaleFactors containsObject:@(scale)]) return NO;
        VTSuperResolutionScalerConfiguration *config=[[VTSuperResolutionScalerConfiguration alloc]
          initWithFrameWidth:width frameHeight:height scaleFactor:scale inputType:VTSuperResolutionScalerConfigurationInputTypeVideo
          usePrecomputedFlow:NO qualityPrioritization:VTSuperResolutionScalerConfigurationQualityPrioritizationNormal revision:VTSuperResolutionScalerConfigurationRevision1];
        return config && config.configurationModelStatus==VTSuperResolutionScalerConfigurationModelStatusReady &&
          SPVideoSRFormat(config.sourcePixelBufferAttributes,config.frameSupportedPixelFormats) &&
          SPVideoSRFormat(config.destinationPixelBufferAttributes,config.frameSupportedPixelFormats);
    }
    return NO;
}
+ (NSArray<NSNumber *> *)readyScalesForWidth:(int)width height:(int)height {
    if (@available(macOS 26.0,*)) {
        NSMutableArray<NSNumber *> *ready=[NSMutableArray array];
        for(NSNumber *factor in VTSuperResolutionScalerConfiguration.supportedScaleFactors)
            if([self isReadyForWidth:width height:height scale:factor.intValue]) [ready addObject:factor];
        [ready sortUsingSelector:@selector(compare:)]; return ready;
    }
    return @[];
}
- (BOOL)prepareWidth:(int)width height:(int)height scale:(int)scale error:(NSError **)error {
    __block uint64_t seen;
    @synchronized(self) {
        if (_processor || _inflight) { if(error)*error=SPVideoSRError(1,@"视频超分会话仍在运行。"); return NO; }
        seen=_epoch;
    }
    if (![self.class isReadyForWidth:width height:height scale:scale]) {
        if(error)*error=SPVideoSRError(2,@"视频超分不支持此尺寸或倍率，模型未就绪，或超出输出预算。"); return NO;
    }
    if (@available(macOS 26.0,*)) {
        VTSuperResolutionScalerConfiguration *config=[[VTSuperResolutionScalerConfiguration alloc]
          initWithFrameWidth:width frameHeight:height scaleFactor:scale inputType:VTSuperResolutionScalerConfigurationInputTypeVideo
          usePrecomputedFlow:NO qualityPrioritization:VTSuperResolutionScalerConfigurationQualityPrioritizationNormal revision:VTSuperResolutionScalerConfigurationRevision1];
        if (!config || config.configurationModelStatus!=VTSuperResolutionScalerConfigurationModelStatusReady) { if(error)*error=SPVideoSRError(3,@"视频超分模型尚未就绪。"); return NO; }
        VTFrameProcessor *processor=[[VTFrameProcessor alloc] init]; NSError *local=nil;
        if (![processor startSessionWithConfiguration:config error:&local]) { if(error)*error=local ?: SPVideoSRError(4,@"视频超分会话创建失败。"); return NO; }
        @synchronized(self) {
            if (_processor || _inflight || _epoch!=seen) { SPVideoSREnd(processor); if(error)*error=SPVideoSRError(1,@"视频超分会话状态已改变。"); return NO; }
            _processor=processor; _sourceAttributes=[config.sourcePixelBufferAttributes copy]; _destinationAttributes=[config.destinationPixelBufferAttributes copy];
            _sourceFormat=SPVideoSRFormat(_sourceAttributes,config.frameSupportedPixelFormats); _destinationFormat=SPVideoSRFormat(_destinationAttributes,config.frameSupportedPixelFormats);
            _width=width;_height=height;_outWidth=width*scale;_outHeight=height*scale;_epoch++;
        }
        return YES;
    }
    if(error)*error=SPVideoSRError(5,@"视频超分需要 macOS 26 或更高版本。"); return NO;
}
- (void)clearHistoryOnQueue {
    if (_previousSource) { CVPixelBufferRelease(_previousSource); _previousSource=NULL; }
    if (_previousOutput) { CVPixelBufferRelease(_previousOutput); _previousOutput=NULL; }
    _previousPTS=kCMTimeInvalid;
    @synchronized(self){_hasPublishedHistory=NO;}
}
- (NSDictionary<NSString *,id> *)submissionDiagnostics {
    @synchronized(self){return @{@"random":@(_randomSubmissions),@"sequential":@(_sequentialSubmissions),@"history":@(_hasPublishedHistory ? 1 : 0),@"previous":@(_lastHadPrevious),@"previousOutput":@(_lastHadPreviousOutput)};}
}
- (BOOL)submitSource:(CVPixelBufferRef)source pts:(CMTime)pts discontinuity:(BOOL)discontinuity token:(uint64_t)token completion:(SPFRCEngineCompletion)completion {
    return [self submitSource:source pts:pts discontinuity:discontinuity randomOnly:NO token:token completion:completion];
}
- (BOOL)submitRandomSource:(CVPixelBufferRef)source pts:(CMTime)pts token:(uint64_t)token completion:(SPFRCEngineCompletion)completion {
    return [self submitSource:source pts:pts discontinuity:YES randomOnly:YES token:token completion:completion];
}
- (BOOL)submitSource:(CVPixelBufferRef)source pts:(CMTime)pts discontinuity:(BOOL)discontinuity randomOnly:(BOOL)randomOnly token:(uint64_t)token completion:(SPFRCEngineCompletion)completion {
    if (!source || !completion || !CMTIME_IS_NUMERIC(pts)) return NO;
    OSType format=CVPixelBufferGetPixelFormatType(source);
    if (format!=kCVPixelFormatType_32BGRA && format!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format!=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return NO;
    CFTypeRef tf=CVBufferCopyAttachment(source,kCVImageBufferTransferFunctionKey,NULL);
    BOOL hdr=tf && (CFEqual(tf,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)||CFEqual(tf,kCVImageBufferTransferFunction_ITU_R_2100_HLG));
    if(tf) CFRelease(tf); if(hdr) return NO;
    __block id processor=nil; __block uint64_t seen=0;
    @synchronized(self) {
        if (!_processor || _inflight || CVPixelBufferGetWidth(source)!=(size_t)_width || CVPixelBufferGetHeight(source)!=(size_t)_height) return NO;
        _inflight=YES;processor=_processor;seen=_epoch;
    }
    CVPixelBufferRetain(source);
    dispatch_async(_queue, ^{
        CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
        void (^finish)(CVPixelBufferRef,NSError *)=^(CVPixelBufferRef output,NSError *failure){
            BOOL stale; @synchronized(self){stale=seen!=self->_epoch;self->_inflight=NO;}
            if(stale && output){CVPixelBufferRelease(output);output=NULL;}
            if(stale){[self clearHistoryOnQueue];SPVideoSREnd(processor);failure=SPVideoSRError(6,@"视频超分结果属于已结束的会话。");}
            CVPixelBufferRelease(source);completion(token,output,MAX(0,CFAbsoluteTimeGetCurrent()-start),failure);
        };
        BOOL stale; @synchronized(self){stale=seen!=self->_epoch;}
        if(stale){finish(NULL,nil);return;}
        if (discontinuity || (CMTIME_IS_NUMERIC(self->_previousPTS) && CMTimeCompare(pts,self->_previousPTS)<=0)) [self clearHistoryOnQueue];
        CVPixelBufferRef input=SPVideoSRBuffer(self->_width,self->_height,self->_sourceFormat,self->_sourceAttributes);
        if(!self->_transfer)VTPixelTransferSessionCreate(NULL,&self->_transfer);
        if(!input || !self->_transfer || VTPixelTransferSessionTransferImage(self->_transfer,source,input)!=noErr){if(input)CVPixelBufferRelease(input);[self clearHistoryOnQueue];finish(NULL,SPVideoSRError(7,@"视频超分输入格式转换失败。"));return;}
        CVBufferPropagateAttachments(source,input);
        CVPixelBufferRef output=SPVideoSRBuffer(self->_outWidth,self->_outHeight,self->_destinationFormat,self->_destinationAttributes);
        if(!output){CVPixelBufferRelease(input);[self clearHistoryOnQueue];finish(NULL,SPVideoSRError(8,@"视频超分输出分配失败。"));return;}
        CVBufferPropagateAttachments(source,output);
        if (@available(macOS 26.0,*)) {
            VTFrameProcessorFrame *now=[[VTFrameProcessorFrame alloc] initWithBuffer:input presentationTimeStamp:pts];
            VTFrameProcessorFrame *dst=[[VTFrameProcessorFrame alloc] initWithBuffer:output presentationTimeStamp:pts];
            VTFrameProcessorFrame *previous=self->_previousSource?[[VTFrameProcessorFrame alloc] initWithBuffer:self->_previousSource presentationTimeStamp:self->_previousPTS]:nil;
            VTFrameProcessorFrame *previousOut=self->_previousOutput?[[VTFrameProcessorFrame alloc] initWithBuffer:self->_previousOutput presentationTimeStamp:self->_previousPTS]:nil;
            BOOL sequential=!randomOnly && previous && previousOut;
            VTSuperResolutionScalerParameters *params=[[VTSuperResolutionScalerParameters alloc] initWithSourceFrame:now previousFrame:previous previousOutputFrame:previousOut opticalFlow:nil submissionMode:sequential?VTSuperResolutionScalerParametersSubmissionModeSequential:VTSuperResolutionScalerParametersSubmissionModeRandom destinationFrame:dst];
            if(!params){CVPixelBufferRelease(input);CVPixelBufferRelease(output);[self clearHistoryOnQueue];finish(NULL,SPVideoSRError(9,@"视频超分参数创建失败。"));return;}
            @synchronized(self) { self->_lastHadPrevious=previous!=nil; self->_lastHadPreviousOutput=previousOut!=nil; if(sequential)self->_sequentialSubmissions++;else self->_randomSubmissions++; }
            [(VTFrameProcessor *)processor processWithParameters:params completionHandler:^(id<VTFrameProcessorParameters> result,NSError *failure){
                (void)result;
                dispatch_async(self->_queue, ^{
                    BOOL invalid; @synchronized(self){invalid=seen!=self->_epoch;}
                    if(failure || invalid){CVPixelBufferRelease(input);CVPixelBufferRelease(output);[self clearHistoryOnQueue];finish(NULL,failure);return;}
                    [self clearHistoryOnQueue];
                    if(randomOnly) CVPixelBufferRelease(input);
                    else {self->_previousSource=input;self->_previousOutput=CVPixelBufferRetain(output);self->_previousPTS=pts;@synchronized(self){self->_hasPublishedHistory=YES;}}
                    finish(output,nil);
                });
            }];
            return;
        }
        CVPixelBufferRelease(input);CVPixelBufferRelease(output);finish(NULL,SPVideoSRError(5,@"视频超分需要 macOS 26 或更高版本。"));
    });
    return YES;
}
- (void)invalidate {
    id old=nil;BOOL active;
    @synchronized(self){_epoch++;old=_processor;_processor=nil;active=_inflight;}
    dispatch_async(_queue, ^{[self clearHistoryOnQueue];if(old && !active)SPVideoSREnd(old);});
}
@end
