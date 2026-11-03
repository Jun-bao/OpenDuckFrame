#!/bin/bash
# Compatibility entry point for the Mac product build.
set -euo pipefail
exec "$(dirname "$0")/../Apps/Mac/Scripts/build.sh" "$@"
