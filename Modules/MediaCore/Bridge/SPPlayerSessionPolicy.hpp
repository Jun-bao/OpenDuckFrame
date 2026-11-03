#pragma once

#include <cstddef>
#include <cstdint>

namespace sp {

// Main-queue callbacks originating from a playback worker may execute after
// stop() has joined that worker and a new open has already started.  Keep the
// token comparison independent from Objective-C/Core state so every such
// callback uses the same fail-closed rule.
inline bool spPlayerSessionIsCurrent(int64_t callbackOpenGeneration,
                                     int64_t currentOpenGeneration) noexcept {
    return callbackOpenGeneration == currentOpenGeneration;
}

// Seek generations are scoped to one open session and may be reused by a
// later file. A delayed seek callback is current only when both tokens match.
inline bool spPlayerSeekCallbackIsCurrent(
        int64_t callbackOpenGeneration,
        int64_t currentOpenGeneration,
        int64_t callbackSeekGeneration,
        int64_t currentSeekGeneration) noexcept {
    return spPlayerSessionIsCurrent(callbackOpenGeneration,
                                    currentOpenGeneration) &&
           callbackSeekGeneration == currentSeekGeneration;
}

inline bool spSpeculativeSubmitAllowed(uint64_t acceptedFramesInSubmitEpoch,
                                       int64_t racerOpenGeneration,
                                       int64_t currentOpenGeneration,
                                       int64_t rendererConfiguredOpenGeneration,
                                       bool revokedBySeek) noexcept {
    if (!spPlayerSessionIsCurrent(racerOpenGeneration, currentOpenGeneration)) {
        return false;
    }
    if (rendererConfiguredOpenGeneration != racerOpenGeneration) return false;
    if (revokedBySeek) return false;
    return acceptedFramesInSubmitEpoch == 0;
}

// A requested audio track is reflected immediately while the demux thread is
// applying the seek transaction.  Once no request is pending, only the
// explicitly published track may cross back to the main thread.
inline int spResolvePublishedAudioTrack(int pendingTrack,
                                        int publishedTrack) noexcept {
    return pendingTrack >= 0 ? pendingTrack : publishedTrack;
}

// The MKV index warmer performs 9 MiB of deliberately non-sequential I/O.
// Keep its admission independent from the demux loop so the complete rule is
// deterministic and reviewable instead of growing another set of loosely
// related conditions in SPPlayerCore.mm.
struct SPIndexPrefetchAdmissionState {
    bool alreadyIssued = false;
    bool currentOpenSession = false;
    bool audioOnly = false;
    bool firstFramePending = true;

    bool committedThisSession = false;
    int64_t submittedVideoGeneration = -1;
    int64_t currentSeekGeneration = 0;
    bool seekPending = false;
    bool seekFramePending = false;
    bool catchUpPending = false;
    size_t videoPacketDepth = 0;
    size_t videoPacketCapacity = 0;
    int64_t nowUs = 0;
    int64_t lastPresentationStarveUs = 0;
};

inline constexpr int64_t kSPIndexPrefetchStarveQuietUs = 3000000;

// A two-packet floor matters for the memory-bounded high-bitrate queues whose
// capacity can be as small as two: capacity*3/4 truncates to one there, which
// is not a healthy runway. For normal queues this is the established 75% mark.
inline size_t spIndexPrefetchHealthyPacketDepth(size_t capacity) noexcept {
    if (capacity == 0) return 0;
    const size_t threeQuarters = capacity * 3 / 4;
    const size_t floor = capacity < 2 ? capacity : 2;
    return threeQuarters > floor ? threeQuarters : floor;
}

inline bool spShouldIssueIndexPrefetch(
        const SPIndexPrefetchAdmissionState &state) noexcept {
    if (state.alreadyIssued || !state.currentOpenSession || state.audioOnly ||
        state.firstFramePending) {
        return false;
    }
    // A session-level "ever presented" bit is insufficient after a seek. The
    // accepted renderer submission must belong to the current seek generation.
    if (state.submittedVideoGeneration != state.currentSeekGeneration) return false;
    if (!state.committedThisSession) return false;
    if (state.seekPending || state.seekFramePending || state.catchUpPending) return false;
    const size_t healthy =
        spIndexPrefetchHealthyPacketDepth(state.videoPacketCapacity);
    if (healthy == 0 || state.videoPacketDepth < healthy) return false;
    if (state.lastPresentationStarveUs > 0 &&
        (state.nowUs <= state.lastPresentationStarveUs ||
         state.nowUs - state.lastPresentationStarveUs <=
             kSPIndexPrefetchStarveQuietUs)) {
        return false;
    }
    return true;
}

// Background directory-catalogue listing asks the same question as the index
// prefetch — "is background disk I/O safe right now?" — so the complete rule
// lives here beside it instead of as hand-copied early returns in
// SPPlayerCore.mm (two such copies drifted into real bugs: the audio-only
// exemption sat behind a firstFramePending check that pure-audio sessions
// never clear, and short files could never satisfy the runway after demux
// EOF). The caller fills every field honestly; the special admits are states
// where playback consumes no packet runway at all.
struct SPDirectoryScanAdmissionState {
    bool running = false;
    bool playing = false;
    bool paused = false;
    bool ended = false;
    bool audioOnly = false;
    bool demuxAtEOF = false;
    SPIndexPrefetchAdmissionState prefetch;
};

inline bool spShouldAdmitBackgroundDirectoryScan(
        const SPDirectoryScanAdmissionState &state) noexcept {
    if (!state.running || !(state.playing || state.paused || state.ended)) {
        return false;
    }
    if (state.prefetch.seekPending || state.prefetch.seekFramePending ||
        state.prefetch.catchUpPending) {
        return false;
    }
    // Pure audio has no video generation/runway and never clears
    // firstFramePending, so this admit must precede those checks. Its demux
    // path is naturally bounded by the audio ring; user seek/hover still
    // closes the Swift-side gate.
    if (state.audioOnly) return true;
    if (state.prefetch.firstFramePending) return false;
    if (state.prefetch.submittedVideoGeneration !=
        state.prefetch.currentSeekGeneration) {
        return false;
    }
    // Paused/Ended consume no packet runway; requiring 75% would starve
    // forever because the demux loop deliberately sleeps in both states.
    if (state.paused || state.ended) return true;
    // Demux EOF ends the runway requirement while still Playing: a short
    // file's total packet count may never reach the healthy depth, and the
    // runway exists to protect a demux thread that is no longer reading.
    if (state.demuxAtEOF) return true;
    return spShouldIssueIndexPrefetch(state.prefetch);
}

// Caption workers query this from outside the playback threads. Idle and failed
// sessions contribute no playback demand; Opening must remain protected even
// before _running becomes true. Audio-only sessions have no video first frame
// or presentation callback to clear video-specific pending bits.
enum class SPBackgroundPlaybackPhase { Idle, Opening, Ready, Playing, Paused, Ended, Failed };

struct SPBackgroundWorkAdmissionState {
    SPBackgroundPlaybackPhase phase = SPBackgroundPlaybackPhase::Opening;
    bool running = false;
    bool audioOnly = false;
    bool firstFramePending = true;
    bool seekPending = false;
    bool seekFramePending = false;
    bool catchUpPending = false;
    bool scrubHintPending = false;
    bool demuxSeekPending = false;
    bool audioWorkPending = false; // pending flush or sample trim
    bool audioAtEOF = false;       // decoded/drained for the current generation
    bool audioOutputRunning = false;
    int64_t bufferedAudioFrames = 0; // 48 kHz output frames, already rate-adjusted
    int64_t nowUs = 0;
    int64_t lastPresentationStarveUs = 0;
};

inline bool spShouldAdmitCaptionBackgroundWork(const SPBackgroundWorkAdmissionState &s) noexcept {
    using Phase = SPBackgroundPlaybackPhase;
    if (s.phase == Phase::Opening || s.phase == Phase::Ready) return false;
    if (s.phase == Phase::Idle || s.phase == Phase::Failed) return true;
    if (!s.running) return false; // running -> stopped transition is not stable Idle yet
    if (s.demuxSeekPending || s.scrubHintPending) return false;
    if (s.audioOnly) {
        // In paused audio, seekPending can outlive the real seek because its
        // clearing timer is stopped. Use demux/trim completion instead; a
        // seek to EOF may have no sample with which to consume the trim target.
        if (s.phase == Phase::Ended) return true;
        if (s.audioWorkPending && !s.audioAtEOF) return false;
        if (s.phase == Phase::Paused) return true;
        // Match the player's existing 100 ms audio-recovery floor. EOF is
        // already fully decoded; its shrinking tail needs no more file I/O.
        return s.audioAtEOF || (s.audioOutputRunning && s.bufferedAudioFrames >= 4800);
    }
    if (s.seekPending) return false;
    // Video can terminate without ever reaching a truncated seek target.
    // Ended acknowledges that interaction; obsolete catch-up must not veto
    // every other window's background task forever.
    if (s.phase == Phase::Ended) return true;
    if (s.firstFramePending || s.seekFramePending || s.catchUpPending) return false;
    if (s.phase == Phase::Paused) return true;
    return s.lastPresentationStarveUs <= 0 ||
        (s.nowUs > s.lastPresentationStarveUs &&
         s.nowUs - s.lastPresentationStarveUs > 3000000);
}

struct SPRateSwitchAnchorInputs {
    bool audioRunning = false;        // _audioOutput.isRunning
    bool audioClockHandedOff = false;
    bool audioOnlySession = false;
    int64_t currentMediaNowUs = 0;
    int64_t audioClockNowUs = 0;
    int64_t positionUs = 0;
    int64_t lastPresentedPtsUs = -1;
};

inline int64_t spRateSwitchClockAnchorUs(const SPRateSwitchAnchorInputs &in) noexcept {
    const bool liveClock = in.audioRunning && !in.audioClockHandedOff;
    if (liveClock) return in.currentMediaNowUs;
    if (in.audioOnlySession) return in.positionUs;
    if (!in.audioClockHandedOff) return in.audioClockNowUs;
    return in.lastPresentedPtsUs;
}

inline bool spShouldPrewarmDecodersAtLaunch(bool hasCLIFile,
                                            bool lastLaunchWasBare) noexcept {
    if (hasCLIFile) return false;
    return !lastLaunchWasBare;
}

inline bool spSpeculativeWarmShouldYield(bool realOpenIssued,
                                         bool warmAlreadyIssued) noexcept {
    return realOpenIssued || warmAlreadyIssued;
}

} // namespace sp
