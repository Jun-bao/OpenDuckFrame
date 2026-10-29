#pragma once

#include <cstdint>

namespace sp {

// Stable status codes consumed by the UI and the reliability logs
// ([MEMCPolicy] code=N). Keep the decision itself resource-free; SPPlayerCore
// remains the sole owner of queues, CVPixelBuffers and engine lifetime.
//
// Codes come from two sources that consumers must distinguish:
// - routing codes returned by spEvaluateInterpolationRouting;
// - module-state codes (Preparing, ResourceUnavailable) published directly by
//   SPFrameBudgetGenerator with their own formatted status text.
// Retired values (10-13, 16, 18, 19: legacy VTME health/admission states) stay
// reserved so historical logs cannot be misread.
enum class SPInterpolationPolicyCode : int {
    Active = 0,
    Off = 1,
    Unavailable = 2,
    DynamicHDR = 3,
    Interlaced = 4,
    FastPlayback = 5,
    DisplayCadence = 6,
    PixelFormat = 7,
    MissingIOSurface = 8,
    // Engine could not be built for this geometry, or one session plus the
    // shortest lookahead ring does not fit the memory budget.
    ResourceUnavailable = 9,
    ScanUnknown = 14,
    ChromaSiting = 15,
    // Engine being built or lookahead ring still filling: original frames pass
    // through, interpolation starts once the ring is nearly full.
    Preparing = 17,
    // Current product ceiling, independent of measured device throughput.
    ResolutionLimit = 20,
    // Distinguish resource failures without parsing a localized diagnostic.
    MemoryLimit = 21,
    EngineFailed = 22,
};

// Include UHD and DCI 4K in either orientation. Check both dimensions instead
// of pixel count so a 5120x1440 video cannot pass as a smaller-than-4K frame.
// Unknown geometry is left to the later decoded-frame check.
constexpr bool spInterpolationExceeds4KLimit(uint32_t width,
                                           uint32_t height) noexcept {
    if (width == 0 || height == 0) return false;
    const uint32_t longEdge = width > height ? width : height;
    const uint32_t shortEdge = width > height ? height : width;
    return longEdge > 4096 || shortEdge > 2160;
}

constexpr bool spInterpolationPolicyIsActive(
    SPInterpolationPolicyCode code) noexcept {
    return code == SPInterpolationPolicyCode::Active;
}

struct SPInterpolationRoutingContext {
    bool requested = false;
    bool apiAvailable = false;
    bool dynamicHDRUnsafe = false;
    bool interlaced = false;
    bool scanUnknown = false;
    double playbackRate = 1.0;
    double videoFPS = 0.0;
    double displayMaximumFPS = 60.0;
    bool enforceDisplayLimit = true;
    uint32_t width = 0;
    uint32_t height = 0;
    bool supportedPixelFormat = false;
    bool supportedChromaSiting = false;
    bool hasIOSurface = false;
};

constexpr SPInterpolationPolicyCode spEvaluateInterpolationRouting(
    const SPInterpolationRoutingContext &context) noexcept {
    if (!context.requested) return SPInterpolationPolicyCode::Off;
    if (!context.apiAvailable) return SPInterpolationPolicyCode::Unavailable;
    if (spInterpolationExceeds4KLimit(context.width, context.height)) {
        return SPInterpolationPolicyCode::ResolutionLimit;
    }
    if (context.dynamicHDRUnsafe) return SPInterpolationPolicyCode::DynamicHDR;
    if (context.interlaced) return SPInterpolationPolicyCode::Interlaced;
    if (context.scanUnknown) return SPInterpolationPolicyCode::ScanUnknown;
    if (context.playbackRate > 1.0001) {
        return SPInterpolationPolicyCode::FastPlayback;
    }
    if (context.enforceDisplayLimit && context.videoFPS > 0.0 &&
        context.videoFPS * 2.0 * context.playbackRate >
            context.displayMaximumFPS + 0.5) {
        return SPInterpolationPolicyCode::DisplayCadence;
    }
    // Within the 4K ceiling, throughput affects coverage rather than admission.
    // Frame compatibility remains a separate correctness gate.
    if (!context.supportedPixelFormat) {
        return SPInterpolationPolicyCode::PixelFormat;
    }
    if (!context.supportedChromaSiting) {
        return SPInterpolationPolicyCode::ChromaSiting;
    }
    if (!context.hasIOSurface) {
        return SPInterpolationPolicyCode::MissingIOSurface;
    }
    return SPInterpolationPolicyCode::Active;
}

// UTF-8 literals are intentionally centralized beside the stable codes. Codes
// whose text carries runtime values (Active, DisplayCadence, Preparing,
// ResourceUnavailable, MemoryLimit, EngineFailed) are formatted by their
// publisher and return nullptr.
constexpr const char *spInterpolationPolicyStatusUTF8(
    SPInterpolationPolicyCode code) noexcept {
    switch (code) {
        case SPInterpolationPolicyCode::Off:
            return "已关闭";
        case SPInterpolationPolicyCode::Unavailable:
            return "需要 macOS 26 或更高版本";
        case SPInterpolationPolicyCode::DynamicHDR:
            return "当前 Dolby Vision 配置没有已验证的兼容基础层";
        case SPInterpolationPolicyCode::Interlaced:
            return "隔行视频需先去隔行，已旁路";
        case SPInterpolationPolicyCode::FastPlayback:
            return "播放速度超过 1× 时不可插帧，回到 1× 后自动恢复";
        case SPInterpolationPolicyCode::PixelFormat:
            return "不支持当前解码像素格式";
        case SPInterpolationPolicyCode::MissingIOSurface:
            return "解码帧不是 IOSurface，无法走零拷贝路径";
        case SPInterpolationPolicyCode::ScanUnknown:
            return "正在确认视频扫描方式，等待关键帧";
        case SPInterpolationPolicyCode::ChromaSiting:
            return "当前色度采样位置尚未验证，已保留原始帧率";
        case SPInterpolationPolicyCode::ResolutionLimit:
            return "视频分辨率超过插帧上限（长边 4096，短边 2160）";
        case SPInterpolationPolicyCode::Active:
        case SPInterpolationPolicyCode::DisplayCadence:
        case SPInterpolationPolicyCode::ResourceUnavailable:
        case SPInterpolationPolicyCode::MemoryLimit:
        case SPInterpolationPolicyCode::EngineFailed:
        case SPInterpolationPolicyCode::Preparing:
            return nullptr;
    }
    return nullptr;
}

} // namespace sp
