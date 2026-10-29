#pragma once
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

// VT does not necessarily use destination buffer attachments to select its
// conversion matrix. Configure the session explicitly from the source frame.
// Unknown matrix is rejected for RGB->NV12 rather than mislabelling pixels.
static inline BOOL SPConfigureFileColorTransfer(VTPixelTransferSessionRef session, CVPixelBufferRef source, BOOL yuvDestination) {
    if (!session || !source) return NO;
    CFTypeRef matrix=CVBufferCopyAttachment(source,kCVImageBufferYCbCrMatrixKey,NULL);
    CFTypeRef primaries=CVBufferCopyAttachment(source,kCVImageBufferColorPrimariesKey,NULL);
    CFTypeRef transfer=CVBufferCopyAttachment(source,kCVImageBufferTransferFunctionKey,NULL);
    BOOL valid=(!yuvDestination || (matrix && CFGetTypeID(matrix)==CFStringGetTypeID()));
    if (matrix && CFGetTypeID(matrix)!=CFStringGetTypeID()) valid=NO;
    if (primaries && CFGetTypeID(primaries)!=CFStringGetTypeID()) valid=NO;
    if (transfer && CFGetTypeID(transfer)!=CFStringGetTypeID()) valid=NO;
    if (valid) {
        valid=VTSessionSetProperty(session,kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,yuvDestination?matrix:NULL)==noErr &&
              VTSessionSetProperty(session,kVTPixelTransferPropertyKey_DestinationColorPrimaries,primaries)==noErr &&
              VTSessionSetProperty(session,kVTPixelTransferPropertyKey_DestinationTransferFunction,transfer)==noErr;
    }
    if(matrix)CFRelease(matrix);if(primaries)CFRelease(primaries);if(transfer)CFRelease(transfer);
    return valid;
}
