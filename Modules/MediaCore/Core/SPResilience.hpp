// OpenDuckFrame - pure policy and evidence module for resilient playback of damaged or incomplete media
//
// No platform or FFmpeg dependency and no shared state; everything is unit-testable.
//   - The signal that starts resilient handling may be loose (a decoder complaint), but the evidence that
//     establishes damage must be byte-level (all-zero packets, broken NAL/OBU length chains, missing
//     start codes, out-of-range indexes).
//   - Evidence is recorded per track and merged for the selected tracks; it only covers its actual span;
//     a positive observation never overrides explicit negative evidence for the same content version;
//     cancellation or an exhausted budget leaves the span unknown.
//   - Open-failure diagnosis only states confirmed gaps and runs only on the failure branch (healthy files
//     pay nothing).
#pragma once

// This header is now an umbrella; the implementation lives in Resilience/ and the include order is the dependency order.
#include "Resilience/ResilienceBitstream.hpp"
#include "Resilience/ResilienceDamageMap.hpp"
#include "Resilience/ResilienceOpenDiagnosis.hpp"
#include "Resilience/ResilienceVideoCodec.hpp"
#include "Resilience/ResilienceAudioCodec.hpp"
