#!/bin/bash
# Validate only: no GPU, models, event posting or app launch.
set -euo pipefail
probe="${1:?absolute path to compiled probe}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Test.app/Contents"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.p2.parameters</string></dict></plist>' > "$tmp/Test.app/Contents/Info.plist"
python3 - "$probe" "$tmp/Test.app" "$tmp/out" <<'PY'
import json, subprocess, sys
probe, app, out=sys.argv[1:]
def run(engine,quality,extra):
 env={'PATH':'/usr/bin:/bin','CHUANFLOW_PROBE_VALIDATE_ONLY':'1',**extra}
 return subprocess.run([probe,'-',app,engine,quality,'natural','unpaced',out],env=env,capture_output=True,text=True)
for engine,quality in [('frc','normal'),('frc','quality'),('rife','fast'),('rife','balanced'),('lowlatency','normal')]:
 for w,h in [(1280,720),(2560,1410)]:
  r=run(engine,quality,{'CHUANFLOW_PROBE_WIDTH':str(w),'CHUANFLOW_PROBE_HEIGHT':str(h),'CHUANFLOW_PROBE_WARMUP_SEC':'10','CHUANFLOW_PROBE_MEASURE_SEC':'30'})
  assert r.returncode==0, (engine,quality,r.stdout,r.stderr)
  d=json.loads(r.stdout); assert d['validParameters'] and (d['width'],d['height'])==(w,h)
  assert d['warmupCap']==2400 and d['measureCap']==7200 and d['capContract'] and d['clockContract'] and d['clockElapsedMS'] >= 1 and not d['rifeCacheRequest']
r=run('rife','fast',{'CHUANFLOW_PROBE_RIFE_REQUEST':'1'}); assert r.returncode==0 and json.loads(r.stdout)['rifeCacheRequest']
for engine,quality,opts in [('rife','fast',{'CHUANFLOW_PROBE_RIFE_REQUEST':'invalid'}),('frc','normal',{'CHUANFLOW_PROBE_WIDTH':'1279'}),('frc','normal',{'CHUANFLOW_PROBE_WARMUP_SEC':'0','CHUANFLOW_PROBE_MEASURE_SEC':'30'}),('lowlatency','normal',{'CHUANFLOW_PROBE_MULTIPLIER':'3'}),('frc','quality',{'CHUANFLOW_FRC_MODE':'sequential1','CHUANFLOW_FRC_CONTINUOUS':'0'}),('frc','quality',{'CHUANFLOW_FRC_MODE':'sequential1','CHUANFLOW_FRC_CONTINUOUS':'1','CHUANFLOW_PROBE_WARMUP_SEC':'10','CHUANFLOW_PROBE_MEASURE_SEC':'30'}),('frc','quality',{'CHUANFLOW_FRC_MODE':'sequential1','CHUANFLOW_FRC_CONTINUOUS':'1','CHUANFLOW_PROBE_MEASURED':'31'})]:
 r=run(engine,quality,opts); assert r.returncode!=0,(engine,quality,opts,r.stdout)
print('P2 validate-only parameters pass; no GPU/model or event operations')
PY
