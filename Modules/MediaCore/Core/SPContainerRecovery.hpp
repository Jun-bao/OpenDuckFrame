// OpenDuckFrame - container structure candidate recovery (patch plans for the read-only byte overlay)
//
// Covers damage that never touches codec-essential metadata and only needs a few bytes changed in a
// virtual view of the file (the source stays read-only and absolute offsets never move): fixed
// signatures and wrapper headers (RIFF, ASF GUID, EBML header), optional indexes (AVI idx1), redundant
// length fields (FLV PreviousTagSize), outer box sizes (MP4 mdat before a trailing moov, fMP4 moof/mdat
// chains), broken non-essential tracks (MP4 trak isolation), Ogg page CRC fields and MKV block chains.
//
// This module only produces patch plans (offset + bytes) and evidence spans; it runs only on failure or
// abnormal-EOF branches, so the healthy path pays nothing. Every scan is bounded and cancellable through
// AbortFn. Patches are overlaid by LocalFileIO when read callbacks deliver bytes. Each planner requires
// mutually corroborating structure before it accepts anything; a single matching string is never enough.
#pragma once

// This header is now an umbrella; the implementation lives in Recovery/ and the include order is the dependency order.
#include "Recovery/RecoveryBase.hpp"
#include "Recovery/RecoveryMp4.hpp"
#include "Recovery/RecoveryAvi.hpp"
#include "Recovery/RecoveryFlv.hpp"
#include "Recovery/RecoveryMpeg.hpp"
#include "Recovery/RecoveryOgg.hpp"
#include "Recovery/RecoveryMatroska.hpp"
#include "Recovery/RecoveryAsfRm.hpp"
