#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Diagnostic BT.709 video-range NV12 to Lanczos-reduced BGRA adapter.
/// The caller serializes preparation and processing on its background worker.
@interface SPAirFusedPreprocessor : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                library:(id<MTLLibrary>)library
                            sourceWidth:(int)sourceWidth
                           sourceHeight:(int)sourceHeight
                            outputWidth:(int)outputWidth
                           outputHeight:(int)outputHeight
                                  error:(NSError **)error;

/// Returns after its one compute command has completed. The returned image has
/// independent pooled storage, retained for the caller, including a cached B.
- (nullable CVPixelBufferRef)processNV12Buffer:(CVPixelBufferRef)source
                                        error:(NSError **)error CF_RETURNS_RETAINED;
@end

NS_ASSUME_NONNULL_END
