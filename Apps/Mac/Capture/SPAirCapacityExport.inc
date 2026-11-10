// Candidate04 controlled checkpoint/export helpers. No caller below creates
// an inference job, waits for GPU completion, or changes a presentation plan.
#include "SPAirDiagnosticStream.hpp"
#include <map>

@implementation SPAirDiagnosticWriteBudget {
    std::unique_ptr<spAirDiagnostic::WriteBudget> _writeBudget;
}
- (instancetype)initWithDeadlineHostTicks:(uint64_t)deadline {
    if (!(self = [super init])) return nil;
    _writeBudget = std::make_unique<spAirDiagnostic::WriteBudget>(deadline);
    return self;
}
- (void)cancel { _writeBudget->cancelled.store(true, std::memory_order_release); }
- (BOOL)isCancelled { return _writeBudget->cancelled.load(std::memory_order_acquire); }
- (BOOL)isExpired { return mach_absolute_time() >= _writeBudget->deadlineHostTicks; }
- (spAirDiagnostic::WriteBudget *)nativeWriteBudget { return _writeBudget.get(); }
@end

struct SPAirCapacityRingMark {
    uint64_t total = 0, capacity = 0, cutoff = 0;
    __strong NSDictionary *metadata = nil;
};

@interface SPAirCallbackCheckpoint : NSObject {
@public
    SPAirCapacityRingMark mark;
    std::vector<SPAirSlotCallbackEvent> rows;
    uint64_t unsupported, beginHostTicks, endHostTicks;
    __strong SPAirRetainedPayloadBudget *payloadBudget;
    uint64_t ownedPayloadBytes;
}
@end
@implementation SPAirCallbackCheckpoint
- (void)dealloc {
    std::vector<SPAirSlotCallbackEvent>().swap(rows);
    [payloadBudget releaseBytes:ownedPayloadBytes];
}
@end

template<class T, class Host>
static SPAirCapacityRingMark SPAirMarkRows(const std::vector<T> &rows, uint64_t total,
    uint64_t capacity, uint64_t cutoff, Host host) {
    NSMutableArray *excluded = [NSMutableArray array];
    uint64_t count = 0, first = 0, last = 0;
    for (const auto &row : rows) {
        const int64_t stamp = host(row);
        if (stamp <= (int64_t)cutoff) { if (!count) first = row.sequence; last = row.sequence; ++count; }
        else [excluded addObject:@{@"sequence":@(row.sequence), @"hostTicks":@(stamp)}];
    }
    SPAirCapacityRingMark mark;
    mark.total = total; mark.capacity = capacity; mark.cutoff = cutoff;
    mark.metadata = @{@"capacity":@(capacity), @"total":@(total), @"dropped":@(total > capacity ? total - capacity : 0),
        @"firstseq":count ? @(first) : (id)NSNull.null, @"lastseq":count ? @(last) : (id)NSNull.null,
        @"exportedCount":@(count), @"producerTotalAtCopy":@(total), @"retainedCountBeforeCutoffFilter":@(rows.size()),
        @"cutoffExcludedCount":@(excluded.count), @"cutoffExcludedRecords":excluded,
        @"cutoffHostTicks":@(cutoff), @"overflow":@(total > capacity)};
    return mark;
}

static void SPAirMarkRecordingState(SPAirCapacityRingMark &mark, bool sealed, uint64_t sealedHost, uint64_t postSeal) {
    NSMutableDictionary *metadata = [mark.metadata mutableCopy];
    metadata[@"sealed"] = @(sealed); metadata[@"sealedHostTicks"] = @(sealedHost);
    metadata[@"postSealAttempts"] = @(postSeal); mark.metadata = metadata;
}

static bool SPAirReserveSnapshotPayload(SPAirRetainedPayloadBudget *budget, uint64_t bytes, uint64_t &owned) {
    if (!budget || !bytes) return true;
    if (![budget reserveBytes:bytes]) return false;
    owned += bytes;
    return true;
}

static NSDictionary *SPAirMeasurementRow(const spAirMeasurement::Event &event) {
    using K = spAirMeasurement::Kind;
    NSMutableDictionary *row = [@{
        @"sequence":@(event.sequence), @"kind":@(spAirMeasurement::name(event.kind)),
        @"beginHostTicks":@(event.beginHostTicks), @"endHostTicks":@(event.endHostTicks), @"recordHostTicks":@(event.recordHostTicks),
        @"frameID":event.frameID ? @(event.frameID) : (id)NSNull.null,
        @"generation":@(event.generation), @"configVersion":@(event.config), @"measurementEpoch":@(event.epoch), @"clockEpoch":@(event.clock),
        @"ptsNum":event.ptsDen ? @(event.ptsNum) : (id)NSNull.null, @"ptsDen":event.ptsDen ? @(event.ptsDen) : (id)NSNull.null,
        @"targetHostTicks":event.frameID || event.kind == K::targetCreated ? @(event.targetHostTicks) : (id)NSNull.null,
        @"synthetic":(event.flags & 8) ? @((event.flags & 1) != 0) : (id)NSNull.null,
        @"sampleHostTicks":event.sampleHostTicks ? @(event.sampleHostTicks) : (id)NSNull.null
    } mutableCopy];
    switch (event.kind) {
        case K::slotInsert:
            row[@"jobID"] = event.relatedID ? @(event.relatedID) : (id)NSNull.null;
            row[@"readyMarkerBeforeInsertHostTicks"] = @(event.sampleHostTicks);
            row[@"queueSizeBefore"] = @(event.values[0]); row[@"queueSizeAfterInsert"] = @(event.values[1]);
            row[@"insertInstantHostTicks"] = NSNull.null;
            break;
        case K::timerArm:
            row[@"requestedDueHostTicks"] = @(event.values[0]); row[@"effectiveDueHostTicks"] = @(event.values[1]);
            row[@"delayNanoseconds"] = @(event.values[2]); row[@"dispatchDeadlineToken"] = @(event.values[3]);
            row[@"previousArmID"] = event.relatedID ? @(event.relatedID) : (id)NSNull.null;
            break;
        case K::timerFire:
            row[@"fireID"] = @(event.groupID); row[@"latestClockLifetimeAtEntry"] = @(event.values[0]);
            row[@"expirationCountKnown"] = @((event.flags & 16) != 0);
            row[@"expirationCount"] = (event.flags & 16) ? @(event.values[1]) : (id)NSNull.null;
            row[@"causalArmID"] = NSNull.null;
            row[@"armAssociation"] = @"latest-arm-observed-at-entry; actual-triggering-arm-unknown";
            break;
        case K::drainEntry:
            if (event.flags & 256) {
                row[@"kind"] = @"handoff"; row[@"drainID"] = @(event.relatedID);
                row[@"observedPreparationLeadNs"] = @(event.values[0]); row[@"actualPrepareLeadHostTicks"] = @(event.values[1]);
                row[@"enclosingTimerFireID"] = event.values[2] ? @(event.values[2]) : (id)NSNull.null;
            } else {
                row[@"drainID"] = @(event.groupID); row[@"enclosingTimerFireID"] = event.relatedID ? @(event.relatedID) : (id)NSNull.null;
                row[@"queueSize"] = @(event.values[0]); row[@"pendingPhaseCount"] = @(event.values[1]);
            }
            break;
        case K::choiceBegin: case K::choiceCandidate: case K::choiceEnd:
            row[@"choiceGroupID"] = @(event.groupID); row[@"slotToken"] = @(event.relatedID);
            if (event.kind == K::choiceCandidate) {
                row[@"candidateIndex"] = @(event.values[0]);
                row[@"choiceOutcome"] = event.values[1] == 1 ? @"selected" : (event.values[1] == 2 ? @"superseded" : @"retained-future");
            } else {
                row[@"candidateCount"] = @(event.values[0]); row[@"displayTimeMediaNs"] = @(event.values[1]);
                row[@"deadlineMediaNs"] = @(event.values[2]);
                if (event.kind == K::choiceEnd) row[@"selectedIndex"] = event.frameID ? @(event.values[3]) : (id)NSNull.null;
            }
            break;
        case K::leaseRequest:
            row[@"accepted"] = @(event.values[0] != 0); row[@"outstandingAfterAdmission"] = @(event.values[1]); break;
        case K::leaseClaim:
            row[@"reason"] = SPPreparedTextureReasonName((int)event.values[0]); row[@"hit"] = @(event.values[1] != 0); break;
        case K::leaseMap:
            row[@"mapSucceeded"] = @(event.values[0] != 0); break;
        case K::leaseReady:
            row[@"readyPublicationSucceeded"] = @(event.values[0] != 0); row[@"phaseObservedAfterPublication"] = @(event.values[1]); break;
        case K::leaseCancel:
            row[@"phaseBeforeCancel"] = @(event.values[0]); break;
        case K::leaseRelease:
            row[@"outstandingBeforeDecrement"] = @(event.values[0]); row[@"outstandingAfterDecrement"] = @(event.values[1]);
            row[@"phaseObservedAtRelease"] = @(event.values[2]); break;
        case K::inlineMap:
            row[@"preparedFallbackReason"] = SPPreparedTextureReasonName((int)event.values[0]);
            row[@"primaryCVReferenceCreated"] = @(event.values[1] != 0); row[@"compareIncludesSecondary"] = @(event.values[2] != 0);
            row[@"exactCVAPIBracket"] = @(event.values[3] != 0); break;
        case K::targetCreated:
            [row removeObjectForKey:@"sampleHostTicks"];
            row[@"jobID"] = event.relatedID ? @(event.relatedID) : (id)NSNull.null;
            row[@"phaseIndex"] = @(event.groupID); row[@"basisKnown"] = @((event.flags & 16) != 0);
            row[@"delayHostTicksUsed"] = (event.flags & 16) ? @((int64_t)event.values[0]) : (id)NSNull.null;
            row[@"anchorHostTicks"] = (event.flags & 16) ? @(event.values[1]) : (id)NSNull.null;
            row[@"anchorPTSNum"] = (event.flags & 16) ? @((int64_t)event.values[2]) : (id)NSNull.null;
            row[@"anchorPTSDen"] = (event.flags & 16) ? @((int64_t)event.values[3]) : (id)NSNull.null;
            row[@"sourceIntervalHostTicksAtTargetCreation"] = (event.flags & 64) ? @(event.sampleHostTicks) : (id)NSNull.null;
            row[@"trueSourceIntervalRequested"] = @((event.flags & 128) != 0);
            row[@"basisScope"] = @"D/anchor read at actual affine target construction on the serial processor queue. Frozen/pair-affine/latest/no-anchor targets have unknown basis. Interval is the source estimate observed at this construction, not an invented input to an earlier D recompute.";
            break;
        case K::gpuCallback: {
            row[@"commandBufferStatus"] = @(event.values[0]);
            const bool valid = event.values[0] == MTLCommandBufferStatusCompleted && std::isfinite(event.gpuStartSeconds) &&
                std::isfinite(event.gpuEndSeconds) && event.gpuStartSeconds > 0 && event.gpuEndSeconds >= event.gpuStartSeconds;
            row[@"GPUStartSeconds"] = valid ? @(event.gpuStartSeconds) : (id)NSNull.null;
            row[@"GPUEndSeconds"] = valid ? @(event.gpuEndSeconds) : (id)NSNull.null;
            break;
        }
        default: break;
    }
    if (event.kind >= K::leaseRequest && event.kind <= K::gpuCallback)
        row[@"leaseID"] = event.groupID ? @(event.groupID) : (id)NSNull.null;
    if (event.kind >= K::timerCreate && event.kind <= K::drainEntry) {
        row[@"clockLifetimeID"] = @(event.clockLifeID);
        row[@"latestArmIDObserved"] = event.armID ? @(event.armID) : (id)NSNull.null;
    }
    return row;
}

static SPAirCapacityRingMark SPAirMeasurementMark(const spAirMeasurement::TracePtr &trace, uint64_t cutoff,
    std::vector<spAirMeasurement::Event> &rows) {
    auto value = trace ? trace->snapshot() : spAirMeasurement::Snapshot{};
    rows = std::move(value.rows);
    auto mark = SPAirMarkRows(rows, value.total, trace ? trace->capacity() : 0, cutoff,
        [](const auto &row) { return row.recordHostTicks; });
    SPAirMarkRecordingState(mark, value.sealed, value.sealedHostTicks, value.postSealAttempts);
    NSMutableDictionary *metadata = [mark.metadata mutableCopy];
    metadata[@"enabled"] = @(trace != nullptr); metadata[@"recordingSchema"] = @"odf-air-measurement-events-v1";
    metadata[@"recordBytes"] = @(sizeof(spAirMeasurement::Event));
    metadata[@"completeRetainedPrefix"] = @(value.total <= mark.capacity);
    uint64_t accepted = 0, released = 0;
    for (const auto &row : rows) {
        if (row.kind == spAirMeasurement::Kind::leaseRequest && row.values[0]) ++accepted;
        if (row.kind == spAirMeasurement::Kind::leaseRelease) ++released;
    }
    metadata[@"recordedAcceptedLeaseRequests"] = @(accepted); metadata[@"recordedLeaseReleases"] = @(released);
    const bool pendingKnown = value.total <= mark.capacity && accepted >= released;
    metadata[@"pendingRecordedLeases"] = pendingKnown ? @(accepted - released) : (id)NSNull.null;
    metadata[@"lifecycleClosed"] = @(value.sealed && value.postSealAttempts == 0 && pendingKnown && accepted == released);
    metadata[@"incomplete"] = @(value.total > mark.capacity || (value.sealed && (!pendingKnown || accepted != released || value.postSealAttempts)));

    metadata[@"scope"] = @"Immutable CPU observations. Intervals preserve both bounds. recordHostTicks is appended under the logger's own lock and defines cutoff inclusion. timer fire reports the captured clock lifetime and latest arm at entry; its actual triggering arm is unknown. GPU seconds are raw Metal clock endpoints, CPU callback arrival and actual lease release are separate. Capacity overflow is incomplete and never changes processing.";
    mark.metadata = metadata;
    return mark;
}

static SPAirFusedRenderPtr SPAirFreezeFusedRecord(const SPAirFusedRenderPtr &source) {
    auto result = std::make_shared<SPAirFusedRenderRecord>();
#define SP_AIR_COPY(field) result->field = source->field
    SP_AIR_COPY(sequence); SP_AIR_COPY(frameID); SP_AIR_COPY(generation); SP_AIR_COPY(config);
    SP_AIR_COPY(epoch); SP_AIR_COPY(clock); SP_AIR_COPY(slotToken); SP_AIR_COPY(selectionHostTicks);
    SP_AIR_COPY(requestStartHostTicks); SP_AIR_COPY(enqueueHostTicks); SP_AIR_COPY(bufferWidth); SP_AIR_COPY(bufferHeight);
    SP_AIR_COPY(drawableWidth); SP_AIR_COPY(drawableHeight); SP_AIR_COPY(referenceWidth); SP_AIR_COPY(referenceHeight);
    SP_AIR_COPY(imageRect); SP_AIR_COPY(synthetic);
    SP_AIR_COPY(counts); SP_AIR_COPY(redraw); SP_AIR_COPY(lanczosFragment); SP_AIR_COPY(displayTargetMediaTime);
#undef SP_AIR_COPY
#define SP_AIR_COPY_ATOMIC(field) result->field.store(source->field.load(std::memory_order_acquire), std::memory_order_relaxed)
    SP_AIR_COPY_ATOMIC(gpuObserved); SP_AIR_COPY_ATOMIC(presentedObserved); SP_AIR_COPY_ATOMIC(publicationCancelled);
    SP_AIR_COPY_ATOMIC(gpuStatus); SP_AIR_COPY_ATOMIC(completedHostTicks); SP_AIR_COPY_ATOMIC(gpuStartSeconds);
    SP_AIR_COPY_ATOMIC(gpuEndSeconds); SP_AIR_COPY_ATOMIC(completedMediaTime); SP_AIR_COPY_ATOMIC(presentedTime);
#undef SP_AIR_COPY_ATOMIC
    return result;
}

// Only the terminal observation fields can change after publication. Freeze
// those scalars, sharing the immutable geometry/request fields in the producer.
struct SPAirFrozenFusedTerminal {
    bool gpuObserved, presentedObserved, publicationCancelled;
    uint32_t gpuStatus;
    int64_t completedHostTicks;
    double gpuStartSeconds, gpuEndSeconds, completedMediaTime, presentedTime;
};
static SPAirFrozenFusedTerminal SPAirReadFusedTerminal(const SPAirFusedRenderPtr &record) {
    return {record->gpuObserved.load(std::memory_order_acquire), record->presentedObserved.load(std::memory_order_acquire),
        record->publicationCancelled.load(std::memory_order_acquire), record->gpuStatus.load(), record->completedHostTicks.load(),
        record->gpuStartSeconds.load(), record->gpuEndSeconds.load(), record->completedMediaTime.load(), record->presentedTime.load()};
}
static void SPAirApplyFusedTerminal(const SPAirFusedRenderPtr &record, const SPAirFrozenFusedTerminal &value) {
    record->gpuObserved.store(value.gpuObserved); record->presentedObserved.store(value.presentedObserved);
    record->publicationCancelled.store(value.publicationCancelled); record->gpuStatus.store(value.gpuStatus);
    record->completedHostTicks.store(value.completedHostTicks); record->gpuStartSeconds.store(value.gpuStartSeconds);
    record->gpuEndSeconds.store(value.gpuEndSeconds); record->completedMediaTime.store(value.completedMediaTime);
    record->presentedTime.store(value.presentedTime);
}

@interface SPAirCapacityViewMark : NSObject {
@public
    __strong SPLivePreviewView *owner;
    SPAirCapacityRingMark frames, callbacks, consumes, fused, measurement;
    SPAirSlotSnapshot slotSnapshot;
    BOOL callbackSafe;
    uint64_t unsupported;
    std::map<uint64_t, SPAirSlotConsumeEvent> pendingConsumes;
    std::map<uint64_t, SPAirFrozenFusedTerminal> pendingFused;
    __strong NSDictionary *fusedSummary;
    std::vector<SPAirFrameEvent> frozenFrames;
    std::vector<SPAirSlotCallbackEvent> frozenCallbacks;
    std::vector<SPAirSlotConsumeEvent> frozenConsumes;
    std::vector<SPAirFusedRenderPtr> frozenFused;
    std::vector<spAirMeasurement::Event> frozenMeasurement;
    __strong SPAirRetainedPayloadBudget *payloadBudget;
    uint64_t ownedPayloadBytes;
}
@end
@implementation SPAirCapacityViewMark
- (void)dealloc {
    std::vector<SPAirFrameEvent>().swap(frozenFrames);
    std::vector<SPAirSlotCallbackEvent>().swap(frozenCallbacks);
    std::vector<SPAirSlotConsumeEvent>().swap(frozenConsumes);
    std::vector<SPAirFusedRenderPtr>().swap(frozenFused);
    std::vector<spAirMeasurement::Event>().swap(frozenMeasurement);
    std::map<uint64_t, SPAirSlotConsumeEvent>().swap(pendingConsumes);
    std::map<uint64_t, SPAirFrozenFusedTerminal>().swap(pendingFused);
    [payloadBudget releaseBytes:ownedPayloadBytes];
}
@end

@interface SPAirCapacityCheckpoint : NSObject {
@public
    uint64_t cutoff;
    SPAirCapacityRingMark callbacks, budget, delay, currentStats, measurement;
    __strong SPAirCapacityViewMark *preview, *output;
    __strong SPRifeBridge *serviceOwner;
    __strong NSObject *serviceMark;
    __strong NSDictionary *root;
    BOOL frozenRows, session;
    std::vector<SPAirFrameEvent> frozenCallbacks;
    std::vector<SPAirBudgetEvent> frozenBudget;
    std::vector<SPAirDelayAlignmentEvent> frozenDelay;
    std::vector<SPAirCurrentStatsEvent> frozenCurrentStats;
    std::vector<spAirMeasurement::Event> frozenMeasurement;
    __strong SPAirRetainedPayloadBudget *payloadBudget;
    uint64_t ownedPayloadBytes;
}
@end
@implementation SPAirCapacityCheckpoint
- (void)dealloc {
    std::vector<SPAirFrameEvent>().swap(frozenCallbacks);
    std::vector<SPAirBudgetEvent>().swap(frozenBudget);
    std::vector<SPAirDelayAlignmentEvent>().swap(frozenDelay);
    std::vector<SPAirCurrentStatsEvent>().swap(frozenCurrentStats);
    std::vector<spAirMeasurement::Event>().swap(frozenMeasurement);
    [payloadBudget releaseBytes:ownedPayloadBytes];
}
@end

@interface SPLivePreviewView (SPAirCapacityPrivate)
- (SPAirCapacityViewMark *)airCapacityMarkAtCutoff:(uint64_t)cutoff safeMainCallbackCopy:(BOOL)safe;
- (SPAirCapacityViewMark *)airCapacityMarkAtCutoff:(uint64_t)cutoff safeMainCallbackCopy:(BOOL)safe
    callbackCheckpoint:(nullable SPAirCallbackCheckpoint *)callbackCheckpoint freezeRows:(BOOL)freeze budget:(nullable SPAirRetainedPayloadBudget *)budget;
- (nullable SPAirCallbackCheckpoint *)airCallbackCheckpointAtCutoff:(uint64_t)cutoff budget:(nullable SPAirRetainedPayloadBudget *)budget;
- (void)resetAirCapacityCollectorsOnQueue:(dispatch_queue_t)queue completion:(dispatch_block_t)completion;
- (NSDictionary *)airTraceDrainState;
- (BOOL)airCallbackTraceSealed;
- (void)sealAirCapacityCollectors;
- (void)copyAirCapacityFrames:(std::vector<SPAirFrameEvent> &)rows;
- (void)copyAirCapacitySlotCallbacks:(std::vector<SPAirSlotCallbackEvent> &)rows;
- (void)copyAirCapacityConsumes:(std::vector<SPAirSlotConsumeEvent> &)rows;
- (void)copyAirCapacityFused:(std::vector<SPAirFusedRenderPtr> &)rows;
- (void)copyAirMeasurementRows:(std::vector<spAirMeasurement::Event> &)rows;
@end

@implementation SPLivePreviewView (SPAirCapacityPrivate)
- (void)copyAirMeasurementRows:(std::vector<spAirMeasurement::Event> &)rows {
    if (_measurementTrace) rows = _measurementTrace->snapshot().rows;
}
- (void)sealAirCapacityCollectors {
    uint64_t unsealed = 0;
    _airCapacityViewSealedHostTicks.compare_exchange_strong(unsealed, SPHostNow());
    if (_measurementTrace) _measurementTrace->seal();
    {
        std::lock_guard<std::mutex> lock(_presentationMutex);
        if (_airCadenceFrames) _airCadenceFrames->sealed = true;
        if (_airSlotConsumes) _airSlotConsumes->sealed = true;
    }
    if (_airSlotCallbacks) _airSlotCallbacks->sealed = true; // main owner is synchronously blocked by this controlled checkpoint
    {
        std::lock_guard<std::mutex> lock(_airFusedNotesMutex);
        _airFusedTraceSealed = YES;
    }
}
- (SPAirCapacityViewMark *)airCapacityMarkAtCutoff:(uint64_t)cutoff safeMainCallbackCopy:(BOOL)safe {
    return [self airCapacityMarkAtCutoff:cutoff safeMainCallbackCopy:safe callbackCheckpoint:nil freezeRows:NO budget:nil];
}
- (SPAirCapacityViewMark *)airCapacityMarkAtCutoff:(uint64_t)cutoff safeMainCallbackCopy:(BOOL)safe
    callbackCheckpoint:(SPAirCallbackCheckpoint *)callbackCheckpoint freezeRows:(BOOL)freeze budget:(SPAirRetainedPayloadBudget *)budget {
    safe = safe || callbackCheckpoint != nil || [self airCallbackTraceSealed];
    SPAirCapacityViewMark *mark = [SPAirCapacityViewMark new];
    mark->payloadBudget = budget;
    mark->owner = self; mark->unsupported = _airSlotCallbackUnsupported.load(); mark->callbackSafe = safe;
    {
        std::lock_guard<std::mutex> lock(_presentationMutex);
        std::vector<SPAirFrameEvent> rows;
        if (freeze && _airCadenceFrames && !SPAirReserveSnapshotPayload(budget,
            std::min(_airCadenceFrames->total, uint64_t(SPAirFrameRing::capacity)) * sizeof(SPAirFrameEvent), mark->ownedPayloadBytes)) return nil;
        if (_airCadenceFrames) _airCadenceFrames->copy(rows);
        mark->frames = SPAirMarkRows(rows, _airCadenceFrames ? _airCadenceFrames->total : 0, SPAirFrameRing::capacity,
            cutoff, [](const auto &row) { return row.hostTicks; });
        SPAirMarkRecordingState(mark->frames, _airCadenceFrames && _airCadenceFrames->sealed,
            _airCapacityViewSealedHostTicks.load(), _airCadenceFrames ? _airCadenceFrames->postSealAttempts : 0);
        if (freeze) mark->frozenFrames = std::move(rows);
        std::vector<SPAirSlotConsumeEvent> consumes;
        if (freeze && _airSlotConsumes && !SPAirReserveSnapshotPayload(budget,
            std::min(_airSlotConsumes->total, uint64_t(SPAirSlotConsumeRing::capacity)) * sizeof(SPAirSlotConsumeEvent), mark->ownedPayloadBytes)) return nil;
        if (_airSlotConsumes) _airSlotConsumes->copy(consumes);
        mark->consumes = SPAirMarkRows(consumes, _airSlotConsumes ? _airSlotConsumes->total : 0, SPAirSlotConsumeRing::capacity,
            cutoff, [](const auto &row) { return row.recordHostTicks; });
        SPAirMarkRecordingState(mark->consumes, _airSlotConsumes && _airSlotConsumes->sealed,
            _airCapacityViewSealedHostTicks.load(), _airSlotConsumes ? _airSlotConsumes->postSealAttempts : 0);
        for (const auto &row : consumes) if (!row.terminal) {
            if (freeze && !SPAirReserveSnapshotPayload(budget, sizeof(uint64_t) + sizeof(SPAirSlotConsumeEvent), mark->ownedPayloadBytes)) return nil;
            mark->pendingConsumes.emplace(row.sequence, row);
        }
        if (_airSlotConsumes) {
            NSMutableDictionary *metadata = [mark->consumes.metadata mutableCopy];
            metadata[@"producerObservationsAtCopy"] = @(_airSlotConsumes->observations);
            metadata[@"overwrittenTokens"] = @(_airSlotConsumes->overwrittenTokens);
            metadata[@"invalidTokens"] = @(_airSlotConsumes->invalidTokens);
            metadata[@"repeatedAfterTerminal"] = @(_airSlotConsumes->repeatedAfterTerminal);
            metadata[@"recordingSchema"] = @"odf-one-consume-row-per-token-v1";
            uint64_t saturated = 0;
            for (const auto &row : consumes) if (row.prematureWakeCountSaturated) ++saturated;
            metadata[@"prematureWakeCountSaturatedTokens"] = @(saturated);
            mark->consumes.metadata = metadata;
        }
        mark->slotSnapshot = {SPHostNow(), 0, 0, 0, 0, 0, 0, 0, false};
        if (_prospectiveSlot) {
            const auto &slot = _prospectiveSlot->timing;
            mark->slotSnapshot = {SPHostNow(), slot.deadlineNs, slot.displayNs, slot.token,
                slot.context.generation, slot.context.config, slot.context.measurementEpoch, slot.context.clockEpoch, true};
        }
        if (freeze) mark->frozenConsumes = std::move(consumes);
    }
    {
        std::vector<SPAirSlotCallbackEvent> rows;
        if (callbackCheckpoint) {
            mark->callbacks = callbackCheckpoint->mark;
            mark->unsupported = callbackCheckpoint->unsupported;
            mark->frozenCallbacks.swap(callbackCheckpoint->rows);
            mark->ownedPayloadBytes += callbackCheckpoint->ownedPayloadBytes;
            callbackCheckpoint->ownedPayloadBytes = 0;
        } else {
            if (freeze && safe && _airSlotCallbacks && !SPAirReserveSnapshotPayload(budget,
                std::min(_airSlotCallbacks->total, uint64_t(SPAirSlotCallbackRing::capacity)) * sizeof(SPAirSlotCallbackEvent), mark->ownedPayloadBytes)) return nil;
            if (safe && _airSlotCallbacks) _airSlotCallbacks->copy(rows);
            mark->callbacks = SPAirMarkRows(rows, safe && _airSlotCallbacks ? _airSlotCallbacks->total : 0,
                SPAirSlotCallbackRing::capacity, cutoff, [](const auto &row) { return row.outcomeHostTicks; });
            SPAirMarkRecordingState(mark->callbacks, _airSlotCallbacks && _airSlotCallbacks->sealed,
                _airCapacityViewSealedHostTicks.load(), _airSlotCallbacks ? _airSlotCallbacks->postSealAttempts : 0);
            if (freeze) mark->frozenCallbacks = std::move(rows);
        }
    }
    {
        std::lock_guard<std::mutex> lock(_airFusedNotesMutex);
        std::vector<SPAirFusedRenderPtr> rows;
        const uint64_t count = std::min(_airFusedRenderTotal, uint64_t(SPAirFusedRenderCapacity));
        for (uint64_t index = _airFusedRenderTotal - count; index < _airFusedRenderTotal; ++index) {
            auto record = (*_airFusedRenderNotes)[index % SPAirFusedRenderCapacity];
            if (!record) continue;
            rows.push_back(record);
            if (!record->gpuObserved.load(std::memory_order_acquire) || !record->presentedObserved.load(std::memory_order_acquire)) {
                if (freeze && !SPAirReserveSnapshotPayload(budget, sizeof(uint64_t) + sizeof(SPAirFrozenFusedTerminal), mark->ownedPayloadBytes)) return nil;
                mark->pendingFused.emplace(record->sequence, SPAirReadFusedTerminal(record));
            }
        }
        struct Row { uint64_t sequence; int64_t host; };
        std::vector<Row> summaries;
        summaries.reserve(rows.size());
        for (const auto &row : rows) summaries.push_back({row->sequence, row->selectionHostTicks});
        if (freeze) {
            //The frozen arm64 layout is192B record plus24B shared control,
            //rounded to224B by the allocator, plus a16B retained pointer.
            const uint64_t bytes = rows.size() * (224 + sizeof(SPAirFusedRenderPtr));
            if (!SPAirReserveSnapshotPayload(budget, bytes, mark->ownedPayloadBytes)) return nil;
            mark->frozenFused.reserve(rows.size());
            for (const auto &row : rows) mark->frozenFused.push_back(SPAirFreezeFusedRecord(row));
        }
        mark->fused = SPAirMarkRows(summaries, _airFusedRenderTotal, SPAirFusedRenderCapacity, cutoff,
            [](const auto &row) { return row.host; });
        SPAirMarkRecordingState(mark->fused, _airFusedTraceSealed, _airCapacityViewSealedHostTicks.load(), _airFusedPostSealAttempts);
    }
    {
        std::vector<spAirMeasurement::Event> rows;
        mark->measurement = SPAirMeasurementMark(_measurementTrace, cutoff, rows);
        if (freeze && !SPAirReserveSnapshotPayload(budget, rows.size() * sizeof(spAirMeasurement::Event), mark->ownedPayloadBytes)) return nil;
        if (freeze) mark->frozenMeasurement = std::move(rows);
    }
    NSMutableDictionary *fused = [[self fusedRifePresentationSnapshotIncludeRecords:NO cutoffHostTicks:cutoff] mutableCopy];
    [fused addEntriesFromDictionary:mark->fused.metadata]; fused[@"includeRecords"] = @YES;
    mark->fusedSummary = fused;
    return mark;
}
- (void)copyAirCapacityFrames:(std::vector<SPAirFrameEvent> &)rows {
    std::lock_guard<std::mutex> lock(_presentationMutex);
    if (_airCadenceFrames) _airCadenceFrames->copy(rows);
}
- (void)copyAirCapacitySlotCallbacks:(std::vector<SPAirSlotCallbackEvent> &)rows {
    if ((NSThread.isMainThread || [self airCallbackTraceSealed]) && _airSlotCallbacks) _airSlotCallbacks->copy(rows);
}
- (BOOL)airCallbackTraceSealed { return _airSlotCallbacks && _airSlotCallbacks->sealed; }
- (SPAirCallbackCheckpoint *)airCallbackCheckpointAtCutoff:(uint64_t)cutoff budget:(SPAirRetainedPayloadBudget *)budget {
    NSAssert(NSThread.isMainThread, @"Callback checkpoint requires its actual main owner");
    SPAirCallbackCheckpoint *snapshot = [SPAirCallbackCheckpoint new];
    snapshot->payloadBudget = budget;
    snapshot->beginHostTicks = SPHostNow(); snapshot->unsupported = _airSlotCallbackUnsupported.load();
    if (_airSlotCallbacks) {
        if (!SPAirReserveSnapshotPayload(budget,
            std::min(_airSlotCallbacks->total, uint64_t(SPAirSlotCallbackRing::capacity)) * sizeof(SPAirSlotCallbackEvent), snapshot->ownedPayloadBytes)) return nil;
        snapshot->rows.reserve(std::min(_airSlotCallbacks->total, uint64_t(SPAirSlotCallbackRing::capacity)));
        _airSlotCallbacks->copy(snapshot->rows);
    }
    snapshot->mark = SPAirMarkRows(snapshot->rows, _airSlotCallbacks ? _airSlotCallbacks->total : 0,
        SPAirSlotCallbackRing::capacity, cutoff, [](const auto &row) { return row.outcomeHostTicks; });
    SPAirMarkRecordingState(snapshot->mark, _airSlotCallbacks && _airSlotCallbacks->sealed,
        _airCapacityViewSealedHostTicks.load(), _airSlotCallbacks ? _airSlotCallbacks->postSealAttempts : 0);
    snapshot->endHostTicks = SPHostNow();
    return snapshot;
}
- (void)resetAirCapacityCollectorsOnQueue:(dispatch_queue_t)queue completion:(dispatch_block_t)completion {
    NSAssert(NSThread.isMainThread, @"Callback reset requires its actual main owner");
    _airCapacityViewSealedHostTicks.store(0);
    if (_measurementTrace) _measurementTrace->reset();
    if (_airSlotCallbacks) { _airSlotCallbacks->total = 0; _airSlotCallbacks->postSealAttempts = 0; _airSlotCallbacks->sealed = false; }
    _airSlotCallbackUnsupported.store(0);
    dispatch_async(_renderQueue, ^{
        {
            std::lock_guard<std::mutex> lock(self->_presentationMutex);
            if (self->_airCadenceFrames) { self->_airCadenceFrames->total = 0; self->_airCadenceFrames->postSealAttempts = 0; self->_airCadenceFrames->sealed = false; }
            if (self->_airSlotConsumes) {
                auto &ring = *self->_airSlotConsumes;
                ring.records.fill({}); ring.total = 0; ring.postSealAttempts = 0; ring.sealed = false;
#if ODF_AIR_RIFE_PRESCALE_DIAGNOSTIC
                ring.observations = 0; ring.overwrittenTokens = 0; ring.invalidTokens = 0; ring.repeatedAfterTerminal = 0;
#endif
            }
        }
        {
            std::lock_guard<std::mutex> lock(self->_airFusedNotesMutex);
            if (self->_airFusedRenderNotes) for (auto &record : *self->_airFusedRenderNotes) record.reset();
            self->_airFusedRenderTotal = 0; self->_airFusedTraceSealed = NO; self->_airFusedPostSealAttempts = 0;
            self->_airFusedLastPositiveOriginal.reset(); self->_airFusedLastPositiveSynthetic.reset();
        }
        dispatch_async(queue, completion);
    });
}
- (NSDictionary *)airTraceDrainState {
    NSUInteger pendingFrames; BOOL pendingSlot;
    {
        std::lock_guard<std::mutex> lock(_presentationMutex);
        pendingFrames = _pendingPresentations.count; pendingSlot = _prospectiveSlot != nil;
    }
    uint64_t pendingTerminals = 0;
    {
        std::lock_guard<std::mutex> lock(_airFusedNotesMutex);
        if (_airFusedRenderNotes) for (const auto &record : *_airFusedRenderNotes) {
            if (record && !record->publicationCancelled.load(std::memory_order_acquire) &&
                (!record->gpuObserved.load(std::memory_order_acquire) || !record->presentedObserved.load(std::memory_order_acquire))) ++pendingTerminals;
        }
    }
    const auto draws = _inflightDraws.load(); const auto callbacks = _airPresentedCallbacksPending.load(std::memory_order_acquire);
    const uint64_t prepared = _preparedTextures ? [[_preparedTextures snapshot][@"outstanding"] unsignedLongLongValue] : 0;
    return @{ @"inflightDraws": @(draws), @"pendingFrames": @(pendingFrames), @"pendingSlot": @(pendingSlot),
        @"pendingCallbackBodies": @(callbacks), @"pendingRenderTerminals": @(pendingTerminals), @"preparedOutstanding": @(prepared),
        @"observedHostTicks": @(SPHostNow()), @"ready": @(draws == 0 && !pendingFrames && !pendingSlot && !callbacks && !pendingTerminals && !prepared) };
}
- (void)copyAirCapacityConsumes:(std::vector<SPAirSlotConsumeEvent> &)rows {
    std::lock_guard<std::mutex> lock(_presentationMutex);
    if (_airSlotConsumes) _airSlotConsumes->copy(rows);
}
- (void)copyAirCapacityFused:(std::vector<SPAirFusedRenderPtr> &)rows {
    std::lock_guard<std::mutex> lock(_airFusedNotesMutex);
    if (!_airFusedRenderNotes) return;
    const uint64_t count = std::min(_airFusedRenderTotal, uint64_t(SPAirFusedRenderCapacity));
    for (uint64_t index = _airFusedRenderTotal - count; index < _airFusedRenderTotal; ++index) {
        auto record = (*_airFusedRenderNotes)[index % SPAirFusedRenderCapacity];
        if (record) rows.push_back(SPAirFreezeFusedRecord(record));
    }
}
@end

static NSDictionary *SPAirCapacityViewSlots(SPAirCapacityViewMark *mark) {
    return @{@"callbackExportSafe":@(mark->callbackSafe), @"unsupported":@(mark->unsupported),
        @"callbacks":mark->callbacks.metadata, @"consumes":mark->consumes.metadata,
        @"pendingSlotSnapshot":SPAirSlotSnapshotExport(mark->slotSnapshot)};
}

@implementation SPLiveProcessor (SPAirCapacityExport)
- (void)airDetachSessionServiceTrace:(SPRifeBridge *)bridge reason:(NSString *)reason {
    if (!_airTraceSessionActive || !bridge || [_airTraceDetachedBridges containsObject:bridge]) return;
    [_airTraceDetachedBridges addObject:bridge];
    const BOOL accepted = _airTraceDetachPending == 0;
    if (accepted) ++_airTraceDetachPending; else ++_airTraceDetachDropped;
    NSString *sessionID = _airTraceSessionID;
    SPAirRetainedPayloadBudget *payloadBudget = _airTracePayloadBudget;
    const uint64_t ordinal = ++_airTraceServiceOrdinal;
    NSDictionary *context = @{ @"sessionID": sessionID ?: @"", @"ordinal": @(ordinal), @"reason": reason ?: @"retired",
        @"retirementObservedHostTicks": @(SPHostNow()), @"generation": @(_sourceGeneration),
        @"configVersion": @(_configVersion), @"measurementEpoch": @(_measurementEpoch) };
    [bridge finishServiceTraceForSessionWithCompletion:^(NSObject *token) {
        // Rejected tokens are released on this exec tail. They never queue a
        // second full-capacity backing store behind the utility compactor.
        if (!accepted) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                NSDictionary *metadata = token ? [SPRifeBridge compactDetachedServiceTraceSnapshot:token budget:payloadBudget] : nil;
                dispatch_async(self->_q, ^{
                    if (![sessionID isEqual:self->_airTraceSessionID]) return;
                    const uint64_t fence = SPHostNow();
                    NSMutableDictionary *receipt = [context mutableCopy];
                    receipt[@"processorQueueFenceHostTicks"] = @(fence);
                    receipt[@"processorCompletionDrainObserved"] = @YES;
                    receipt[@"pendingInferenceJobsAtFence"] = @(self->_r7JobHosts.size());
                    receipt[@"inferenceTrackingCompleteAtFence"] = @(self->_r7JobUntracked == self->_airTraceUntrackedJobsAtBegin);
                    receipt[@"execTailReached"] = metadata[@"execTailReached"] ?: @NO;
                    receipt[@"compactedRetainedPOD"] = metadata[@"compactedRetainedPOD"] ?: @NO;
                    receipt[@"payloadAdmissionKnown"] = @YES;
                    receipt[@"admitted"] = @([metadata[@"enabled"] boolValue] && [metadata[@"compactedRetainedPOD"] boolValue]);
                    receipt[@"ownedPayloadBytes"] = metadata[@"retainedPODBytes"] ?: @0;
                    NSDictionary *payload = [self->_airTracePayloadBudget snapshot];
                    receipt[@"currentTotalBytes"] = payload[@"retainedBytes"] ?: @0;
                    receipt[@"limitBytes"] = payload[@"limitBytes"] ?: @0;
                    const BOOL known = token && [metadata[@"enabled"] boolValue] && metadata[@"storeID"];
                    if (!known) ++self->_airTraceDetachDropped;
                    void (^handler)(NSObject *, NSDictionary *) = self->_airTraceRetiredServiceHandler;
                    dispatch_queue_t replies = self->_airTraceReplyQueue;
                    if (known && handler) dispatch_async(replies, ^{
                        handler(token, receipt);
                        dispatch_async(self->_q, ^{ --self->_airTraceDetachPending; });
                    });
                    else --self->_airTraceDetachPending;
                });
            }
        });
    }];
}
- (void)beginAirTraceRecordingSession:(NSString *)sessionID keeperJournal:(NSObject *)journal payloadBudget:(SPAirRetainedPayloadBudget *)payloadBudget
    retiredServiceHandler:(void (^)(NSObject *, NSDictionary *))handler replyQueue:(dispatch_queue_t)replyQueue
    completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    NSString *identity = [sessionID copy];
    dispatch_async(_q, ^{
        const BOOL repeated = self->_airTraceSessionActive && [self->_airTraceSessionID isEqual:identity];
        NSString *failure = nil;
        if (!SPAirBetaSessionRecorderRequested()) failure = @"Session recording is disabled";
        else if (!identity.length) failure = @"A session identity is required";
        else if (!payloadBudget) failure = @"A session CPU payload budget is required";
        else if (!repeated && self->_airTraceSessionActive && (!self->_airCapacitySealedHostTicks || self->_airTraceDetachPending || !self->_r7JobHosts.empty()))
            failure = @"The previous session has not sealed and drained";
        if (failure || repeated) {
            NSDictionary *receipt = @{ @"success": @(!failure), @"resetComplete": @(!failure), @"sessionID": identity ?: @"",
                @"beginHostTicks": @(self->_airTraceSessionBeginHostTicks), @"repeated": @(repeated), @"error": failure ?: (id)NSNull.null };
            dispatch_async(replyQueue, ^{ completion(receipt); });
            return;
        }
        self->_airTraceSessionID = identity; self->_airTraceKeeperJournal = journal;
        self->_airTracePayloadBudget = payloadBudget;
        self->_airTraceRetiredServiceHandler = [handler copy]; self->_airTraceReplyQueue = replyQueue;
        self->_airTraceDetachedBridges = [NSHashTable weakObjectsHashTable];
        self->_airTraceDetachPending = 0; self->_airTraceDetachDropped = 0; self->_airTraceServiceOrdinal = 0;
        self->_airTraceUntrackedJobsAtBegin = self->_r7JobUntracked;
        self->_airTraceSessionBeginHostTicks = SPHostNow(); self->_airTraceSessionActive = YES;
        self->_airTraceRecordingSaturated = NO; self->_airCapacitySealedHostTicks = 0;
        if (self->_airCadenceCallbacks) { self->_airCadenceCallbacks->total = 0; self->_airCadenceCallbacks->postSealAttempts = 0; self->_airCadenceCallbacks->sealed = false; }
        if (self->_airCadenceBudget) { self->_airCadenceBudget->total = 0; self->_airCadenceBudget->postSealAttempts = 0; self->_airCadenceBudget->sealed = false; }
        if (self->_airDelayAlignmentEvents) { self->_airDelayAlignmentEvents->total = 0; self->_airDelayAlignmentEvents->postSealAttempts = 0; self->_airDelayAlignmentEvents->sealed = false; }
        if (self->_airCurrentStatsCalls) { self->_airCurrentStatsCalls->total = 0; self->_airCurrentStatsCalls->postSealAttempts = 0; self->_airCurrentStatsCalls->sealed = false; }
        if (self->_measurementTrace) self->_measurementTrace->reset();
        [self->_rife setKeeperSessionJournal:journal];
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_group_t resets = dispatch_group_create();
            for (SPLivePreviewView *view in @[self.preview, self.outputPreview]) {
                dispatch_group_enter(resets);
                [view resetAirCapacityCollectorsOnQueue:self->_q completion:^{ dispatch_group_leave(resets); }];
            }
            dispatch_group_notify(resets, self->_q, ^{
                NSDictionary *receipt = @{ @"success": @YES, @"resetComplete": @YES, @"sessionID": identity,
                    @"beginHostTicks": @(self->_airTraceSessionBeginHostTicks), @"resetEndHostTicks": @(SPHostNow()),
                    @"retainedPayloadBudget": [self->_airTracePayloadBudget snapshot],
                    @"resetScope": @"CPU diagnostic collectors only; lifetime pipeline counters are preserved", @"error": NSNull.null };
                dispatch_async(replyQueue, ^{ completion(receipt); });
            });
        });
    });
}
- (void)captureAirTraceCheckpointAtCutoffHostTicks:(uint64_t)requestedCutoff replyQueue:(dispatch_queue_t)replyQueue
    completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    void (^mainCheckpoint)(void) = ^{
        if (!self->_airTracePayloadBudget) {
            dispatch_async(replyQueue, ^{ completion(@{ @"success": @NO, @"snapshot": NSNull.null,
                @"metadata": @{}, @"error": @"No active session CPU payload budget" }); });
            return;
        }
        const uint64_t cutoff = requestedCutoff ?: SPHostNow();
        SPAirCallbackCheckpoint *preview = [self.preview airCallbackCheckpointAtCutoff:cutoff budget:self->_airTracePayloadBudget];
        SPAirCallbackCheckpoint *output = [self.outputPreview airCallbackCheckpointAtCutoff:cutoff budget:self->_airTracePayloadBudget];
        if (!preview || !output) {
            NSDictionary *receipt = @{ @"success": @NO, @"snapshot": NSNull.null, @"metadata": @{},
                @"retainedPayloadBudget": [self->_airTracePayloadBudget snapshot], @"error": @"Session CPU payload budget exceeded" };
            dispatch_async(replyQueue, ^{ completion(receipt); });
            return;
        }
        dispatch_async(self->_q, ^{
            SPAirCapacityCheckpoint *mark = [self airCaptureSnapshotAtCutoff:cutoff previewCallbacks:preview outputCallbacks:output freezeRows:YES session:YES];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @autoreleasepool {
                    if (mark && mark->serviceMark) [SPRifeBridge compactDetachedServiceTraceSnapshot:mark->serviceMark budget:self->_airTracePayloadBudget];
                    NSDictionary *receipt = @{ @"success": @(mark != nil), @"snapshot": mark ?: (id)NSNull.null,
                        @"metadata": mark ? mark->root : @{}, @"retainedPayloadBudget": [self->_airTracePayloadBudget snapshot],
                        @"error": mark ? (id)NSNull.null : @"Session CPU payload budget exceeded" };
                    dispatch_async(replyQueue, ^{ completion(receipt); });
                }
            });
        });
    };
    if (NSThread.isMainThread) mainCheckpoint(); else dispatch_async(dispatch_get_main_queue(), mainCheckpoint);
}
- (void)sealAirTraceRecordingForReason:(NSString *)reason replyQueue:(dispatch_queue_t)replyQueue
    completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.preview sealAirCapacityCollectors]; [self.outputPreview sealAirCapacityCollectors];
        dispatch_async(self->_q, ^{
            if (!self->_airCapacitySealedHostTicks) {
                if (self->_airCadenceCallbacks) self->_airCadenceCallbacks->sealed = true;
                if (self->_airCurrentStatsCalls) self->_airCurrentStatsCalls->sealed = true;
            if (self->_measurementTrace) self->_measurementTrace->seal();
                if (self->_airCadenceBudget) self->_airCadenceBudget->sealed = true;
                if (self->_airDelayAlignmentEvents) self->_airDelayAlignmentEvents->sealed = true;
                [self->_rife sealServiceTraceForDiagnostics];
                self->_airCapacitySealedHostTicks = SPHostNow();
            }
            if ([reason isEqualToString:@"recording-limit-720s"]) self->_airTraceRecordingSaturated = YES;
            NSDictionary *receipt = @{ @"success": @YES, @"sealed": @YES, @"sealHostTicks": @(self->_airCapacitySealedHostTicks),
                @"reason": reason ?: @"sealed", @"saturated": @(self->_airTraceRecordingSaturated),
                @"pipelineStopRequested": @NO, @"error": NSNull.null };
            dispatch_async(replyQueue, ^{ completion(receipt); });
        });
    });
}
- (void)captureSealedAirTraceSnapshotOnQueue:(dispatch_queue_t)replyQueue completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    dispatch_async(_q, ^{
        if (!self->_airCapacitySealedHostTicks) {
            dispatch_async(replyQueue, ^{ completion(@{ @"success": @NO, @"snapshot": NSNull.null,
                @"metadata": @{}, @"error": @"Recording has not been sealed" }); });
            return;
        }
        [self captureAirTraceCheckpointAtCutoffHostTicks:0 replyQueue:replyQueue completion:completion];
    });
}
- (void)stopAirTraceSessionWithDeadlineHostTicks:(uint64_t)deadline replyQueue:(dispatch_queue_t)replyQueue
    completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    dispatch_async(_q, ^{
        [self stop];
        __block BOOL prepareFence = NO, verifiedFence = NO;
        __block dispatch_block_t observe;
        observe = ^{
            NSDictionary *preview = [self.preview airTraceDrainState], *output = [self.outputPreview airTraceDrainState];
            const BOOL tracked = self->_r7JobUntracked == self->_airTraceUntrackedJobsAtBegin;
            const BOOL ready = prepareFence && tracked && self->_r7JobHosts.empty() && self->_airTraceDetachPending == 0 &&
                [preview[@"ready"] boolValue] && [output[@"ready"] boolValue];
            const BOOL timedOut = SPHostNow() >= deadline;
            if ((!ready || !verifiedFence) && !timedOut) {
                verifiedFence = ready;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ready ? 0 : 10 * NSEC_PER_MSEC), self->_q, observe);
                return;
            }
            NSDictionary *payload = [self->_airTracePayloadBudget snapshot];
            const BOOL complete = ready && self->_airTraceDetachDropped == 0 && [payload[@"reservationFailures"] unsignedLongLongValue] == 0;
            NSDictionary *receipt = @{ @"success": @(complete), @"nativeDrainComplete": @(complete), @"timedOut": @(timedOut),
                @"pendingInferenceJobs": @(self->_r7JobHosts.size()), @"inferenceTrackingComplete": @(tracked),
                @"viewDrains": @{ @"preview": preview, @"output": output }, @"prepareQueueFenceObserved": @(prepareFence),
                @"serviceDetachPending": @(self->_airTraceDetachPending), @"serviceDetachDropped": @(self->_airTraceDetachDropped),
                @"processorQueueFenceHostTicks": @(SPHostNow()), @"keeperDrainObserved": NSNull.null,
                @"retainedPayloadBudget": payload ?: @{},
                @"error": complete ? (id)NSNull.null : @"Native drain or service recording is incomplete" };
            observe = nil;
            dispatch_async(replyQueue, ^{ completion(receipt); });
        };
        dispatch_async(self->_prepareQ, ^{ dispatch_async(self->_q, ^{ prepareFence = YES; }); });
        observe();
    });
}
- (id)captureAirTraceSnapshotAtCutoffHostTicks:(uint64_t)requestedCutoff {
    const BOOL session = SPAirBetaSessionRecorderRequested();
    return [self airCaptureSnapshotAtCutoff:requestedCutoff previewCallbacks:nil outputCallbacks:nil freezeRows:session session:session];
}
- (id)airCaptureSnapshotAtCutoff:(uint64_t)requestedCutoff previewCallbacks:(SPAirCallbackCheckpoint *)previewCallbacks
    outputCallbacks:(SPAirCallbackCheckpoint *)outputCallbacks freezeRows:(BOOL)freeze session:(BOOL)sessionRequested {
    const BOOL mainCaller = NSThread.isMainThread;
    const BOOL queueCaller = dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self;
    __block SPAirCapacityCheckpoint *mark = [SPAirCapacityCheckpoint new];
    mark->frozenRows = freeze;
    void (^capture)(void) = ^{
        const BOOL session = sessionRequested && self->_airTraceSessionActive && self->_airTracePayloadBudget;
        mark->session = session;
        mark->cutoff = requestedCutoff ?: SPHostNow();
        const BOOL safeMain = mainCaller && !queueCaller;
        const uint64_t captureBegin = SPHostNow();
        SPAirRetainedPayloadBudget *budget = session ? self->_airTracePayloadBudget : nil;
        mark->payloadBudget = budget;
        mark->preview = [self.preview airCapacityMarkAtCutoff:mark->cutoff safeMainCallbackCopy:safeMain callbackCheckpoint:previewCallbacks freezeRows:freeze budget:budget];
        mark->output = [self.outputPreview airCapacityMarkAtCutoff:mark->cutoff safeMainCallbackCopy:safeMain callbackCheckpoint:outputCallbacks freezeRows:freeze budget:budget];
        if (!mark->preview || !mark->output) { mark = nil; return; }
        {
            std::vector<SPAirFrameEvent> rows;
            if (freeze && self->_airCadenceCallbacks && !SPAirReserveSnapshotPayload(budget,
                std::min(self->_airCadenceCallbacks->total, uint64_t(SPAirFrameRing::capacity)) * sizeof(SPAirFrameEvent), mark->ownedPayloadBytes)) { mark = nil; return; }
            if (self->_airCadenceCallbacks) self->_airCadenceCallbacks->copy(rows);
            mark->callbacks = SPAirMarkRows(rows, self->_airCadenceCallbacks ? self->_airCadenceCallbacks->total : 0,
                SPAirFrameRing::capacity, mark->cutoff, [](const auto &row) { return row.hostTicks; });
            SPAirMarkRecordingState(mark->callbacks, self->_airCadenceCallbacks && self->_airCadenceCallbacks->sealed,
                self->_airCapacitySealedHostTicks, self->_airCadenceCallbacks ? self->_airCadenceCallbacks->postSealAttempts : 0);
            if (freeze) mark->frozenCallbacks = std::move(rows);
        }
        {
            std::vector<SPAirBudgetEvent> rows;
            if (freeze && self->_airCadenceBudget && !SPAirReserveSnapshotPayload(budget,
                std::min(self->_airCadenceBudget->total, uint64_t(SPAirBudgetRing::capacity)) * sizeof(SPAirBudgetEvent), mark->ownedPayloadBytes)) { mark = nil; return; }
            if (self->_airCadenceBudget) self->_airCadenceBudget->copy(rows);
            mark->budget = SPAirMarkRows(rows, self->_airCadenceBudget ? self->_airCadenceBudget->total : 0,
                SPAirBudgetRing::capacity, mark->cutoff, [](const auto &row) { return row.hostTicks; });
            SPAirMarkRecordingState(mark->budget, self->_airCadenceBudget && self->_airCadenceBudget->sealed,
                self->_airCapacitySealedHostTicks, self->_airCadenceBudget ? self->_airCadenceBudget->postSealAttempts : 0);
            if (freeze) mark->frozenBudget = std::move(rows);
        }
        {
            std::vector<SPAirDelayAlignmentEvent> rows;
            if (freeze && self->_airDelayAlignmentEvents && !SPAirReserveSnapshotPayload(budget,
                std::min(self->_airDelayAlignmentEvents->total, uint64_t(SPAirDelayAlignmentRing::capacity)) * sizeof(SPAirDelayAlignmentEvent), mark->ownedPayloadBytes)) { mark = nil; return; }
            if (self->_airDelayAlignmentEvents) self->_airDelayAlignmentEvents->copy(rows);
            mark->delay = SPAirMarkRows(rows, self->_airDelayAlignmentEvents ? self->_airDelayAlignmentEvents->total : 0,
                SPAirDelayAlignmentRing::capacity, mark->cutoff, [](const auto &row) { return row.hostTicks; });
            SPAirMarkRecordingState(mark->delay, self->_airDelayAlignmentEvents && self->_airDelayAlignmentEvents->sealed,
                self->_airCapacitySealedHostTicks, self->_airDelayAlignmentEvents ? self->_airDelayAlignmentEvents->postSealAttempts : 0);
            if (freeze) mark->frozenDelay = std::move(rows);
        }
        {
            std::vector<SPAirCurrentStatsEvent> rows;
            if (freeze && self->_airCurrentStatsCalls && !SPAirReserveSnapshotPayload(budget,
                std::min(self->_airCurrentStatsCalls->total, uint64_t(SPAirCurrentStatsRing::capacity)) * sizeof(SPAirCurrentStatsEvent), mark->ownedPayloadBytes)) { mark = nil; return; }
            if (self->_airCurrentStatsCalls) self->_airCurrentStatsCalls->copy(rows);
            mark->currentStats = SPAirMarkRows(rows, self->_airCurrentStatsCalls ? self->_airCurrentStatsCalls->total : 0,
                SPAirCurrentStatsRing::capacity, mark->cutoff, [](const auto &row) { return row.endHostTicks; });
            NSMutableDictionary *metadata = [mark->currentStats.metadata mutableCopy];
            metadata[@"enabled"] = @(self->_airCurrentStatsCalls != nullptr);
            metadata[@"recordingSchema"] = @"odf-air-current-stats-trace-v1";
            metadata[@"sealed"] = @(self->_airCurrentStatsCalls && self->_airCurrentStatsCalls->sealed);
            metadata[@"sealedHostTicks"] = @(self->_airCapacitySealedHostTicks);
            metadata[@"postSealAttempts"] = @(self->_airCurrentStatsCalls ? self->_airCurrentStatsCalls->postSealAttempts : 0);
            mark->currentStats.metadata = metadata;
            if (freeze) mark->frozenCurrentStats = std::move(rows);
        }
        {
            std::vector<spAirMeasurement::Event> rows;
            mark->measurement = SPAirMeasurementMark(self->_measurementTrace, mark->cutoff, rows);
            if (freeze && !SPAirReserveSnapshotPayload(budget, rows.size() * sizeof(spAirMeasurement::Event), mark->ownedPayloadBytes)) { mark = nil; return; }
            if (freeze) mark->frozenMeasurement = std::move(rows);
        }
        uint64_t overflow = 0;
        for (NSDictionary *item in @[mark->preview->frames.metadata, mark->output->frames.metadata, mark->callbacks.metadata,
            mark->budget.metadata, mark->delay.metadata, mark->preview->callbacks.metadata, mark->output->callbacks.metadata,
            mark->preview->consumes.metadata, mark->output->consumes.metadata]) overflow += [item[@"dropped"] unsignedLongLongValue];
        const uint64_t slotOverflow = [mark->preview->callbacks.metadata[@"dropped"] unsignedLongLongValue]
            + [mark->output->callbacks.metadata[@"dropped"] unsignedLongLongValue]
            + [mark->preview->consumes.metadata[@"dropped"] unsignedLongLongValue]
            + [mark->output->consumes.metadata[@"dropped"] unsignedLongLongValue];
        const BOOL callbackSafe = mark->preview->callbackSafe && mark->output->callbackSafe;
        NSDictionary *causal = @{@"enabled":@YES, @"exportCutoffHostTicks":@(mark->cutoff),
            @"overflowCount":@(overflow), @"overflowCountKnown":@(callbackSafe),
            @"ringsComplete":@(overflow == 0 && callbackSafe && mark->preview->unsupported == 0 && mark->output->unsupported == 0),
            @"preview":mark->preview->frames.metadata, @"output":mark->output->frames.metadata,
            @"callbacks":mark->callbacks.metadata, @"rateBudget":mark->budget.metadata,
            @"delayAlignment":@{@"enabled":@(self->_airDelayAlignmentEvents != nullptr),
                @"trueSourceIntervalRequested":@(self->_airTrueSourceIntervalRequested),
                @"interactiveCap125msRequested":@(self->_airInteractiveCap125msRequested), @"recomputes":mark->delay.metadata},
            @"slots":@{@"callbackExportSafe":@(callbackSafe), @"valid":@(callbackSafe && slotOverflow == 0 && mark->preview->unsupported == 0 && mark->output->unsupported == 0),
                @"overflowCount":@(slotOverflow), @"overflowCountKnown":@(callbackSafe),
                @"callerWasMain":@(mainCaller), @"callerWasProcessorQueue":@(queueCaller), @"captureWasProcessorQueue":@YES,
                @"unsupported":@(mark->preview->unsupported + mark->output->unsupported),
                @"preview":SPAirCapacityViewSlots(mark->preview), @"output":SPAirCapacityViewSlots(mark->output)}};
        NSMutableDictionary *root = [@{@"summary":[self presentationOrderSummary], @"sourceGeneration":@(self->_sourceGeneration),
            @"configVersion":@(self->_configVersion), @"measurementEpoch":@(self->_measurementEpoch),
            @"airCadenceCausalTrace":causal, @"airFusedRifePresenter":mark->output->fusedSummary,
            @"capacityExtra":@{@"previewFusedPresenter":mark->preview->fusedSummary}} mutableCopy];
        NSMutableArray *rollingEvents = [NSMutableArray array];
        for (const auto &event : self->_presentationOrder.events()) [rollingEvents addObject:@{
            @"ptsNs":@(event.pts), @"presentedTimeNs":@(event.presented), @"frameID":@(event.frame),
            @"endpoint":event.output ? @"output" : @"preview", @"visible":@(event.visible), @"held":@(event.held), @"originalSynthetic":@(event.originalSynthetic)}];
        root[@"eventsInCallbackOrder"] = rollingEvents;
        root[@"airCurrentStatsTrace"] = mark->currentStats.metadata;
        root[@"airMeasurementTrace"] = @{@"schema":@"odf-air-measurement-events-v1", @"enabled":@(self->_measurementTrace != nullptr),
            @"incomplete":@([mark->measurement.metadata[@"incomplete"] boolValue] || [mark->preview->measurement.metadata[@"incomplete"] boolValue] || [mark->output->measurement.metadata[@"incomplete"] boolValue]),
            @"processor":mark->measurement.metadata, @"preview":mark->preview->measurement.metadata, @"output":mark->output->measurement.metadata};
        SPRifeBridge *service = self->_rife ?: self->_airResidentRetiredBridge;
        if (service.serviceTraceEnabled) {
            if (session) mark->serviceMark = [service captureServicePrefixForSessionAtCutoffHostTicks:mark->cutoff budget:budget];
            else {
                mark->serviceOwner = service;
                mark->serviceMark = [service captureServiceTraceAtCutoffHostTicks:mark->cutoff];
                root[@"airServiceTrace"] = [service serviceTraceMetadataForSnapshot:mark->serviceMark];
            }
        }
        root[@"capacitySealing"] = @{@"sealed":@(self->_airCapacitySealedHostTicks != 0), @"sealedHostTicks":@(self->_airCapacitySealedHostTicks)};
        if (session) root[@"retainedPayloadBudget"] = [budget snapshot] ?: @{};
        if (session) root[@"sessionCheckpoint"] = @{ @"sessionID": self->_airTraceSessionID ?: @"",
            @"cutoffHostTicks": @(mark->cutoff), @"processorCaptureBeginHostTicks": @(captureBegin),
            @"processorCaptureEndHostTicks": @(SPHostNow()), @"frozenRowStorage": @(freeze),
            @"previewCallbackCaptureBeginHostTicks": previewCallbacks ? @(previewCallbacks->beginHostTicks) : (id)NSNull.null,
            @"previewCallbackCaptureEndHostTicks": previewCallbacks ? @(previewCallbacks->endHostTicks) : (id)NSNull.null,
            @"outputCallbackCaptureBeginHostTicks": outputCallbacks ? @(outputCallbacks->beginHostTicks) : (id)NSNull.null,
            @"outputCallbackCaptureEndHostTicks": outputCallbacks ? @(outputCallbacks->endHostTicks) : (id)NSNull.null,
            @"recordingSaturated": @(self->_airTraceRecordingSaturated) };
        mark->root = root;
    };
    if (queueCaller) capture(); else dispatch_sync(_q, capture);
    return mark;
}
- (id)captureAndSealAirTraceSnapshotAtCutoffHostTicks:(uint64_t)cutoff {
    if (!NSThread.isMainThread) {
        __block id result;
        dispatch_sync(dispatch_get_main_queue(), ^{ result = [self captureAndSealAirTraceSnapshotAtCutoffHostTicks:cutoff]; });
        return result;
    }
    void (^seal)(void) = ^{
        if (!self->_airCapacitySealedHostTicks) {
            [self.preview sealAirCapacityCollectors]; [self.outputPreview sealAirCapacityCollectors];
            if (self->_airCadenceCallbacks) self->_airCadenceCallbacks->sealed = true;
            if (self->_airCurrentStatsCalls) self->_airCurrentStatsCalls->sealed = true;
            if (self->_measurementTrace) self->_measurementTrace->seal();
            if (self->_airCadenceBudget) self->_airCadenceBudget->sealed = true;
            if (self->_airDelayAlignmentEvents) self->_airDelayAlignmentEvents->sealed = true;
            SPRifeBridge *bridge = self->_rife ?: self->_airResidentRetiredBridge;
            [bridge sealServiceTraceForDiagnostics];
            self->_airCapacitySealedHostTicks = SPHostNow();
        }
    };
    if (dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self) seal(); else dispatch_sync(_q, seal);
    return [self captureAirTraceSnapshotAtCutoffHostTicks:cutoff];
}
- (NSDictionary *)airTraceSnapshotMetadata:(id)snapshot {
    return [snapshot isKindOfClass:SPAirCapacityCheckpoint.class] ? ((SPAirCapacityCheckpoint *)snapshot)->root : @{};
}
@end

template<class Row, class SelectMark, class Override, class Host, class Serialize>
static NSDictionary *SPAirWriteCapacityRows(NSString *directory, NSString *name, NSString *progress,
    NSArray<SPAirCapacityCheckpoint *> *checkpoints, NSArray<NSString *> *labels, NSArray<NSString *> *target,
    const std::vector<Row> &rows, SelectMark selectMark, Override overrideRow, Host host, Serialize serialize, NSError **error) {
    spAirDiagnostic::SharedTraceWriter writer(directory, name, progress, error);
    if (!writer.valid()) return nil;
    for (NSUInteger view = 0; view < checkpoints.count; ++view) {
        SPAirCapacityCheckpoint *checkpoint = checkpoints[view];
        const auto mark = selectMark(checkpoint);
        const NSUInteger identifier = writer.addView(labels[view], target);
        for (const auto &current : rows) {
            @autoreleasepool {
                const auto row = overrideRow(checkpoint, current);
                const uint64_t sequence = row.sequence;
                if (sequence > mark.total || (int64_t)host(row) > (int64_t)mark.cutoff) continue;
                if (!writer.append(identifier, sequence, serialize(row), error)) return nil;
            }
        }
    }
    return writer.finish(error);
}

struct SPAirFrozenFusedRow {
    uint64_t sequence;
    SPAirFusedRenderPtr record;
};

@implementation SPLiveProcessor (SPAirCapacityWriteExport)
- (NSDictionary *)writeAirTraceSnapshotsToDirectory:(NSString *)directory formal:(id)formal
    association:(id)association final:(id)final progressPath:(NSString *)progress error:(NSError **)error {
    NSMutableArray<SPAirCapacityCheckpoint *> *checkpoints = [NSMutableArray array];
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    NSArray *candidates = @[formal ?: NSNull.null, association ?: NSNull.null, final ?: NSNull.null];
    NSArray *names = @[@"formal", @"association", @"final"];
    for (NSUInteger index = 0; index < candidates.count; ++index) if ([candidates[index] isKindOfClass:SPAirCapacityCheckpoint.class]) {
        [checkpoints addObject:candidates[index]]; [labels addObject:names[index]];
    }
    if (!checkpoints.count) { spAirDiagnostic::setError(error, @"missing trace checkpoint", EINVAL); return nil; }
    NSMutableArray *files = [NSMutableArray array];
    SPAirCapacityCheckpoint *last = checkpoints.lastObject;
    for (NSUInteger endpoint = 0; endpoint < 2; ++endpoint) {
        const bool output = endpoint == 1;
        SPLivePreviewView *owner = output ? last->output->owner : last->preview->owner;
        NSString *endpointName = output ? @"output" : @"preview";
        auto selectView = [=](SPAirCapacityCheckpoint *mark) { return output ? mark->output : mark->preview; };
        {
            std::vector<spAirMeasurement::Event> liveRows;
            if (!last->frozenRows) [owner copyAirMeasurementRows:liveRows];
            const auto &rows = last->frozenRows ? selectView(last)->frozenMeasurement : liveRows;
            NSDictionary *file = SPAirWriteCapacityRows(directory, [endpointName stringByAppendingString:@"-measurement"], progress,
                checkpoints, labels, @[@"airMeasurementTrace", endpointName, @"records"], rows,
                [=](auto mark) { return selectView(mark)->measurement; }, [](auto, const auto &row) { return row; },
                [](const auto &row) { return row.recordHostTicks; }, [](const auto &row) { return SPAirMeasurementRow(row); }, error);
            if (!file) return nil; [files addObject:file];
        }
        {
            std::vector<SPAirFrameEvent> liveRows;
            if (!last->frozenRows) [owner copyAirCapacityFrames:liveRows];
            const auto &rows = last->frozenRows ? selectView(last)->frozenFrames : liveRows;
            NSDictionary *file = SPAirWriteCapacityRows(directory, [endpointName stringByAppendingString:@"-frames"], progress,
                checkpoints, labels, @[@"airCadenceCausalTrace", endpointName, @"events"], rows,
                [=](auto mark) { return selectView(mark)->frames; }, [](auto, const auto &row) { return row; },
                [](const auto &row) { return row.hostTicks; }, [=](const auto &row) {
                    return [SPAirFrameExport({row}, 1, endpointName, INT64_MAX)[@"events"] firstObject];
                }, error);
            if (!file) return nil; [files addObject:file];
        }
        {
            __block std::vector<SPAirSlotCallbackEvent> liveRows;
            if (!last->frozenRows) {
                void (^copy)(void) = ^{ [owner copyAirCapacitySlotCallbacks:liveRows]; };
                if (NSThread.isMainThread || [owner airCallbackTraceSealed]) copy(); else dispatch_sync(dispatch_get_main_queue(), copy);
            }
            const auto &rows = last->frozenRows ? selectView(last)->frozenCallbacks : liveRows;
            NSDictionary *file = SPAirWriteCapacityRows(directory, [endpointName stringByAppendingString:@"-slot-callbacks"], progress,
                checkpoints, labels, @[@"airCadenceCausalTrace", @"slots", endpointName, @"callbacks", @"events"], rows,
                [=](auto mark) { return selectView(mark)->callbacks; }, [](auto, const auto &row) { return row; },
                [](const auto &row) { return row.outcomeHostTicks; }, [](const auto &row) {
                    return [SPAirSlotCallbackExport({row}, 1, INT64_MAX)[@"events"] firstObject];
                }, error);
            if (!file) return nil; [files addObject:file];
        }
        {
            std::vector<SPAirSlotConsumeEvent> liveRows;
            if (!last->frozenRows) [owner copyAirCapacityConsumes:liveRows];
            const auto &rows = last->frozenRows ? selectView(last)->frozenConsumes : liveRows;
            NSDictionary *file = SPAirWriteCapacityRows(directory, [endpointName stringByAppendingString:@"-slot-consumes"], progress,
                checkpoints, labels, @[@"airCadenceCausalTrace", @"slots", endpointName, @"consumes", @"events"], rows,
                [=](auto mark) { return selectView(mark)->consumes; }, [=](auto mark, const auto &row) {
                    const auto &overrides = selectView(mark)->pendingConsumes;
                    auto found = overrides.find(row.sequence); return found == overrides.end() ? row : found->second;
                }, [](const auto &row) { return row.recordHostTicks; }, [](const auto &row) {
                    return [SPAirSlotConsumeExport({row}, 1, INT64_MAX)[@"events"] firstObject];
                }, error);
            if (!file) return nil; [files addObject:file];
        }
        {
            std::vector<SPAirFusedRenderPtr> liveRows;
            if (!last->frozenRows) [owner copyAirCapacityFused:liveRows];
            const auto &source = last->frozenRows ? selectView(last)->frozenFused : liveRows;
            std::vector<SPAirFrozenFusedRow> rows; rows.reserve(source.size());
            for (const auto &row : source) rows.push_back({row->sequence, row});
            NSArray *target = output ? @[@"airFusedRifePresenter", @"records"] : @[@"capacityExtra", @"previewFusedPresenter", @"records"];
            NSDictionary *file = SPAirWriteCapacityRows(directory, [endpointName stringByAppendingString:@"-fused-presenter"], progress,
                checkpoints, labels, target, rows, [=](auto mark) { return selectView(mark)->fused; },
                [=](auto mark, const auto &row) {
                    const auto &overrides = selectView(mark)->pendingFused;
                    auto found = overrides.find(row.sequence);
                    if (found == overrides.end()) return row;
                    auto frozen = SPAirFreezeFusedRecord(row.record);
                    SPAirApplyFusedTerminal(frozen, found->second);
                    return SPAirFrozenFusedRow{row.sequence, frozen};
                }, [](const auto &row) { return row.record->selectionHostTicks; },
                [](const auto &row) { return SPAirFusedRenderExport(row.record); }, error);
            if (!file) return nil; [files addObject:file];
        }
    }
    {
        __block std::vector<SPAirFrameEvent> liveRows;
        if (!last->frozenRows) {
            void (^copy)(void) = ^{ if (self->_airCadenceCallbacks) self->_airCadenceCallbacks->copy(liveRows); };
            if (dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self) copy(); else dispatch_sync(_q, copy);
        }
        const auto &rows = last->frozenRows ? last->frozenCallbacks : liveRows;
        NSDictionary *file = SPAirWriteCapacityRows(directory, @"processor-callbacks", progress, checkpoints, labels,
            @[@"airCadenceCausalTrace", @"callbacks", @"events"], rows, [](auto mark) { return mark->callbacks; },
            [](auto, const auto &row) { return row; }, [](const auto &row) { return row.hostTicks; },
            [](const auto &row) { return [SPAirFrameExport({row}, 1, nil, INT64_MAX)[@"events"] firstObject]; }, error);
        if (!file) return nil; [files addObject:file];
    }
    {
        __block std::vector<SPAirBudgetEvent> liveRows;
        if (!last->frozenRows) {
            void (^copy)(void) = ^{ if (self->_airCadenceBudget) self->_airCadenceBudget->copy(liveRows); };
            if (dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self) copy(); else dispatch_sync(_q, copy);
        }
        const auto &rows = last->frozenRows ? last->frozenBudget : liveRows;
        NSDictionary *file = SPAirWriteCapacityRows(directory, @"rate-budget", progress, checkpoints, labels,
            @[@"airCadenceCausalTrace", @"rateBudget", @"events"], rows, [](auto mark) { return mark->budget; },
            [](auto, const auto &row) { return row; }, [](const auto &row) { return row.hostTicks; },
            [](const auto &row) { return [SPAirBudgetExport({row}, 1, INT64_MAX)[@"events"] firstObject]; }, error);
        if (!file) return nil; [files addObject:file];
    }
    {
        __block std::vector<SPAirDelayAlignmentEvent> liveRows;
        if (!last->frozenRows) {
            void (^copy)(void) = ^{ if (self->_airDelayAlignmentEvents) self->_airDelayAlignmentEvents->copy(liveRows); };
            if (dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self) copy(); else dispatch_sync(_q, copy);
        }
        const auto &rows = last->frozenRows ? last->frozenDelay : liveRows;
        NSDictionary *file = SPAirWriteCapacityRows(directory, @"delay-alignment", progress, checkpoints, labels,
            @[@"airCadenceCausalTrace", @"delayAlignment", @"recomputes", @"events"], rows, [](auto mark) { return mark->delay; },
            [](auto, const auto &row) { return row; }, [](const auto &row) { return row.hostTicks; },
            [](const auto &row) { return [SPAirDelayAlignmentExport({row}, 1, INT64_MAX)[@"events"] firstObject]; }, error);
        if (!file) return nil; [files addObject:file];
    }
    {
        __block std::vector<SPAirCurrentStatsEvent> liveRows;
        if (!last->frozenRows) {
            void (^copy)(void) = ^{ if (self->_airCurrentStatsCalls) self->_airCurrentStatsCalls->copy(liveRows); };
            if (dispatch_get_specific(SPLiveQueueKey) == (__bridge void *)self) copy(); else dispatch_sync(_q, copy);
        }
        const auto &rows = last->frozenRows ? last->frozenCurrentStats : liveRows;
        NSDictionary *file = SPAirWriteCapacityRows(directory, @"stats-current-calls", progress, checkpoints, labels,
            @[@"airCurrentStatsTrace", @"records"], rows, [](auto mark) { return mark->currentStats; },
            [](auto, const auto &row) { return row; }, [](const auto &row) { return row.endHostTicks; },
            [](const auto &row) { return @{ @"sequence": @(row.sequence), @"beginHostTicks": @(row.beginHostTicks),
                @"endHostTicks": @(row.endHostTicks), @"threadID": @(row.threadID) }; }, error);
        if (!file) return nil; [files addObject:file];
    }
    {
        std::vector<spAirMeasurement::Event> liveRows;
        if (!last->frozenRows && _measurementTrace) liveRows = _measurementTrace->snapshot().rows;
        const auto &rows = last->frozenRows ? last->frozenMeasurement : liveRows;
        NSDictionary *file = SPAirWriteCapacityRows(directory, @"processor-measurement", progress,
            checkpoints, labels, @[@"airMeasurementTrace", @"processor", @"records"], rows,
            [](auto mark) { return mark->measurement; }, [](auto, const auto &row) { return row; },
            [](const auto &row) { return row.recordHostTicks; }, [](const auto &row) { return SPAirMeasurementRow(row); }, error);
        if (!file) return nil; [files addObject:file];
    }
    if (!last->session) {
    for (NSString *ring in @[@"jobs", @"events"]) {
        spAirDiagnostic::SharedTraceWriter writer(directory, [@"service-" stringByAppendingString:ring], progress, error);
        if (!writer.valid()) return nil;
        for (NSUInteger view = 0; view < checkpoints.count; ++view) {
            SPAirCapacityCheckpoint *mark = checkpoints[view];
            const NSUInteger identifier = writer.addView(labels[view], @[@"airServiceTrace", ring, @"records"]);
            auto *writerPointer = &writer;
            __block NSError *blockError = nil;
            const BOOL ok = [mark->serviceOwner enumerateServiceTraceSnapshot:mark->serviceMark ring:ring usingBlock:^BOOL(uint64_t sequence, NSDictionary *row) {
                NSError *rowError = nil;
                const bool written = writerPointer->append(identifier, sequence, row, &rowError);
                if (!written) blockError = rowError;
                return written;
            }];
            if (!ok) { if (error) *error = blockError; return nil; }
        }
        NSDictionary *file = writer.finish(error); if (!file) return nil; [files addObject:file];
    }
    {
        spAirDiagnostic::NDJSONWriter writer(directory, @"service-gpu-gate", progress, error);
        if (!writer.valid()) return nil;
        NSMutableArray *gpuViews = [NSMutableArray array];
        for (NSUInteger view = 0; view < checkpoints.count; ++view) [gpuViews addObject:[@{
            @"name":labels[view], @"target":@[@"airServiceTrace", @"gpu", @"records"],
            @"indexRanges":[NSMutableArray array], @"rows":@0} mutableCopy]];
        auto *pointer = &writer;
        __block NSError *blockError = nil;
        BOOL ok = [last->serviceOwner enumerateServiceTraceSnapshot:last->serviceMark ring:@"gpu" usingBlock:^BOOL(uint64_t sequence, NSDictionary *row) {
            NSError *rowError = nil;
            const uint64_t index = pointer->rows();
            if (!pointer->append(row, &rowError)) { blockError = rowError; return NO; }
            const uint64_t host = [row[@"sampleHostTicks"] unsignedLongLongValue];
            for (NSUInteger view = 0; view < checkpoints.count; ++view) {
                SPAirCapacityCheckpoint *checkpoint = checkpoints[view];
                NSDictionary *metadata = checkpoint->root[@"airServiceTrace"][@"gpu"];
                if (sequence > [metadata[@"total"] unsignedLongLongValue] || host > checkpoint->cutoff) continue;
                NSMutableDictionary *entry = gpuViews[view]; NSMutableArray *ranges = entry[@"indexRanges"];
                NSMutableArray *range = ranges.lastObject;
                if (range && [range[1] unsignedLongLongValue] == index) range[1] = @(index + 1);
                else [ranges addObject:[@[@(index), @(index + 1)] mutableCopy]];
                entry[@"rows"] = @([entry[@"rows"] unsignedLongLongValue] + 1);
            }
            return YES;
        }];
        if (!ok) { if (error) *error = blockError; return nil; }
        NSMutableDictionary *descriptor = [writer.finish(error) mutableCopy];
        if (!descriptor) return nil;
        descriptor[@"views"] = gpuViews; descriptor[@"recordingSchema"] = @"odf-service-gpu-gate-v1";
        [files addObject:descriptor];
    }
    {
        spAirDiagnostic::NDJSONWriter writer(directory, @"service-gpu-body", progress, error);
        if (!writer.valid()) return nil;
        auto *pointer = &writer; __block NSError *blockError = nil;
        const BOOL ok = [last->serviceOwner enumerateServiceGPUBodyForSnapshot:last->serviceMark usingBlock:^BOOL(uint64_t sequence, NSDictionary *row) {
            NSError *rowError = nil;
            const bool written = pointer->append(row, &rowError);
            if (!written) blockError = rowError;
            return written;
        }];
        if (!ok) { if (error) *error = blockError; return nil; }
        NSDictionary *base = writer.finish(error); if (!base) return nil;
        NSMutableDictionary *descriptor = [base mutableCopy];
        descriptor[@"coverageScope"] = @"b_diagnostic_detail";
        descriptor[@"views"] = @[@{@"name":labels.lastObject,
            @"target":@[@"airServiceTrace", @"gpuBodyDiagnostics", @"records"],
            @"rows":base[@"rows"], @"indexRanges":@[@[@0, base[@"rows"]]]}];
        [files addObject:descriptor];
    }
    }
    NSMutableDictionary *views = [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index < checkpoints.count; ++index) views[labels[index]] = checkpoints[index]->root;
    return @{@"files":files, @"views":views, @"schema":@"odf-air-capacity-native-traces-v1"};
}
- (NSDictionary *)writeRetiredAirServiceTraces:(NSArray<NSDictionary *> *)entries formal:(id)formal association:(id)association
    toDirectory:(NSString *)directory progressPath:(NSString *)progress error:(NSError **)error {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *stores = [NSMutableDictionary dictionary];
    NSMutableDictionary *views = [NSMutableDictionary dictionary];
    NSArray *labels = @[@"formal", @"association", @"final"];
    BOOL complete = YES;
    for (NSDictionary *entry in entries) {
        NSObject *token = entry[@"snapshot"];
        NSDictionary *metadata = token ? [SPRifeBridge serviceTraceMetadataForDetachedSnapshot:token] : nil;
        NSString *storeID = metadata[@"storeID"];
        if (![metadata[@"enabled"] boolValue] || ![storeID isKindOfClass:NSString.class] || stores[storeID]) { complete = NO; continue; }
        NSMutableDictionary *finalMetadata = [metadata mutableCopy];
        NSDictionary *context = entry[@"context"] ?: @{};
        finalMetadata[@"sessionRetirementContext"] = context;
        finalMetadata[@"processorCompletionDrainObserved"] = context[@"processorCompletionDrainObserved"] ?: @NO;
        finalMetadata[@"processorCompletionDrainReady"] = @([context[@"inferenceTrackingCompleteAtFence"] boolValue] &&
            [context[@"pendingInferenceJobsAtFence"] unsignedLongLongValue] == 0 && [context[@"processorCompletionDrainObserved"] boolValue]);
        stores[storeID] = [@{ @"final": token, @"finalMetadata": finalMetadata } mutableCopy];
    }
    NSArray *prefixes = @[formal ?: NSNull.null, association ?: NSNull.null];
    for (NSUInteger index = 0; index < prefixes.count; ++index) {
        if (![prefixes[index] isKindOfClass:SPAirCapacityCheckpoint.class]) continue;
        SPAirCapacityCheckpoint *checkpoint = prefixes[index];
        NSString *label = labels[index];
        NSDictionary *prefixMetadata = checkpoint->serviceMark ? [SPRifeBridge serviceTraceMetadataForDetachedSnapshot:checkpoint->serviceMark] : nil;
        NSString *prefixID = prefixMetadata[@"storeID"];
        for (NSString *storeID in stores) {
            NSMutableDictionary *store = stores[storeID];
            NSDictionary *metadata = store[@"finalMetadata"];
            if ([storeID isEqual:prefixID]) { store[label] = checkpoint->serviceMark; store[[label stringByAppendingString:@"Metadata"]] = prefixMetadata; }
            else if ([metadata[@"execTailReached"] boolValue] && [metadata[@"execTailReachedHostTicks"] unsignedLongLongValue] <= checkpoint->cutoff) {
                store[label] = store[@"final"]; store[[label stringByAppendingString:@"Metadata"]] = metadata;
            }
        }
        if (prefixID && !stores[prefixID]) {
            // Preserve the actual prefix if a retirement was lost. It remains
            // incomplete and cannot manufacture a final producer ledger.
            stores[prefixID] = [@{label:checkpoint->serviceMark, [label stringByAppendingString:@"Metadata"]:prefixMetadata} mutableCopy];
            complete = NO;
        }
    }
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *storeID in [[stores allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *store = stores[storeID];
        NSMutableArray *presentLabels = [NSMutableArray array];
        for (NSString *label in labels) if (store[label]) {
            [presentLabels addObject:label];
            if (!views[label]) views[label] = [@{@"airServiceTraces":[NSMutableDictionary dictionary]} mutableCopy];
            views[label][@"airServiceTraces"][storeID] = store[[label stringByAppendingString:@"Metadata"]];
        }
        for (NSString *ring in @[@"jobs", @"events"]) {
            spAirDiagnostic::SharedTraceWriter writer(directory, [NSString stringWithFormat:@"service-%@-%@", storeID, ring], progress, error);
            if (!writer.valid()) return nil;
            for (NSString *label in presentLabels) {
                const NSUInteger view = writer.addView(label, @[@"airServiceTraces", storeID, ring, @"records"]);
                auto *output = &writer; __block NSError *rowError = nil;
                const BOOL ok = [SPRifeBridge enumerateDetachedServiceTraceSnapshot:store[label] ring:ring usingBlock:^BOOL(uint64_t sequence, NSDictionary *row) {
                    return output->append(view, sequence, row, &rowError);
                }];
                if (!ok) { if (error) *error = rowError; if (!rowError) spAirDiagnostic::setError(error, @"enumerate detached service trace", EIO); return nil; }
            }
            NSDictionary *descriptor = writer.finish(error); if (!descriptor) return nil; [files addObject:descriptor];
        }
        NSString *lastLabel = presentLabels.lastObject;
        NSObject *lastToken = store[lastLabel];
        {
            spAirDiagnostic::NDJSONWriter writer(directory, [NSString stringWithFormat:@"service-%@-gpu-gate", storeID], progress, error);
            if (!writer.valid()) return nil;
            NSMutableArray *gpuViews = [NSMutableArray array];
            for (NSString *label in presentLabels) [gpuViews addObject:[@{ @"name":label,
                @"target":@[@"airServiceTraces", storeID, @"gpu", @"records"], @"rows":@0, @"indexRanges":[NSMutableArray array] } mutableCopy]];
            auto *output = &writer; __block NSError *rowError = nil;
            const BOOL ok = [SPRifeBridge enumerateDetachedServiceTraceSnapshot:lastToken ring:@"gpu" usingBlock:^BOOL(uint64_t sequence, NSDictionary *row) {
                const uint64_t position = output->rows();
                if (!output->append(row, &rowError)) return NO;
                const uint64_t host = [row[@"sampleHostTicks"] unsignedLongLongValue];
                for (NSMutableDictionary *view in gpuViews) {
                    NSDictionary *metadata = store[[view[@"name"] stringByAppendingString:@"Metadata"]][@"gpu"];
                    if (sequence > [metadata[@"total"] unsignedLongLongValue] || host > [metadata[@"cutoffHostTicks"] unsignedLongLongValue]) continue;
                    NSMutableArray *ranges = view[@"indexRanges"], *range = ranges.lastObject;
                    if (range && [range[1] unsignedLongLongValue] == position) range[1] = @(position + 1);
                    else [ranges addObject:[@[@(position), @(position + 1)] mutableCopy]];
                    view[@"rows"] = @([view[@"rows"] unsignedLongLongValue] + 1);
                }
                return YES;
            }];
            if (!ok) { if (error) *error = rowError; if (!rowError) spAirDiagnostic::setError(error, @"enumerate detached GPU gate", EIO); return nil; }
            NSMutableDictionary *descriptor = [writer.finish(error) mutableCopy]; if (!descriptor) return nil;
            descriptor[@"views"] = gpuViews; descriptor[@"recordingSchema"] = @"odf-service-gpu-gate-v1"; [files addObject:descriptor];
        }
        {
            spAirDiagnostic::NDJSONWriter writer(directory, [NSString stringWithFormat:@"service-%@-gpu-body", storeID], progress, error);
            if (!writer.valid()) return nil;
            auto *output = &writer; __block NSError *rowError = nil;
            const BOOL ok = [SPRifeBridge enumerateDetachedServiceGPUBodyForSnapshot:lastToken usingBlock:^BOOL(uint64_t sequence, NSDictionary *row) {
                return output->append(row, &rowError);
            }];
            if (!ok) { if (error) *error = rowError; if (!rowError) spAirDiagnostic::setError(error, @"enumerate detached GPU body", EIO); return nil; }
            NSDictionary *base = writer.finish(error); if (!base) return nil;
            NSMutableDictionary *descriptor = [base mutableCopy]; descriptor[@"coverageScope"] = @"b_diagnostic_detail";
            descriptor[@"views"] = @[@{ @"name":lastLabel, @"target":@[@"airServiceTraces", storeID, @"gpuBodyDiagnostics", @"records"],
                @"rows":base[@"rows"], @"indexRanges":@[@[@0, base[@"rows"]]] }];
            [files addObject:descriptor];
        }
    }
    return @{ @"schema":@"odf-air-session-service-traces-v1", @"files":files, @"views":views,
        @"complete":@(complete), @"storeCount":@(stores.count), @"actualRetirements":@(entries.count) };
}
@end
