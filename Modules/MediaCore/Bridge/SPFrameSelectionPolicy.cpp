#include "SPFrameSelectionPolicy.hpp"

namespace sp {

bool spIsStaleSyntheticFrame(
    const SPFrameCandidateMetadata &candidate,
    const SPSyntheticFramePolicy &policy) noexcept {
    return policy.enforce && candidate.synthetic &&
           (!policy.acceptsSynthetic ||
            candidate.interpolationEpoch != policy.interpolationEpoch);
}

SPFrameSelectionDecision spEvaluateSteadyFrame(
    const SPFrameCandidateMetadata &candidate,
    const SPSteadyFrameSelectionContext &context) noexcept {
    // Policy-stale synthetic frames must be removed even when their PTS is in
    // the future; otherwise they can indefinitely block a current source frame.
    if (spIsStaleSyntheticFrame(candidate, context.syntheticPolicy)) {
        return {SPFrameSelectionAction::DropStaleInterpolationPolicy};
    }

    const bool currentGeneration =
        candidate.generation == context.currentGeneration;

    const bool filtersToSeekTarget = context.seekTargetUs >= 0;
    if (currentGeneration && !filtersToSeekTarget &&
        candidate.ptsUs > context.presentUs) {
        if (!context.hasSelectedFrame &&
            candidate.ptsUs - context.presentUs >
                context.reanchorThresholdUs) {
            return {SPFrameSelectionAction::ReanchorClock};
        }
        return {SPFrameSelectionAction::HoldFuture};
    }

    // A future PTS from an old generation is stale, not a reason to hold the
    // current queue. Generation validation intentionally follows the future
    // check that is restricted to current-generation candidates above.
    if (!currentGeneration) {
        return {SPFrameSelectionAction::DropStaleGeneration};
    }
    if (filtersToSeekTarget && candidate.ptsUs < context.seekTargetUs) {
        return {SPFrameSelectionAction::DropBeforeSeekTarget};
    }

    if (context.hasSelectedFrame && !filtersToSeekTarget &&
        context.lateReplaceThresholdUs > 0 &&
        candidate.ptsUs + context.lateReplaceThresholdUs > context.presentUs) {
        return {SPFrameSelectionAction::HoldFuture};
    }
    return {SPFrameSelectionAction::Select, filtersToSeekTarget};
}

SPFrameSelectionDecision spEvaluateImmediateFrame(
    const SPFrameCandidateMetadata &candidate,
    const SPImmediateFrameSelectionContext &context) noexcept {
    if (spIsStaleSyntheticFrame(candidate, context.syntheticPolicy)) {
        return {SPFrameSelectionAction::DropStaleInterpolationPolicy};
    }
    if (candidate.generation != context.currentGeneration) {
        return {SPFrameSelectionAction::DropStaleGeneration};
    }
    if (context.minimumPtsUs >= 0 && candidate.ptsUs >= 0 &&
        candidate.ptsUs < context.minimumPtsUs) {
        return {SPFrameSelectionAction::DropBeforeMinimumPTS};
    }
    return {SPFrameSelectionAction::Select};
}

SPFrameSelectionDecision spEvaluateStepFrame(
    const SPFrameCandidateMetadata &candidate,
    const SPStepFrameSelectionContext &context) noexcept {
    if (candidate.generation != context.currentGeneration) {
        return {SPFrameSelectionAction::DropStaleGeneration};
    }
    if (candidate.synthetic) {
        return {SPFrameSelectionAction::DropSyntheticForStep};
    }

    if (candidate.ptsUs <= context.lastPresentedPtsUs) {
        return {SPFrameSelectionAction::DropBeforeMinimumPTS};
    }
    return {SPFrameSelectionAction::Select};
}

SPFrameSelectionDecision spEvaluateSeekPreviewFrame(
    const SPFrameCandidateMetadata &candidate,
    const SPSeekPreviewSelectionContext &context) noexcept {
    if (spIsStaleSyntheticFrame(candidate, context.syntheticPolicy)) {
        return {SPFrameSelectionAction::DropStaleInterpolationPolicy};
    }
    if (candidate.generation < context.seekBurstBaseGeneration) {
        return {SPFrameSelectionAction::DropBeforeSeekBurst};
    }
    return {SPFrameSelectionAction::Select};
}

SPSeekSettlementDecision spEvaluateSeekSettlement(
    const SPFrameCandidateMetadata &candidate,
    int64_t currentGeneration,
    int64_t seekTargetUs) noexcept {
    if (candidate.generation != currentGeneration) return {};
    if (seekTargetUs >= 0) {
        const bool reached = candidate.ptsUs >= seekTargetUs;
        return {reached, reached, false};
    }
    // Coarse seeks commit the actual keyframe PTS and must reanchor. Precise
    // seeks keep the sample-trimmed audio target even if the selected video
    // frame lands slightly after it.
    return {true, false, true};
}

} // namespace sp
