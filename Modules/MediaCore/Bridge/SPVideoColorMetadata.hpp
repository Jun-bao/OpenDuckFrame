#pragma once

#import <CoreVideo/CoreVideo.h>

extern "C" {
#include <libavutil/pixfmt.h>
}

namespace sp {

// Shared FFmpeg -> CoreVideo color-description mapping. VideoToolbox format
// descriptions and FFmpeg-created pixel buffers must use the same tags: VT
// does not reliably recover VUI colorimetry on its own, while Core Image needs
// these attachments to interpret software-decoded YUV surfaces correctly.
// A stream declaration is authoritative even when CoreVideo has no equivalent
// tag for it. Only AVCOL_*_UNSPECIFIED delegates that individual field to the
// decoded frame; an unsupported explicit stream value must not be silently
// replaced by a frame value with different semantics.
inline constexpr int spAuthoritativeColorValue(int streamValue,
                                                int frameValue,
                                                int unspecifiedValue) {
    return streamValue != unspecifiedValue ? streamValue : frameValue;
}

inline CFStringRef spCVColorPrimaries(int value) {
    switch (value) {
        case AVCOL_PRI_BT709:     return kCVImageBufferColorPrimaries_ITU_R_709_2;
        case AVCOL_PRI_BT470BG:   return kCVImageBufferColorPrimaries_EBU_3213;
        case AVCOL_PRI_SMPTE170M:
        case AVCOL_PRI_SMPTE240M: return kCVImageBufferColorPrimaries_SMPTE_C;
        case AVCOL_PRI_BT2020:    return kCVImageBufferColorPrimaries_ITU_R_2020;
        case AVCOL_PRI_SMPTE432:  return kCVImageBufferColorPrimaries_P3_D65;
        case AVCOL_PRI_SMPTE431:  return kCVImageBufferColorPrimaries_DCI_P3;
        default:                  return nullptr;
    }
}

inline CFStringRef spCVTransferFunction(int value) {
    switch (value) {
        case AVCOL_TRC_BT709:
        case AVCOL_TRC_SMPTE170M:    return kCVImageBufferTransferFunction_ITU_R_709_2;
        case AVCOL_TRC_SMPTE240M:    return kCVImageBufferTransferFunction_SMPTE_240M_1995;
        case AVCOL_TRC_LINEAR:       return kCVImageBufferTransferFunction_Linear;
        case AVCOL_TRC_IEC61966_2_1: return kCVImageBufferTransferFunction_sRGB;
        case AVCOL_TRC_BT2020_10:
        case AVCOL_TRC_BT2020_12:    return kCVImageBufferTransferFunction_ITU_R_2020;
        case AVCOL_TRC_SMPTE2084:    return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
        case AVCOL_TRC_SMPTE428:     return kCVImageBufferTransferFunction_SMPTE_ST_428_1;
        case AVCOL_TRC_ARIB_STD_B67: return kCVImageBufferTransferFunction_ITU_R_2100_HLG;
        default:                     return nullptr;
    }
}

enum : int {
    kSPTransferBT709  = 0,
    kSPTransferPQ     = 1, // SMPTE ST 2084
    kSPTransferHLG    = 2, // ARIB STD-B67
    kSPTransferLinear = 3,
    kSPTransferSRGB   = 4, // IEC 61966-2-1
    kSPTransferGamma22 = 5,
    kSPTransferGamma28 = 6,
    kSPTransferST428   = 7,
};

struct SPRendererTransfer {
    int index;
    bool hdr;

    constexpr bool operator==(const SPRendererTransfer &) const = default;
};

inline constexpr SPRendererTransfer spRendererTransferForAVTrc(int trc) {
    switch (trc) {
        case AVCOL_TRC_SMPTE2084:    return { kSPTransferPQ,     true  };
        case AVCOL_TRC_ARIB_STD_B67: return { kSPTransferHLG,    true  };
        case AVCOL_TRC_LINEAR:       return { kSPTransferLinear, false };
        case AVCOL_TRC_IEC61966_2_1: return { kSPTransferSRGB,   false };
        case AVCOL_TRC_GAMMA22:      return { kSPTransferGamma22, false };
        case AVCOL_TRC_GAMMA28:      return { kSPTransferGamma28, false };
        case AVCOL_TRC_SMPTE428:     return { kSPTransferST428,   false };

        default:                     return { kSPTransferBT709,  false };
    }
}

inline SPRendererTransfer spRendererTransferForCVTrc(CFStringRef trc) {
    if (!trc) return { kSPTransferBT709, false };
    if (CFEqual(trc, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ))
        return { kSPTransferPQ, true };
    if (CFEqual(trc, kCVImageBufferTransferFunction_ITU_R_2100_HLG))
        return { kSPTransferHLG, true };
    if (CFEqual(trc, kCVImageBufferTransferFunction_Linear))
        return { kSPTransferLinear, false };
    if (CFEqual(trc, kCVImageBufferTransferFunction_sRGB))
        return { kSPTransferSRGB, false };
    if (CFEqual(trc, kCVImageBufferTransferFunction_SMPTE_ST_428_1))
        return { kSPTransferST428, false };

    return { kSPTransferBT709, false };
}

enum SPRendererSourceGamut : int {
    kSPGamutBT709  = 0,
    kSPGamutBT2020 = 1,
    kSPGamutSMPTEC = 2, // SMPTE 170M / 240M（NTSC）
    kSPGamutEBU    = 3, // BT.470BG / EBU Tech 3213（PAL）
    kSPGamutP3     = 4, // P3-D65（SMPTE 432）
    kSPGamutDCIP3  = 5,
};

inline constexpr int spRendererSourceGamutForAV(int primaries, int matrix) {
    switch (primaries) {
        case AVCOL_PRI_BT2020:    return kSPGamutBT2020;
        case AVCOL_PRI_SMPTE170M:
        case AVCOL_PRI_SMPTE240M: return kSPGamutSMPTEC;
        case AVCOL_PRI_BT470BG:   return kSPGamutEBU;
        case AVCOL_PRI_SMPTE432:  return kSPGamutP3;
        case AVCOL_PRI_SMPTE431:  return kSPGamutDCIP3;
        case AVCOL_PRI_BT709:     return kSPGamutBT709;
        default: break;
    }
    const bool declared = primaries > 0 && primaries != AVCOL_PRI_UNSPECIFIED;
    if (!declared && (matrix == AVCOL_SPC_BT2020_NCL || matrix == AVCOL_SPC_BT2020_CL)) {
        return kSPGamutBT2020;
    }
    return kSPGamutBT709;
}

inline int spRendererSourceGamutForCV(CFStringRef primaries) {
    if (!primaries) return kSPGamutBT709;
    if (CFEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_2020)) return kSPGamutBT2020;
    if (CFEqual(primaries, kCVImageBufferColorPrimaries_SMPTE_C))    return kSPGamutSMPTEC;
    if (CFEqual(primaries, kCVImageBufferColorPrimaries_EBU_3213))   return kSPGamutEBU;
    if (CFEqual(primaries, kCVImageBufferColorPrimaries_P3_D65))     return kSPGamutP3;
    if (CFEqual(primaries, kCVImageBufferColorPrimaries_DCI_P3))     return kSPGamutDCIP3;
    return kSPGamutBT709;
}

inline constexpr int spSDRLayerTagKey(int sourceGamut, int transfer, bool hasHdr) {
    return hasHdr ? 0 : 1 + (sourceGamut & 7) + (transfer & 0xF) * 8;
}
inline constexpr int spSDRLayerTagKeyGamut(int key) { return (key - 1) & 7; }
inline constexpr int spSDRLayerTagKeyTransfer(int key) { return (key - 1) >> 3; }
static_assert(spSDRLayerTagKey(kSPGamutBT709, kSPTransferBT709, false) == 1);
static_assert(spSDRLayerTagKey(kSPGamutBT2020, kSPTransferPQ, true) == 0);
static_assert(spSDRLayerTagKeyGamut(spSDRLayerTagKey(kSPGamutDCIP3, kSPTransferGamma28, false)) == kSPGamutDCIP3);
static_assert(spSDRLayerTagKeyTransfer(spSDRLayerTagKey(kSPGamutDCIP3, kSPTransferGamma28, false)) == kSPTransferGamma28);

inline CFStringRef spCVColorPrimariesForGamut(int gamut) {
    switch (gamut) {
        case kSPGamutBT2020: return kCVImageBufferColorPrimaries_ITU_R_2020;
        case kSPGamutSMPTEC: return kCVImageBufferColorPrimaries_SMPTE_C;
        case kSPGamutEBU:    return kCVImageBufferColorPrimaries_EBU_3213;
        case kSPGamutP3:     return kCVImageBufferColorPrimaries_P3_D65;
        case kSPGamutDCIP3:  return kCVImageBufferColorPrimaries_DCI_P3;
        default:             return kCVImageBufferColorPrimaries_ITU_R_709_2;
    }
}

inline CFStringRef spCVTransferFunctionForTransfer(int transfer) {
    switch (transfer) {
        case kSPTransferPQ:      return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
        case kSPTransferHLG:     return kCVImageBufferTransferFunction_ITU_R_2100_HLG;
        case kSPTransferLinear:  return kCVImageBufferTransferFunction_Linear;
        case kSPTransferSRGB:    return kCVImageBufferTransferFunction_sRGB;
        case kSPTransferGamma22:
        case kSPTransferGamma28: return kCVImageBufferTransferFunction_UseGamma;
        case kSPTransferST428:   return kCVImageBufferTransferFunction_SMPTE_ST_428_1;
        default:                 return kCVImageBufferTransferFunction_ITU_R_709_2;
    }
}
inline constexpr double spCVGammaLevelForTransfer(int transfer) {
    return transfer == kSPTransferGamma22 ? 2.2 : transfer == kSPTransferGamma28 ? 2.8 : 0.0;
}

inline CFStringRef spCVYCbCrMatrix(int value) {
    switch (value) {
        case AVCOL_SPC_BT709:      return kCVImageBufferYCbCrMatrix_ITU_R_709_2;
        case AVCOL_SPC_BT470BG:
        case AVCOL_SPC_SMPTE170M:  return kCVImageBufferYCbCrMatrix_ITU_R_601_4;
        case AVCOL_SPC_SMPTE240M:  return kCVImageBufferYCbCrMatrix_SMPTE_240M_1995;
        case AVCOL_SPC_BT2020_NCL:
        case AVCOL_SPC_BT2020_CL:  return kCVImageBufferYCbCrMatrix_ITU_R_2020;
        default:                   return nullptr;
    }
}

struct SPCVColorMetadata {
    CFStringRef primaries;
    CFStringRef transferFunction;
    CFStringRef yCbCrMatrix;
};

inline SPCVColorMetadata spResolveCVColorMetadata(int streamPrimaries,
                                                   int streamTransfer,
                                                   int streamMatrix,
                                                   int framePrimaries,
                                                   int frameTransfer,
                                                   int frameMatrix) {
    const int primaries = spAuthoritativeColorValue(
        streamPrimaries, framePrimaries, AVCOL_PRI_UNSPECIFIED);
    const int transfer = spAuthoritativeColorValue(
        streamTransfer, frameTransfer, AVCOL_TRC_UNSPECIFIED);
    const int matrix = spAuthoritativeColorValue(
        streamMatrix, frameMatrix, AVCOL_SPC_UNSPECIFIED);
    return {
        spCVColorPrimaries(primaries),
        spCVTransferFunction(transfer),
        spCVYCbCrMatrix(matrix),
    };
}

} // namespace sp
