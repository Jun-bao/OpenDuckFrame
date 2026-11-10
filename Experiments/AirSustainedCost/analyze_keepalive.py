#!/usr/bin/env python3
"""CPU-only review of the single-SIMD-group resident keepalive diagnostic.

Requires an external pre-run manifest for the NEW binary and source/config
evidence. Never invokes native, macmon, a GPU API, SSH, or a repeat experiment.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from collections import Counter
from decimal import Decimal as D
from pathlib import Path

import analyze as native_analysis
import analyze_observed_comparison as observed

MODEL_SHA = "ef29a643a76a9202600458a23dddce16919337ef01743d0fbe817684ec990f74"
COMMON_SHA = "b863c9a20210430fdc4a32015723d41a10fdec6d9b91aa6b2986cebb97bbea40"
NS = 1_000_000_000


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def distribution(values):
    values = list(values)
    result = native_analysis.distribution(values)
    if result:
        result["p99"] = native_analysis.quantile(values, '.99')
    return result


def subset_mismatches(expected, actual, prefix=""):
    differences = []
    for key, value in expected.items():
        path = prefix + key
        if isinstance(value, dict):
            differences.extend(subset_mismatches(value, actual.get(key) or {}, path + "."))
        elif actual.get(key) != value:
            differences.append({"field": path, "expected": value, "actual": actual.get(key)})
    return differences


def manifest_review(manifest, manifest_path, raw, coordinator):
    errors, files = [], []
    expected = manifest.get("expected_sha256") or {}
    if manifest.get("schema") != "odf-keepalive-analysis-manifest-v1":
        errors.append("manifest_schema")
    for name in ("binary", "model", "observer_helper"):
        value = expected.get(name)
        if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value.lower()):
            errors.append("manifest_missing_sha:" + name)
    if expected.get("model") != MODEL_SHA:
        errors.append("manifest_model_is_not_frozen_original_EF29")
    for name in ("binary", "model"):
        if ((coordinator.get("expected_sha256") or {}).get(name) != expected.get(name)
                or (coordinator.get("actual_sha256") or {}).get(name) != expected.get(name)):
            errors.append("coordinator_actual_expected_mismatch:" + name)
    evidence = manifest.get("evidence_files") or []
    if not evidence:
        errors.append("source_helper_configuration_evidence_missing")
    for item in evidence:
        path = manifest_path.parent / item["path"]
        try:
            actual = sha(path)
        except OSError as error:
            actual = None
            errors.append("evidence_unreadable:" + item.get("label", item["path"]) + ":" + str(error))
        matched = actual == item.get("sha256")
        files.append({"label": item.get("label"), "path": item["path"], "expected": item.get("sha256"),
                      "actual": actual, "matched": matched})
        if not matched:
            errors.append("evidence_hash_mismatch:" + item.get("label", item["path"]))
    if not any(f["matched"] and f["actual"] == expected.get("observer_helper") for f in files):
        errors.append("expected_observer_helper_evidence_not_found")
    keeper = raw.get("residentKeepAlive") or {}
    native_config = raw.get("configuration") or {}
    mismatches = subset_mismatches(manifest.get("expected_native_configuration") or {}, native_config, "native.")
    mismatches += subset_mismatches(manifest.get("expected_keeper_configuration") or {}, keeper.get("configuration") or {}, "keeper.")
    if not manifest.get("expected_native_configuration") or not manifest.get("expected_keeper_configuration"):
        errors.append("expected_configuration_missing")
    if mismatches:
        errors.append("manifest_configuration_mismatch")
    model = raw.get("modelIdentity") or {}
    if (model.get("sha256") != MODEL_SHA or model.get("stageCount") != 5 or model.get("tensorCount") != 158
            or model.get("overrideApplied") is not False):
        errors.append("actual_original_model_identity_not_verified")
    if (native_config.get("residentKeepAliveEnabled") is not True or keeper.get("enabled") is not True
            or (raw.get("gapFill") or {}).get("enabled") is True
            or (raw.get("realWorkFill") or {}).get("enabled") is True
            or native_config.get("gapFillEnabled") is True or native_config.get("realWorkFillEnabled") is True):
        errors.append("keeper_not_enabled_or_old_filler_mixed_in")
    return {"verified": not errors, "errors": errors, "expectedSHA256": expected,
            "manifestSHA256": sha(manifest_path), "evidenceFiles": files, "configurationMismatches": mismatches,
            "actualModelIdentity": model, "scope": "External frozen manifest, immutable evidence copies and coordinator actual/expected hashes; no hard-coded historical native binary SHA and no manifest/cfg self-hash cycle."}


def cb_row(row):
    s, e = (native_analysis.number(row.get(k)) for k in ("gpuStartSeconds", "gpuEndSeconds"))
    begin, end, terminal = (native_analysis.integer(row.get(k)) for k in ("commitBeginNs", "commitEndNs", "terminalObservedNs"))
    mask = native_analysis.integer(row.get("validityMask"))
    valid = (s is not None and e is not None and 0 < s < e and row.get("status") == 4
             and mask is not None and mask & 7 == 7 and begin is not None and end is not None
             and terminal is not None and 0 < begin <= end <= terminal and not row.get("error"))
    ms = None
    if valid:
        # Restore the native Double operands before its subtraction/multiplication.
        # Large absolute GPU seconds must not be treated as integer nanoseconds.
        measured = (float(e)-float(s))*1000
        reported = native_analysis.number(row.get("gpuDurationMs"))
        valid = math.isfinite(measured) and measured > 0 and reported is not None and float(reported) == measured
        ms = D(str(measured)) if valid else None
    return {"cbID": row.get("cbID"), "phase": row.get("phase"), "iterations": row.get("iterations"),
            "valid": valid, "gpuDurationMs": ms, "commitBeginNs": begin, "commitEndNs": end,
            "terminalObservedNs": terminal, "error": row.get("error")}


def keeper_review(raw):
    keeper = raw.get("residentKeepAlive") or {}
    config = keeper.get("configuration") or {}
    calibration = keeper.get("calibration") or {}
    lifecycle = keeper.get("lifecycle") or {}
    calibration_rows = [cb_row(r) for r in calibration.get("records", [])]
    operational = [cb_row(r) for r in keeper.get("records", [])]
    rows = calibration_rows + operational
    errors = []
    ids = [r["cbID"] for r in rows]
    attempted = native_analysis.integer(keeper.get("recordsAttempted"))
    ledger = (attempted is not None and attempted == len(rows) and all(native_analysis.integer(i) is not None for i in ids)
              and sorted(ids) == list(range(1, attempted+1)))
    if not ledger:
        errors.append("keeper_CB_accounting_not_closed")
    if keeper.get("recordsDropped") != 0 or keeper.get("overflow") is not False or keeper.get("unknownTimingCount") != 0:
        errors.append("keeper_overflow_or_unknown_timing")
    if keeper.get("firstFailure") or calibration.get("firstFailure"):
        errors.append("keeper_first_failure")
    invalid = [r for r in rows if not r["valid"]]
    if invalid:
        errors.append("invalid_keeper_CB")
    width = native_analysis.integer(config.get("threadExecutionWidth"))
    geometry = (width is not None and width > 0 and config.get("threadgroups") == [1,1,1]
                and config.get("threadsPerThreadgroup") == [width,1,1] and config.get("scratchBytes") == width*4
                and config.get("maximumQueuedCommandBuffers") == 2 and config.get("storageMode") == "private"
                and config.get("hazardTrackingMode") == "tracked" and config.get("deviceRegistryID") == raw.get("deviceRegistryID")
                and raw.get("deviceRegistryID") is not None)
    if not geometry:
        errors.append("single_SIMD_group_same_device_configuration_not_verified")
    pilot = [r for r in calibration_rows if r["phase"] == "calibration_pilot"]
    validation = [r for r in calibration_rows if r["phase"] == "calibration_validation"]
    pilot_ms = native_analysis.quantile([r["gpuDurationMs"] for r in pilot], '.5') if len(pilot)==5 and all(r["valid"] for r in pilot) else None
    validation_ms = native_analysis.quantile([r["gpuDurationMs"] for r in validation], '.5') if len(validation)==5 and all(r["valid"] for r in validation) else None
    expected_iterations = None
    if pilot_ms is not None and pilot_ms > 0:
        quotient = 65536.0/float(pilot_ms)
        if math.isfinite(quotient):
            integer_part = math.floor(quotient)
            expected_iterations = integer_part + int(quotient-integer_part >= .5)
    scaled = calibration.get("scaledIterations")
    calibration_valid = (len(calibration_rows)==10 and calibration.get("initialPilotIterations")==65536
        and calibration.get("targetMilliseconds")==1 and calibration.get("pilotCount")==5 and calibration.get("validationCount")==5
        and calibration.get("minimumValidationMs")==D('.5') and calibration.get("maximumValidationMs")==2
        and expected_iterations is not None and 1 <= expected_iterations <= 2**32-1 and scaled==expected_iterations
        and all(r["iterations"]==65536 for r in pilot) and all(r["iterations"]==scaled for r in validation)
        and validation_ms is not None and D('.5')<=validation_ms<=2 and calibration.get("passed") is True)
    if not calibration_valid:
        errors.append("five_pilot_one_conversion_five_validation_not_verified")
    if any(r["iterations"] != scaled or r["phase"] not in ("baseline", "measurement") for r in operational):
        errors.append("operational_iterations_or_phase_changed")
    if lifecycle.get("pendingAtEnd") != 0 or native_analysis.integer(lifecycle.get("maximumPendingObserved")) is None or not 0 <= lifecycle["maximumPendingObserved"] <= 2:
        errors.append("keeper_inflight_or_drain_not_closed")
    baseline = raw.get("phases", {}).get("baseline", {})
    formal = raw.get("phases", {}).get("measurement", {})
    first, stop = (native_analysis.integer(lifecycle.get(k)) for k in ("firstOperationalCommitBeginNs", "stopRequestedNs"))
    coverage_of_phase = (first is not None and stop is not None and baseline.get("startNs") is not None
                         and formal.get("endNs") is not None and first <= baseline["startNs"] and stop >= formal["endNs"])
    if raw.get("functionalComplete") is True and not coverage_of_phase:
        errors.append("keeper_lifecycle_does_not_span_real_phases")
    profiles = {phase: distribution(r["gpuDurationMs"] for r in rows if r["phase"]==phase and r["valid"])
                for phase in ("calibration_pilot", "calibration_validation", "baseline", "measurement")}
    return {"valid": not errors, "errors": errors, "configuration": config, "geometryVerified": geometry,
            "calibration": {"verified": calibration_valid, "pilotMedianMs": pilot_ms, "validationMedianMs": validation_ms,
                            "expectedScaledIterations": expected_iterations, "recorded": {k:v for k,v in calibration.items() if k!='records'}},
            "CBcountsByPhase": dict(Counter(r["phase"] for r in rows)), "CBledgerClosed": ledger,
            "recordsAttempted": attempted, "invalidCBcount": len(invalid), "firstInvalidCBs": invalid[:20],
            "durationMsByCommitPhase": profiles, "fixedOperationalIterations": scaled,
            "lifecycle": lifecycle, "lifecycleSpansRealPhases": coverage_of_phase, "phaseMarks": keeper.get("phaseMarks", []),
            "firstFailure": keeper.get("firstFailure"),
            "scope": "Completed command-buffer GPU residency durations, not active cycles or direct MHz. Phase is the recorded commit-phase label; boundary CBs can finish later. Fixed-iteration durations are a descriptive frequency proxy and add no performance gate."}


def phase_observation(native, name, mapped, segments):
    phase = native[name]
    view = {"measurement": {"bounds": phase["bounds"], "one_second_bins": phase["one_second_bins"]}}
    bins = observed.align_bins(view, mapped, segments)
    known = [b for b in bins if b["observationStatus"]=="known"]
    eligible = [b for b in known if b["nativeGpuBinStatus"]=="valid"]
    keys = sorted({k for b in eligible for k in b["metricsMedian"]})
    metrics = {k: distribution(b["metricsMedian"][k] for b in eligible if b["metricsMedian"].get(k) is not None) for k in keys}
    fraction = D(len(bins)-len(known))/len(bins) if bins else None
    return {"completeCpuBins": len(bins), "observerKnownBins": len(known), "observerMissingBins": len(bins)-len(known),
            "observerMissingFraction": fraction, "missingAbove10Percent": fraction is None or fraction>D('.1'),
            "comparisonEligibleBins": len(eligible), "comparisonEligibleIndices": [b["index"] for b in eligible],
            "excludedNativeLowSampleBins": [b["index"] for b in bins if b["nativeGpuBinStatus"] in ('lowcount','empty')],
            "metricsOverBinMedians": metrics, "bins": bins,
            "scope": "Observer missing denominator is all complete CPU bins. Frequency/power medians use common native-eligible and observer-known bins; no extra minimum-window gate and no lowcount whole-window veto. Prefix partial tail stays excluded."}


def decide(prerequisite_errors, frequency_pass, costs):
    if prerequisite_errors:
        return "inconclusive", "error_incomplete_observation_interruption_or_unverified_evidence"
    if frequency_pass is False:
        return "fail_frequency", "formal_frequency_below_0_75_of_own_prefix"
    if any(value is False for value in costs.values()):
        return "fail_interference", "at_least_one_real_cost_gate_definitely_failed_other_unknowns_retained"
    if frequency_pass is True and all(value is True for value in costs.values()):
        return "pass", "frequency_and_all_three_real_cost_gates_verified"
    return "inconclusive", "one_or_more_required_gates_remain_unknown"


def analyze(raw, native_receipt, coordinator, manifest, manifest_path, observer_dir):
    native = native_analysis.analyze_arm(raw, native_receipt, "A")
    manifest_result = manifest_review(manifest, manifest_path, raw, coordinator)
    keeper = keeper_review(raw)
    metadata, meta_receipt = native_analysis.read_json(observer_dir/'metadata.json')
    samples, samples_receipt = observed.read_jsonl(observer_dir/'samples.jsonl')
    anchors, anchors_receipt = observed.read_jsonl(observer_dir/'anchors.jsonl')
    segments, clock = observed.clock_segments(anchors)
    mapped = observed.map_samples(samples, segments)
    observer_identity = observed.observer_identity(metadata)
    phases = {name:phase_observation(native,name,mapped,segments) for name in ('baseline','measurement')}
    freq = {k:(v['metricsOverBinMedians'].get('gpu_freq_mhz') or {}).get('p50') for k,v in phases.items()}
    frequency_ratio = freq['measurement']/freq['baseline'] if freq['measurement'] is not None and freq['baseline'] is not None and freq['baseline']>0 else None
    frequency_pass = frequency_ratio>=D('.75') if frequency_ratio is not None else None
    pg = (native['baseline']['GPU_union_ms'] or {}).get('p50')
    fg = (native['measurement']['GPU_union_ms'] or {}).get('p50')
    gpu_ratio = fg/pg if fg is not None and pg is not None and pg>0 else None
    wall_p95 = (native['measurement']['wall_ms'] or {}).get('p95')
    burst = native['primary_spike']
    no_burst = True if burst['classification']=='no_spike_observed' else False if burst['classification']=='spike_observed' else None
    costs = {'noVerifiedFiveBinGPUburst':no_burst, 'pooledGPUmedianRatioAtMost1_3':gpu_ratio<=D('1.3') if gpu_ratio is not None else None,
             'pooledWallP95AtMost30_8ms':wall_p95<=D('30.8') if wall_p95 is not None else None}
    errors = list(manifest_result['errors']) + list(keeper['errors'])
    if not native['protocol_eligible']:errors.extend(native['protocol_ineligible_reasons'])
    if raw.get('diagnosticInvalid') is not False:errors.append('native_diagnosticInvalid_or_missing')
    if raw.get('status')!='complete' or raw.get('functionalComplete') is not True:errors.append('native_interrupted_or_incomplete')
    if native['coverage']['invalid_unique_root_ids'] or native['coverage']['duplicate_job_ids'] or any(not j['GPU_valid'] for j in native['job_series']):errors.append('real_trace_invalid')
    if not observer_identity['verified']:errors.append('observer_identity_not_verified')
    if metadata.get('first_error') or samples_receipt['invalidEnvelopeLines'] or anchors_receipt['invalidEnvelopeLines']:errors.append('observer_error')
    for name,phase in phases.items():
        if phase['missingAbove10Percent']:errors.append(name+'_observer_missing_above10percent_or_no_bins')
    classification, reason = decide(errors,frequency_pass,costs)
    durations = keeper['durationMsByCommitPhase']
    pd=(durations.get('baseline') or {}).get('p50');fd=(durations.get('measurement') or {}).get('p50')
    native.pop('job_series',None)
    return {'format':'odf-air-resident-keepalive-review-v1','classification':classification,'classificationReason':reason,
            'manifest':manifest_result,'native':native,'keeper':keeper,
            'observer':{'metadata':metadata,'identity':observer_identity,'files':{'metadata':meta_receipt,'samples':samples_receipt,'anchors':anchors_receipt},'clockMapping':clock,
                        'sampleStatusCounts':dict(Counter(s['status'] for s in mapped)),'phases':phases},
            'gates':{'frequency':frequency_pass,**costs},'unknownGates':[k for k,v in {'frequency':frequency_pass,**costs}.items() if v is None],
            'frequencyEffect':{'prefixMedianMHz':freq['baseline'],'formalMedianMHz':freq['measurement'],'formalOverPrefix':frequency_ratio,'minimumInclusiveRatio':D('.75')},
            'realCost':{'prefixPooledGPUmedianMs':pg,'formalPooledGPUmedianMs':fg,'pooledGPUmedianRatio':gpu_ratio,'formalPooledWallP95Ms':wall_p95,
                        'burst':burst,'scope':'Old known/unknown burst semantics retained; lowcount breaks the eligible-bin sequence and possible unknown onsets remain unknown, without a separate whole-window minimum-count veto.'},
            'keeperProxyCrossCheck':{'isGate':False,'CBdurationFormalOverPrefix':fd/pd if fd is not None and pd is not None and pd>0 else None,
                                     'inverseMacmonFrequencyRatio':1/frequency_ratio if frequency_ratio is not None and frequency_ratio>0 else None,
                                     'scope':'Descriptive only: fixed ALU iteration count does not eliminate command scheduling/preemption/overlap effects. No proportionality or additional threshold is asserted.'},
            'prerequisiteErrors':errors,'firstNativeFailure':raw.get('firstFailure'),'diagnosticInvalid':raw.get('diagnosticInvalid'),
            'contract':{'mechanismGeometry':[1814,1142],'realModelSHA256':MODEL_SHA,'formalSeconds':180,'prefixSeconds':5,
                        'frequencyWeighting':'Within each native-eligible/observer-known CPU bin median, then equal-bin median; all complete CPU bins remain the observation-missing denominator.',
                        'realCostWeighting':'Pooled real-job GPU medians and wall p95; burst uses consecutive complete eligible CPU bins against pooled prefix GPU p50.',
                        'missingFractionMaximumInclusive':D('.1'),'frequencyMinimumInclusive':D('.75'),'GPUmedianRatioMaximumInclusive':D('1.3'),'wallP95MaximumInclusiveMs':D('30.8'),
                        'errorsTakePrecedence':True,'additionalMinimumWindowGate':None,'automaticTask':None},
            'limits':['Mechanism diagnostic at1814x1142 is not delivery of the user\'s2648x1668 capture scene or App24to48 acceptance.',
                      'Frequency and power are pinned macmon aggregate estimates, not per-PID energy or formal energy acceptance.',
                      'No CPU/GPU epoch subtraction. CB phase uses recorded commit labels; drain time is outside real phase timing.',
                      'fail_interference denotes a known real-cost gate failure; it is not proof of a unique physical cause, and any unknown gates remain explicit.']}


def add_power_reference(report, path):
    if path is None:
        report['powerComparison']={'status':'reference_facts_not_supplied','isGate':False}
        return
    facts, receipt=native_analysis.read_json(path)
    keys=('gpu_power_w','system_power_estimate_w','cpu_gpu_ane_sum_w','gpu_active_ratio','gpu_temp_c')
    rows={name:{k:(row.get('metricBinMedians') or {}).get(k) for k in keys} for name,row in (facts.get('windows') or {}).items()}
    for phase,value in report['observer']['phases'].items():
        rows['new_'+phase]={k:(value['metricsOverBinMedians'].get(k) or {}).get('p50') for k in keys}
    report['powerComparison']={'source':receipt,'isGate':False,'rows':rows,
                              'scope':'Old frozen facts quoted without reanalysis. B is interrupted partial data, not a completed control. Whole-system/component power estimates are descriptive only.'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input',type=Path,required=True)
    parser.add_argument('--manifest',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--environment',type=Path)
    parser.add_argument('--observer',type=Path)
    parser.add_argument('--reference-facts',type=Path)
    args=parser.parse_args()
    raw,receipt=native_analysis.read_json(args.input)
    manifest,mreceipt=native_analysis.read_json(args.manifest)
    coordinator,creceipt=native_analysis.read_json(args.environment or args.input.parent.parent/'coordinator-state.json')
    try:
        if sha(Path(observed.__file__))!=COMMON_SHA:raise ValueError('Frozen common observer analysis SHA changed')
        report=analyze(raw,receipt,coordinator,manifest,args.manifest,args.observer or args.input.parent/'metrics')
        add_power_reference(report,args.reference_facts)
    except (OSError,ValueError,TypeError,KeyError,ArithmeticError) as error:
        report={'format':'odf-air-resident-keepalive-review-v1','classification':'inconclusive','classificationReason':'input_or_schema_error',
                'firstAnalysisFailure':str(error),'nativeStatus':raw.get('status'),'firstNativeFailure':raw.get('firstFailure'),'automaticTask':None}
    report.update(input=receipt,manifestFile=mreceipt,coordinatorFile=creceipt,analyzerSHA256=sha(Path(__file__)),
                  commonAnalyzerSHA256=sha(Path(observed.__file__)),nativeAnalyzerSHA256=sha(Path(native_analysis.__file__)))
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,default=observed.json_default,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'classification':report['classification'],'gates':report.get('gates'),'output':str(args.output)},default=observed.json_default))


if __name__=='__main__':
    main()
