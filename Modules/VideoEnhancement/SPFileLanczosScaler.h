#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN
/// Single-in-flight SDR NV12 Lanczos. The caller owns the returned +1 buffer.
/// It preserves the input's color attachments and never substitutes a different scaler.
@interface SPFileLanczosScaler : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device width:(int)width height:(int)height error:(NSError **)error;
- (BOOL)submit:(CVPixelBufferRef)source ptsUs:(int64_t)ptsUs completion:(void (^)(CVPixelBufferRef _Nullable, NSError * _Nullable))completion;
- (BOOL)submit:(CVPixelBufferRef)source completion:(void (^)(CVPixelBufferRef _Nullable, NSError * _Nullable))completion;
@property (nonatomic, readonly) int outputWidth;
@property (nonatomic, readonly) int outputHeight;
@end
NS_ASSUME_NONNULL_END
