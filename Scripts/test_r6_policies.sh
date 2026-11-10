#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$ROOT/.build/r6-development"
mkdir -p "$OUT/module-cache"
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$OUT/module-cache" \
  "$ROOT/Apps/Mac/UI/SingleInstancePolicy.swift" \
  "$ROOT/Apps/Mac/UI/LanguageChangePolicy.swift" \
  "$ROOT/Apps/Mac/UI/PixelDiagnosticsPolicy.swift" \
  "$ROOT/Apps/Mac/UI/Enhancement/LiveFPSOverlay.swift" \
  "$ROOT/Modules/VideoEnhancement/Tests/R6PolicyTests.swift" -o "$OUT/r6-policy-tests"
"$OUT/r6-policy-tests"
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$OUT/module-cache" \
  "$ROOT/Apps/Mac/UI/SingleInstanceLock.swift" \
  "$ROOT/Modules/VideoEnhancement/Tests/SingleInstanceLockTests.swift" -o "$OUT/r6-lock-tests"
python3 - "$OUT" <<'PY'
import os, pathlib, select, subprocess, sys, uuid
out = pathlib.Path(sys.argv[1])
case = out / ('lock-test-' + str(uuid.uuid4()))
case.mkdir(mode=0o700)
lock = str(case / 'instance.lock')
exe = str(out / 'r6-lock-tests')
readfd, writefd = os.pipe()
first = os.fork()
if first == 0:
    os.close(writefd)
    owner = os.read(readfd, 32).decode('ascii')
    os.close(readfd)
    os.execv(exe, [exe, lock, 'check', owner])
os.close(readfd)
holder = None
try:
    holder = subprocess.Popen([exe, lock, 'hold'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    ready, _, _ = select.select([holder.stdout], [], [], 5)
    if not ready or holder.stdout.readline().strip() != f'held {holder.pid}':
        raise AssertionError('newer lock holder did not become ready')
    os.write(writefd, str(holder.pid).encode('ascii'))
    os.close(writefd); writefd = -1
    pid, status = os.waitpid(first, 0); first = 0
    assert pid and os.waitstatus_to_exitcode(status) == 0, 'earlier fork did not see the newer lock holder'
    link = str(case / 'link.lock')
    os.symlink(lock, link)
    subprocess.run([exe, link, 'reject'], check=True)
    loose = case / 'loose.lock'
    loose.touch(mode=0o600)
    loose.chmod(0o666)
    subprocess.run([exe, str(loose), 'reject'], check=True)
    linked = case / 'hard-source.lock'
    linked.touch(mode=0o600)
    os.link(linked, case / 'hard-link.lock')
    subprocess.run([exe, str(linked), 'reject'], check=True)
    holder.stdin.write('x'); holder.stdin.flush()
    assert holder.wait(timeout=5) == 0
    subprocess.run([exe, lock, 'acquire'], check=True)
    print('Real fcntl lock test passed: delayed exec sees actual owner, unsafe paths rejected, release reacquires')
finally:
    if writefd >= 0: os.close(writefd)
    if first:
        os.kill(first, 15); os.waitpid(first, 0)
    if holder and holder.poll() is None:
        holder.terminate(); holder.wait(timeout=5)
PY
xcrun clang++ -std=c++17 -I "$ROOT/Apps/Mac/Capture" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPLivePixelProbeTests.cpp" -o "$OUT/r6-pixel-probe-tests"
"$OUT/r6-pixel-probe-tests"
xcrun clang++ -std=c++17 -fobjc-arc -fblocks -I "$ROOT/Apps/Mac/Capture" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPLivePixelProbeCVTests.mm" -framework Foundation -framework CoreVideo -framework CoreGraphics -o "$OUT/r6-pixel-cv-tests"
"$OUT/r6-pixel-cv-tests"
python3 - "$ROOT/Apps/Mac/UI/AppDelegate.swift" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
action = source.split('@objc func languageAction(', 1)[1].split('\n    }', 1)[0]
assert 'LanguageChangePolicy.change' in action
assert all(word not in action for word in ('NSApp.terminate', 'openApplication', 'createsNewApplicationInstance'))
print('Language action path: persists and notifies; no process launch or termination')
PY
