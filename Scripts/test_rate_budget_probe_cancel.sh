#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Compile the production methods verbatim, as in test_r8_diagnostic_contract.sh.
# Only the engine boundary and the unused processor surface are replaced by the
# small harness. Completion, eligibility, cancellation, pin release and held
# reclamation always come from the current SPLiveProcessor.mm, never test copies.
python3 -I - "$ROOT/Apps/Mac/Capture/SPLiveProcessor.mm" "$TEST_DIR" <<'PY'
import hashlib
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
destination = pathlib.Path(sys.argv[2])

def extract(marker, end="\n}"):
    if source.count(marker) != 1:
        raise SystemExit("FAIL probe contract: expected one production entry: " + marker)
    start = source.index(marker)
    # Brace matching also handles one-line helpers. Ignore comments and quoted
    # strings so a diagnostic string cannot change which function is tested.
    pos = source.index("{", start)
    depth = 0
    state = "code"
    while pos < len(source):
        char = source[pos]
        pair = source[pos:pos + 2]
        if state in ('"', "'"):
            if char == "\\":
                pos += 2
                continue
            if char == state:
                state = "code"
        elif state == "line":
            if char == "\n":
                state = "code"
        elif state == "comment":
            if pair == "*/":
                state = "code"
                pos += 2
                continue
        elif pair == "//":
            state = "line"
            pos += 2
            continue
        elif pair == "/*":
            state = "comment"
            pos += 2
            continue
        elif char in ('"', "'"):
            state = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                stop = pos + 1 + (1 if end.endswith(";") else 0)
                break
        pos += 1
    else:
        raise SystemExit("FAIL probe contract: unterminated production entry: " + marker)
    text = source[start:stop]
    print("SOURCE", marker, hashlib.sha256(text.encode()).hexdigest())
    return text

structures = [extract("struct SPLiveHeld {", "\n};"),
              extract("struct SPLiveJob {", "\n};")]
helpers = [extract("static int64_t SPHostNow(void)"),
           extract("static int64_t SPHostToNs(int64_t host)"),
           extract("static BOOL SPR7Passthrough(void)")]
methods = [
    "- (sp::NativeCadenceSnapshot)nativeCadenceSnapshot",
    "- (BOOL)nativeBudgetForSnapshot:",
    "- (BOOL)rateBudgetEnabled",
    "- (void)releaseRateBudgetProbeJob:",
    "- (void)cancelRateBudgetProbe",
    "- (BOOL)rateBudgetProbeEligible",
    "- (void)finishRateBudgetProbe:",
    "- (void)submitNextRateBudgetProbe",
    "- (void)trimHeld",
    "- (NSDictionary<NSString *, id> *)ownedContractRateBudgetProbeCancellation:",
]
production_methods = [extract(marker) for marker in methods]
(destination / "RateBudgetProbeStructures.inc").write_text("\n\n".join(structures + helpers) + "\n")
(destination / "RateBudgetProbeMethods.inc").write_text("\n\n".join(production_methods) + "\n")
PY

xcrun clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra \
  -Wno-incomplete-implementation \
  -I "$ROOT/Apps/Mac/Capture" -I "$ROOT/Modules/VideoEnhancement" -I "$TEST_DIR" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPRateBudgetProbeCancelTests.mm" \
  -framework Foundation -framework AppKit -framework CoreVideo \
  -framework CoreMedia -framework QuartzCore -o "$TEST_DIR/rate-budget-probe-cancel-tests"
"$TEST_DIR/rate-budget-probe-cancel-tests"
