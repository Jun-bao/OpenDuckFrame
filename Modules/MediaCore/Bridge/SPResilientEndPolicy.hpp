// OpenDuckFrame - pure decision rules for end-of-content and the audio decode failure signal
//
// Input to verdict only: no state publication, audio device, clock or DisplayLink work. The three call sites keep
// their side effects on their own threads. The rules are covered by the end-policy unit tests.
//   - Video path: reaching the declared duration ends normally (the position snaps to the duration); audio still
//     playing waits for the audio to finish. When video is exhausted, no audio remains and the position is more
//     than 0.5 s short of the declared duration, the outcome depends on evidence. Independent damage or truncation
//     evidence in this session yields PartialEnded (the declared duration is kept and the usable end is recorded).
//     Without evidence, after 0.7 s with no new content the declared duration is rewritten to the actual position
//     and playback ends normally. A declared duration longer than the content is not evidence of damage:
//     bitrate-estimated durations (ADTS AAC, VBR MP3 without a Xing header) and durations that include an unplayed
//     track (a Matroska segment duration covering a longer subtitle track) overshoot on healthy files.
//   - Audio only: a drained EOF plus an empty ring ends. A content end more than 0.5 s short of the declared
//     duration is PartialEnded only with independent evidence; otherwise the position is the declared duration.
//   - Audio decode signal: a definite error with no output, or output whose frames are all concealed, counts as a
//     failure; six in a row request recovery; any clean output resets the run and marks the session as voiced.
#pragma once

#include <algorithm>
#include <cstdint>

namespace sp {

struct EndVerdict {
    bool ended = false;
    bool partial = false;
    int64_t positionUs = -1;
    int64_t availableEndUs = -1;
    int64_t durationUs = -1;
    bool holding = false;
};

constexpr double kTruncationSettleSec = 0.7;

inline EndVerdict evaluateVideoEnd(bool exhausted, bool audioBusy, double positionSec, double durationSec,
                                   bool damageEvidence, double heldSec) {
    EndVerdict v;
    if (!exhausted) return v;
    const bool nearEnd = positionSec + 0.5 >= durationSec;
    if (nearEnd) {
        v.ended = true;
        v.positionUs = (int64_t)(durationSec * 1e6);
        return v;
    }
    if (audioBusy) return v;
    const int64_t atUs = (int64_t)(std::max(positionSec, 0.0) * 1e6);
    if (damageEvidence) {
        v.ended = v.partial = true;
        v.positionUs = v.availableEndUs = atUs;
        return v;
    }
    v.holding = true;
    if (heldSec > kTruncationSettleSec) {

        v.holding = false;
        v.ended = true;
        v.durationUs = v.positionUs = std::max<int64_t>(atUs, 10000);
    }
    return v;
}

inline EndVerdict evaluateAudioOnlyEnd(bool audioDrained, int64_t audioEndUs, double durationSec, bool damageEvidence) {
    EndVerdict v;
    if (!audioDrained || !(durationSec > 0 || audioEndUs > 0)) return v;
    v.ended = true;
    v.partial = damageEvidence && durationSec > 0 && audioEndUs > 0 && audioEndUs / 1e6 + 0.5 < durationSec;
    if (v.partial) {
        v.positionUs = audioEndUs;
        v.availableEndUs = audioEndUs;
    } else {
        v.positionUs = durationSec > 0 ? (int64_t)(durationSec * 1e6) : audioEndUs;
    }
    return v;
}

// Monotonically extend the declared duration when delivered content passes it (a stale sidx/mfra index or an
// underestimated bitrate duration). Otherwise the position exceeds the duration during playback, jumps back to the
// declared duration at the end, and seeking stays clamped to the stale duration.
// contentSec is the actually delivered content position (video: presented frame pts; audio only: the smaller of the
// media clock and the ring's content end). The first extension requires exceeding the duration by more than 0.5 s,
// the same tolerance as the end rules, so end-of-file rounding on healthy files never triggers it. Once the declared
// duration is known to be stale (extending = true), it follows the content frame by frame, so the end position
// equals the duration without jumping back. Returns the new declared duration.
// runStartSec is the start of the continuous content run containing contentSec (see ContentRun). Only a run that
// crossed the boundary continuously from within the declared duration (at most 0.5 s beyond it) proves the duration
// stale. A run that begins with a forward timestamp jump (a bad tfdt or PTS pushing frames past the declared
// duration) is not evidence; otherwise a short clip whose timestamps jump ahead and back would be stretched and its
// end position would jump.
inline double extendDurationToContent(double durationSec, double contentSec, bool extending, double runStartSec) {
    if (!(durationSec > 0) || !(contentSec > durationSec)) return durationSec;
    if (!(runStartSec >= 0) || runStartSec > durationSec + 0.5) return durationSec;
    if (!extending && contentSec <= durationSec + 0.5) return durationSec;
    return contentSec;
}

// Continuous content run of steadily presented frames. Adjacent frames whose pts advance by no more than
// kContentRunMaxGapSec stay in one run; going backward or jumping further starts a new run. A legitimate content
// gap also starts a new run; if content continues from within the declared duration after the gap, it can still
// prove the duration stale.
constexpr double kContentRunMaxGapSec = 1.0;
struct ContentRun {
    double startSec = -1.0; // < 0: no run (restarted after a seek, a pause or a pending first frame)
    double lastSec = -1.0;
};
inline void noteContentRun(ContentRun& run, double ptsSec) {
    if (!(run.lastSec >= 0) || ptsSec < run.lastSec || ptsSec - run.lastSec > kContentRunMaxGapSec) run.startSec = ptsSec;
    run.lastSec = ptsSec;
}

struct AudioDecodeSignal {
    bool voiced = false;
    bool failure = false;
};
inline AudioDecodeSignal classifyAudioDecode(int decodeResult, int packetSize, size_t outputBytes, int cleanFrames, int errorFlaggedFrames) {
    AudioDecodeSignal s;
    const bool allFlagged = outputBytes > 0 && cleanFrames == 0 && errorFlaggedFrames > 0;
    if (outputBytes > 0 && !allFlagged) s.voiced = true;
    else if ((decodeResult < 0 && packetSize > 0 && outputBytes == 0) || allFlagged) s.failure = true;
    return s;
}
constexpr int kAudioDecodeFailureRunToRecover = 6;

} // namespace sp
