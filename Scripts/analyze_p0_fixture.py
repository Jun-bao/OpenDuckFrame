#!/usr/bin/env python3
"""Offline fixture evidence only: bounded first-departure and same-frame timing."""
import argparse, collections, ctypes, json, math, re, statistics

class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

MAX_STATUS_GAP_SECONDS = 0.100
DEPARTURE_SECONDS = 0.200

def visible_state(row):
    """Return actual sampled state and its identity; missing data is unknown."""
    cap, proc = row.get("capture"), row.get("processor")
    if not isinstance(cap, dict) or not isinstance(proc, dict): return None, None, "missing_capture_or_processor"
    fixture = cap.get("r8Fixture")
    if not isinstance(fixture, dict) or not isinstance(fixture.get("events"), list) or not isinstance(proc.get("r8OutputTimeline"), list):
        return None, None, "missing_frame_evidence"
    bool_keys = ("realWindowCapture", "capturePaused", "targetOnscreen", "outputTargetReady", "outputPanelVisible")
    if any(type(row.get(k)) is not bool for k in bool_keys) or type(cap.get("running")) is not bool or type(cap.get("paused")) is not bool:
        return None, None, "missing_boolean_state"
    alpha = row.get("outputPanelAlpha")
    if type(alpha) not in (int, float) or not math.isfinite(alpha): return None, None, "missing_alpha"
    if not row["realWindowCapture"] or row["capturePaused"] or not cap["running"] or cap["paused"] or not row["targetOnscreen"] or not row["outputTargetReady"] or not row["outputPanelVisible"] or alpha < .99:
        return False, None, "not_expected_visible"
    if proc.get("snapshotStale") is True: return None, None, "stale_processor_snapshot"
    fields = (cap.get("generation"), proc.get("sourceGeneration"), proc.get("configVersion"), proc.get("measurementEpoch"),
              row.get("targetWindowID"), row.get("targetOwnerPID"), row.get("frontProcessActualPID"), row.get("r8ProcessID"))
    if any(type(x) is not int or x <= 0 for x in fields): return None, None, "missing_identity"
    clock_epoch = proc.get("clockEpoch")
    if type(clock_epoch) is not int or clock_epoch < 0: return None, None, "missing_clock_epoch"
    generation, processor_generation, config, epoch, window, owner, front, own_pid = fields
    if generation != processor_generation: return None, None, "generation_mismatch"
    if front == owner:
        if row.get("targetFrontmostMatch") is not True: return None, None, "source_window_not_verified_front"
        mode = "source_front"
    elif front == own_pid:
        if row.get("outputPanelIsKey") is not True: return None, None, "output_not_verified_key"
        mode = "output_front"
    else:
        return False, None, "other_app_front"
    return True, (generation, config, epoch, clock_epoch, window, owner, mode), "sampled_expected_visible"

def visible_segments(samples, start, end):
    """Join only consecutive good samples; a gap is unknown, not visibility."""
    samples.sort(key=lambda item: item[0])
    segments, current = [], None
    counts = collections.Counter()
    for t, row in samples:
        if not start <= t <= end: continue
        good, cohort, reason = visible_state(row); counts[reason] += 1
        if good is not True:
            if current is not None: segments.append(current); current = None
            continue
        if current is None or current[2] != cohort or t-current[1] > MAX_STATUS_GAP_SECONDS+1e-9:
            if current is not None: segments.append(current)
            current = [t, t, cohort, 1]
        else:
            current[1] = t; current[3] += 1
    if current is not None: segments.append(current)
    return [s for s in segments if s[1]-s[0] >= DEPARTURE_SECONDS-1e-9], counts

def summarize(values):
    v = sorted(x for x in values if math.isfinite(x))
    return {"n": len(v), "p50Ms": statistics.median(v) if v else None,
            "p95Ms": v[int((len(v)-1)*.95)] if v else None}

def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)

def analyze(source, rows, start, end, ticks_to_seconds):
    draws = []
    for line in source:
        if not line.startswith("sourceDraw "): continue
        fields = dict(re.findall(r"(\w+)=([^ ]+)", line))
        try:
            t, ident = float(fields["monotonic"]), int(fields["encodedSequence"])
            if start <= t <= end: draws.append((t, ident))
        except (KeyError, ValueError): pass
    captures, outputs, status_samples, unlocatable_status_rows = {}, {}, [], 0
    for row in rows:
        if not isinstance(row, dict): unlocatable_status_rows += 1; continue
        timestamp = row.get("monotonicSeconds")
        if not finite_number(timestamp): unlocatable_status_rows += 1
        if type(timestamp) in (int, float) and math.isfinite(timestamp) and start <= timestamp <= end:
            status_samples.append((timestamp, row))
        capture = row.get("capture") if isinstance(row.get("capture"), dict) else {}
        fixture = capture.get("r8Fixture") if isinstance(capture.get("r8Fixture"), dict) else {}
        cap_events = fixture.get("events") if isinstance(fixture.get("events"), list) else []
        processor = row.get("processor") if isinstance(row.get("processor"), dict) else {}
        out_events = processor.get("r8OutputTimeline") if isinstance(processor.get("r8OutputTimeline"), list) else []
        malformed = False
        for e in cap_events:
            if not isinstance(e, dict) or not finite_number(e.get("captureHost")):
                malformed = True; continue
            if start <= e["captureHost"]*ticks_to_seconds <= end:
                generation = e.get("generation") if type(e.get("generation")) is int else None
                sequence = e.get("receivedSequence")
                captures[(generation, sequence if type(sequence) is int else ("host",e["captureHost"]))] = e
        for e in out_events:
            if not isinstance(e, dict): malformed = True; continue
            host = e.get("presentedTime") if e.get("kind") == "presented" else e.get("captureHost")
            timestamp = host if e.get("kind") == "presented" else (host*ticks_to_seconds if finite_number(host) else None)
            if not finite_number(timestamp): malformed = True; continue
            if e.get("kind") == "presented" and e.get("counts") is True and timestamp <= 0:
                malformed = True; continue
            if finite_number(timestamp) and start <= timestamp <= end:
                outputs[(e.get("kind"), e.get("frameID"), e.get("generation"), e.get("configVersion"), e.get("measurementEpoch"))] = e
        if malformed and type(row.get("monotonicSeconds")) in (int,float) and start <= row["monotonicSeconds"] <= end:
            status_samples.append((row["monotonicSeconds"], {}))
    capture_list = [e for e in captures.values() if e.get("decoded") is True and type(e.get("frameNumber")) is int and e["frameNumber"] >= 0 and type(e.get("receivedSequence")) is int and type(e.get("generation")) is int]
    by_host = {(e.get("generation"), e.get("captureHost")): e for e in capture_list}
    positive = []
    for key, event in outputs.items():
        if key[0] != "presented" or not start <= event.get("presentedTime", 0) <= end: continue
        if not event.get("counts") or not event.get("windowVisible") or not event.get("exposed") or event.get("occluded"): continue
        submission = outputs.get(("submitted",)+key[1:]); enqueue = outputs.get(("enqueued",)+key[1:])
        if not submission or submission.get("synthetic"): continue
        cap = by_host.get((submission.get("generation"), submission.get("captureHost")))
        if cap and submission.get("decoded") is True and type(submission.get("frameNumber")) is int and submission.get("frameNumber") == cap.get("frameNumber"):
            positive.append((event, submission, enqueue, cap))
    draw_ids = collections.defaultdict(list)
    for t, ident in draws: draw_ids[ident].append(t)
    draw_capture, capture_present, draw_present, capture_ready, copy_ready_enqueue, enqueue_submit = [], [], [], [], [], []
    for e in capture_list:
        cap_time = e["captureHost"]*ticks_to_seconds
        # No invented matching across wrap or reused identifiers.
        matches = [t for t in draw_ids[e["frameNumber"]] if t <= cap_time]
        if len(matches) == 1: draw_capture.append((cap_time-matches[0])*1000)
    for presented, submitted, enqueued, cap in positive:
        cp = cap["captureHost"]*ticks_to_seconds
        t = presented["presentedTime"]
        if t >= cp: capture_present.append((t-cp)*1000)
        matches = [x for x in draw_ids[cap["frameNumber"]] if x <= cp]
        if len(matches) == 1 and t >= matches[0]: draw_present.append((t-matches[0])*1000)
        if finite_number(cap.get("readyHost")) and cap["readyHost"] >= cap["captureHost"]: capture_ready.append((cap["readyHost"]-cap["captureHost"])*ticks_to_seconds*1000)
        if enqueued and finite_number(enqueued.get("readyHost")) and finite_number(cap.get("readyHost")) and enqueued["readyHost"] >= cap["readyHost"] > 0:
            copy_ready_enqueue.append((enqueued["readyHost"]-cap["readyHost"])*ticks_to_seconds*1000)
        if enqueued and finite_number(submitted.get("submitHost")) and finite_number(enqueued.get("readyHost")) and submitted["submitHost"] >= enqueued["readyHost"] > 0:
            enqueue_submit.append((submitted["submitHost"]-enqueued["readyHost"])*ticks_to_seconds*1000)
    events = [(t, "draw", n, None) for t,n in draws]
    events += [(e["captureHost"]*ticks_to_seconds, "capture", e["frameNumber"], (e.get("generation"),)) for e in capture_list]
    events += [(e["captureHost"]*ticks_to_seconds, "capture_unknown", None, (e.get("generation"),)) for e in captures.values()
               if e.get("decoded") is not True or type(e.get("frameNumber")) is not int or e["frameNumber"] < 0 or type(e.get("receivedSequence")) is not int or type(e.get("generation")) is not int]
    events += [(p["presentedTime"], "present", c["frameNumber"], (s.get("generation"),s.get("configVersion"),s.get("measurementEpoch"),s.get("clockEpoch"))) for p,s,_,c in positive]
    positive_keys = {(p.get("frameID"),p.get("generation"),p.get("configVersion"),p.get("measurementEpoch")) for p,_,_,_ in positive}
    events += [(e["presentedTime"], "present_unknown", None, (e.get("generation"),e.get("configVersion"),e.get("measurementEpoch")))
               for e in outputs.values() if e.get("kind") == "presented" and e.get("counts") is not False and
               (e.get("frameID"),e.get("generation"),e.get("configVersion"),e.get("measurementEpoch")) not in positive_keys]
    events.sort(key=lambda e: (e[0], e[1])); first = None; evaluable = False
    cohorts = {(s.get("generation"), s.get("configVersion"), s.get("measurementEpoch"), s.get("clockEpoch")) for _,s,_,_ in positive}
    segments, status_counts = visible_segments(status_samples, start, end)
    # A malformed/untimed row cannot be placed on the timeline, so it may
    # hide a visibility or identity transition anywhere in this input file.
    if unlocatable_status_rows: segments = []
    for seg_start, seg_end, cohort, _ in segments:
        state = {}; primed = None; draw_advanced = False
        for t, kind, ident, identity in events:
            if t < seg_start or t > seg_end: continue
            if kind == "capture_unknown" and identity in ((cohort[0],),(None,)):
                state.pop("capture",None); primed = None; continue
            if kind == "present_unknown" and all(a is None or a == b for a,b in zip(identity,cohort[:3])):
                state.pop("present",None); primed = None; continue
            if kind == "capture" and identity != (cohort[0],): continue
            if kind == "present" and identity != cohort[:4]: continue
            old = state.get(kind); changed = old is None or old[0] != ident
            if changed:
                if kind == "draw" and old is not None: draw_advanced = True
                state[kind] = (ident, t)
            if not all(k in state for k in ("draw", "capture", "present")): continue
            if primed is None: primed = t
            if kind != "draw" or not changed or not draw_advanced: continue
            if t-primed >= DEPARTURE_SECONDS-1e-9: evaluable = True
            if t-state["capture"][1] >= DEPARTURE_SECONDS-1e-9:
                first = (t, "capture_content_not_advancing", seg_start, seg_end, cohort); evaluable = True; break
            if state["capture"][1] > state["present"][1] and t-state["present"][1] >= DEPARTURE_SECONDS-1e-9:
                first = (t, "visible_present_content_not_advancing", seg_start, seg_end, cohort); evaluable = True; break
        if first: break
    fragment = []
    if first:
        fragment = [{"time":t,"stage":k,"fixtureFrame":n} for t,k,n,identity in events
                    if max(first[2],first[0]-.2) <= t <= min(first[3],first[0]+.2) and
                    (k == "draw" or (k == "capture" and identity == (first[4][0],)) or (k == "present" and identity == first[4][:4]))][-200:]
    return {"window": [start,end], "draws":len(draws), "captureDecoded":len(capture_list), "matchingVisibleSourcePresents":len(positive),
            "drawToCapture":summarize(draw_capture), "captureToReady":summarize(capture_ready),
            "copyReadyToEnqueue":summarize(copy_ready_enqueue), "enqueueToSubmit":summarize(enqueue_submit),
            "captureToPresent":summarize(capture_present), "drawToPresent":summarize(draw_present),
            "firstDeparture": {"time":first[0],"kind":first[1],"classification":"sampled_suspected", "thresholdMs":200,"fragment":fragment} if first else None,
            "firstDepartureStatus": "sampled_suspected" if first else ("sampled_no_suspicion" if evaluable else "unknown"),
            "firstDepartureEligible":evaluable, "statusSampleCount":len(status_samples), "statusCounts":dict(status_counts),
            "unlocatableStatusRows":unlocatable_status_rows,
            "eligibleSampledSegments":[{"start":s[0],"end":s[1],"generation":s[2][0],"config":s[2][1],"measurementEpoch":s[2][2],"clockEpoch":s[2][3],"focus":s[2][6],"samples":s[3]} for s in segments],
            "maxStatusGapMs":MAX_STATUS_GAP_SECONDS*1000, "cohortCount":len(cohorts), "geometryVersion":None,
            "scope":"fixture IDs; actual state sampled at <=100ms within eligible segments; brief unobserved changes remain possible; suspected is not proof of continuous visibility or freeze; null/unknown is not a pass"}

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("source"); ap.add_argument("live"); ap.add_argument("--start",type=float,required=True); ap.add_argument("--end",type=float,required=True); args=ap.parse_args()
    if args.end <= args.start: ap.error("end must exceed start")
    tb=Timebase(); ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(tb))
    with open(args.source) as s, open(args.live) as f:
        def rows():
            for line in f:
                try: yield json.loads(line)
                except json.JSONDecodeError: yield None
        print(json.dumps(analyze(s,rows(),args.start,args.end,tb.numer/tb.denom/1e9),ensure_ascii=False,indent=2))
if __name__ == '__main__': main()
