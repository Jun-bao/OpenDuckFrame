#ifndef SP_FRAME_SELECTION_POLICY_HPP
#define SP_FRAME_SELECTION_POLICY_HPP

#include <cstdint>

namespace sp {

// Resource-free metadata used by the main-thread presentation policy. Pixel
// buffers, queue ownership and rendering deliberately stay in SPPlayerCore.
struct SPFrameCandidateMetadata {
    int64_t ptsUs = 0;
    int64_t generation = 0;
    bool synthetic = false;
    uint64_t interpolationEpoch = 0;
};

// Off-path callers leave enforce=false. Motion-path callers enforce the
// requested mode and policy epoch only for synthetic frames; source frames are
// valid across an in-progress policy transition.
struct SPSyntheticFramePolicy {
    bool enforce = false;
    bool acceptsSynthetic = true;
    uint64_t interpolationEpoch = 0;
};

enum class SPFrameSelectionAction {
    Select,
    HoldFuture,
    ReanchorClock,
    DropStaleInterpolationPolicy,
    DropStaleGeneration,
    DropBeforeMinimumPTS,
    DropBeforeSeekTarget,
    DropBeforeSeekBurst,
    DropSyntheticForStep,
};

struct SPFrameSelectionDecision {
    SPFrameSelectionAction action = SPFrameSelectionAction::Select;
    // True only when a current-generation candidate satisfies an active
    // precise-seek target. The owner may then clear its target/catch-up state.
    bool reachesSeekTarget = false;
};

struct SPSteadyFrameSelectionContext {
    int64_t presentUs = 0;
    int64_t currentGeneration = 0;
    int64_t seekTargetUs = -1;
    bool hasSelectedFrame = false;
    int64_t reanchorThresholdUs = 1000000;

    int64_t lateReplaceThresholdUs = 0;
    SPSyntheticFramePolicy syntheticPolicy;
};

struct SPImmediateFrameSelectionContext {
    int64_t currentGeneration = 0;
    // Nonnegative targets, including time zero, enable catch-up filtering.
    int64_t minimumPtsUs = -1;
    SPSyntheticFramePolicy syntheticPolicy;
};

struct SPStepFrameSelectionContext {
    int64_t currentGeneration = 0;

    int64_t lastPresentedPtsUs = -1;
};

// Forward precise seeks already use the no-flash path: the rearmed decoder only
// admits frames at or after the target. Demuxer lower bounds and burst-generation
// filtering provide the same guarantee for relative seek sequences.
struct SPSeekPreviewSelectionContext {
    int64_t seekBurstBaseGeneration = 0;
    SPSyntheticFramePolicy syntheticPolicy;
};

struct SPSeekSettlementDecision {
    bool settles = false;
    bool reachesPreciseTarget = false;
    bool reanchorToCandidate = false;
};

bool spIsStaleSyntheticFrame(
    const SPFrameCandidateMetadata &candidate,
    const SPSyntheticFramePolicy &policy) noexcept;

SPFrameSelectionDecision spEvaluateSteadyFrame(
    const SPFrameCandidateMetadata &candidate,
    const SPSteadyFrameSelectionContext &context) noexcept;

SPFrameSelectionDecision spEvaluateImmediateFrame(
    const SPFrameCandidateMetadata &candidate,
    const SPImmediateFrameSelectionContext &context) noexcept;

SPFrameSelectionDecision spEvaluateStepFrame(
    const SPFrameCandidateMetadata &candidate,
    const SPStepFrameSelectionContext &context) noexcept;

SPFrameSelectionDecision spEvaluateSeekPreviewFrame(
    const SPFrameCandidateMetadata &candidate,
    const SPSeekPreviewSelectionContext &context) noexcept;

SPSeekSettlementDecision spEvaluateSeekSettlement(
    const SPFrameCandidateMetadata &candidate,
    int64_t currentGeneration,
    int64_t seekTargetUs) noexcept;

} // namespace sp

#endif // SP_FRAME_SELECTION_POLICY_HPP
