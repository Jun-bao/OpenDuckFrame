#!/usr/bin/env python3
import importlib.util
from pathlib import Path
root = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('p0', root / 'Scripts/analyze_p0_fixture.py')
p0 = importlib.util.module_from_spec(spec); spec.loader.exec_module(p0)

def cap(i, generation=1):
    return {'generation':generation,'receivedSequence':i,'captureHost':i*10000000,'readyHost':i*10000000,'decoded':True,'frameNumber':i}
def out(i, generation=1, config=2, epoch=3):
    common={'frameID':i,'generation':generation,'configVersion':config,'measurementEpoch':epoch}
    return [dict(common,kind='submitted',clockEpoch=4,captureHost=i*10000000,decoded=True,frameNumber=i,synthetic=False),
            dict(common,kind='presented',presentedTime=i/100,counts=True,windowVisible=True,exposed=True,occluded=False)]
def status(t, generation=1, config=2, epoch=3):
    return {'monotonicSeconds':t,'realWindowCapture':True,'capturePaused':False,'targetOnscreen':True,
            'outputTargetReady':True,'outputPanelVisible':True,'outputPanelAlpha':1,'targetWindowID':101,'targetOwnerPID':77,
            'frontProcessActualPID':77,'r8ProcessID':88,'targetFrontmostMatch':True,'outputPanelIsKey':False,
            'capture':{'running':True,'paused':False,'generation':generation,'r8Fixture':{'events':[]}},
            'processor':{'sourceGeneration':generation,'configVersion':config,'measurementEpoch':epoch,'clockEpoch':4,'r8OutputTimeline':[]}}
def rows(samples, cap_end=100, present_end=10):
    values=[s.copy() for s in samples]
    if values:
        last=values[-1]; last['capture']=dict(last['capture'],r8Fixture={'events':[cap(i) for i in range(1,cap_end+1)]})
        last['processor']=dict(last['processor'],r8OutputTimeline=sum([out(i) for i in range(1,present_end+1)],[]))
    return values

def calc(samples, source=None):
    source = source if source is not None else [f'sourceDraw monotonic={i/100:.2f} encodedSequence={i} drawCount={i}\n' for i in range(1,101)]
    return p0.analyze(source, rows(samples), .01, 1, 1e-9)
def dense(): return [status(i/20) for i in range(1,21)]

value=calc(dense())
assert value['firstDepartureStatus']=='sampled_suspected' and value['firstDeparture']['kind']=='visible_present_content_not_advancing', value
assert value['firstDeparture']['classification']=='sampled_suspected' and value['firstDepartureEligible']
draws=[f'sourceDraw monotonic={i/100:.2f} encodedSequence={i} drawCount={i}\n' for i in range(1,101)]
v=p0.analyze(draws,rows(dense(),cap_end=10),.01,1,1e-9)
assert v['firstDeparture']['kind']=='capture_content_not_advancing' and v['firstDepartureStatus']=='sampled_suspected', v
# The last positive present is followed by expected hiding while source/capture advance.
hidden=dense()
for r in hidden:
    if r['monotonicSeconds']>=.15: r.update(outputPanelVisible=False, outputTargetReady=False, frontProcessActualPID=99)
v=calc(hidden); assert v['firstDeparture'] is None and v['firstDepartureStatus']=='unknown' and not v['firstDepartureEligible'], v
# A later visible interval without a new baseline present cannot inherit the previous segment.
resumed=dense()
for r in resumed:
    if .15 <= r['monotonicSeconds'] < .55: r.update(outputPanelVisible=False,outputTargetReady=False)
v=calc(resumed); assert v['firstDeparture'] is None and v['firstDepartureStatus']=='unknown', v
# A config or epoch switch after the last present must not reuse that old present.
for field in ('configVersion','measurementEpoch','clockEpoch'):
    changed=dense()
    for r in changed:
        if r['monotonicSeconds']>=.15: r['processor'][field]+=1
    v=calc(changed); assert v['firstDeparture'] is None and v['firstDepartureStatus']=='unknown', (field,v)
# New capture generation also cannot inherit prior evidence.
changed=dense()
for r in changed:
    if r['monotonicSeconds']>=.15: r['capture']['generation']=2; r['processor']['sourceGeneration']=2
v=calc(changed); assert v['firstDeparture'] is None and v['firstDepartureStatus']=='unknown', v
# Missing fields, pause, warmup, other-app focus or a sampling hole break the baseline.
for mutation in ('missing','missing_clock','pause','warmup','focus','gap','stale'):
    samples=dense()
    if mutation=='gap': samples=[r for r in samples if not (.15<=r['monotonicSeconds']<.55)]
    else:
        for r in samples:
            if .15<=r['monotonicSeconds']<.55:
                if mutation=='missing': r.pop('outputTargetReady')
                if mutation=='missing_clock': r['processor'].pop('clockEpoch')
                if mutation=='pause': r['capturePaused']=True
                if mutation=='warmup': r['outputPanelAlpha']=.001
                if mutation=='focus': r['frontProcessActualPID']=99
                if mutation=='stale': r['processor']['snapshotStale']=True
    v=calc(samples); assert v['firstDeparture'] is None and v['firstDepartureStatus']=='unknown', (mutation,v)
# Sparse 1-second logs cannot prove 200ms of sampled expected visibility.
v=calc([status(.05),status(1.0)]); assert v['firstDeparture'] is None and not v['firstDepartureEligible'] and v['firstDepartureStatus']=='unknown', v
# An undecodable capture/output is unknown evidence, never a frozen identity.
samples=rows(dense()); samples[-1]['capture']['r8Fixture']['events'][14]['decoded']=False
samples[-1]['capture']['r8Fixture']['events'][14]['frameNumber']=-1
unknown_output=out(15); unknown_output[0]['decoded']=False
samples[-1]['processor']['r8OutputTimeline'] += unknown_output
v=p0.analyze([f'sourceDraw monotonic={i/100:.2f} encodedSequence={i} drawCount={i}\n' for i in range(1,101)],samples,.01,1,1e-9)
assert v['firstDeparture'] is None and v['firstDepartureStatus']=='unknown', v
# Missing nested dictionaries and incomplete capture metadata are safe unknowns.
v=p0.analyze([], [None, {'monotonicSeconds':.05,'capture':None,'processor':None}], .01,1,1e-9)
assert v['firstDepartureStatus']=='unknown' and v['firstDeparture'] is None, v
samples=rows(dense()); samples.insert(4,{'capture':{},'processor':{}})
v=p0.analyze(draws,samples,.01,1,1e-9); assert v['unlocatableStatusRows']==1 and v['firstDepartureStatus']=='unknown', v
samples=rows(dense()); samples[2]['capture']=dict(samples[2]['capture'],r8Fixture={'events':[{'generation':1, 'decoded':True}]})
v=p0.analyze(draws,samples,.01,1,1e-9); assert v['firstDepartureStatus']=='unknown' and v['firstDeparture'] is None, v
static=[f'sourceDraw monotonic={i/100:.2f} encodedSequence=1 drawCount={i}\n' for i in range(1,101)]
v=calc(dense(),static); assert v['firstDeparture'] is None and v['firstDepartureStatus']=='unknown', v
# Output-focus case uses actual own PID and actual key status, without requested flags.
focused=dense()
for r in focused: r['frontProcessActualPID']=88; r['outputPanelIsKey']=True
v=calc(focused); assert v['firstDepartureStatus']=='sampled_suspected', v
for r in focused: r['outputPanelIsKey']=False
v=calc(focused); assert v['firstDepartureStatus']=='unknown', v
assert p0.analyze([],[],.01,1,1e-9)['captureToPresent']['p95Ms'] is None
print('fixture-analysis-v2: sampled stall, hidden, resume, config/epoch/generation, missing, pause, warmup, focus, gap, static and output focus pass')
