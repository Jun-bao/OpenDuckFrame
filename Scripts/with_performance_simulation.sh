#!/bin/bash
# Process-local RIFE service-time simulation. No system-wide resource changes.
set -euo pipefail
if [[ $# -lt 2 || "$1" == "--help" ]]; then
  echo 'Usage: Scripts/with_performance_simulation.sh off|m1pro-16|m1pro-14|custom COMMAND [ARGS...]'
  echo 'Optional: ODF_PERF_MODEL_SLOWDOWN=3.5 ODF_PERF_MODEL_MIN_MS=60'
  echo 'Profiles are exploratory service-time envelopes, not M1 Pro hardware emulation.'
  [[ "${1:-}" == "--help" ]] && exit 0
  exit 2
fi
profile="$1"
shift
case "$profile" in off|m1pro-16|m1pro-14|custom) ;; *) echo "Unknown performance profile: $profile" >&2; exit 2 ;; esac
export ODF_PERF_PROFILE="$profile"
echo "RIFE performance simulation: $profile (process-local, exploratory)" >&2
exec "$@"
