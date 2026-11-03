#!/bin/bash
# Verify that every executable object in a direct-distribution app carries the
# expected Developer ID signature, hardened runtime, and secure timestamp.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Scripts/lib/verify_developer_id_app.sh \
  --app PATH \
  --team-id TEAM_ID \
  [--bundle-id BUNDLE_ID]
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

require_argument() {
  [ "$#" -ge 2 ] || die "missing value for $1"
  [ -n "$2" ] || die "empty value for $1"
}

APP=""
TEAM_ID=""
BUNDLE_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      require_argument "$@"
      APP="$2"
      shift 2
      ;;
    --team-id)
      require_argument "$@"
      TEAM_ID="$2"
      shift 2
      ;;
    --bundle-id)
      require_argument "$@"
      BUNDLE_ID="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$APP" ] || die "--app is required"
[ -n "$TEAM_ID" ] || die "--team-id is required"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || \
  die "--team-id must be a 10-character Apple Team ID"
[ -d "$APP" ] || die "app does not exist: $APP"
APP="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"

TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

entitlement_value() {
  local code="$1"
  local key="$2"
  local plist="$TMP/entitlements.plist"
  : >"$plist"
  codesign -d --entitlements - --xml "$code" >"$plist" 2>/dev/null || true
  [ -s "$plist" ] || return 1
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
}

verify_code() {
  local code="$1"
  local details

  codesign --verify --strict --verbose=4 "$code" >/dev/null 2>&1 || \
    die "invalid code signature: $code"
  details="$(codesign -dv --verbose=4 "$code" 2>&1)"
  grep -Fq 'Authority=Developer ID Application:' <<<"$details" || \
    die "not signed by Developer ID Application: $code"
  grep -Fq "TeamIdentifier=$TEAM_ID" <<<"$details" || \
    die "signature does not belong to team $TEAM_ID: $code"
  grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' <<<"$details" || \
    die "hardened runtime is not enabled: $code"
  grep -Eq '^Timestamp=' <<<"$details" || \
    die "secure timestamp is missing: $code"
  if [ "$(entitlement_value "$code" \
        com.apple.security.get-task-allow || true)" = "true" ]; then
    die "get-task-allow must not be enabled: $code"
  fi
  for key in \
    com.apple.security.cs.disable-library-validation \
    com.apple.security.cs.allow-jit \
    com.apple.security.cs.allow-unsigned-executable-memory; do
    if [ "$(entitlement_value "$code" "$key" || true)" = "true" ]; then
      die "forbidden release entitlement $key: $code"
    fi
  done
}

EXPECTED_PATHS=(
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
  "$APP/Contents/Frameworks/Sparkle.framework"
  "$APP/Contents/Frameworks/libass.9.dylib"
  "$APP/Contents/Frameworks/OpenDuckFrameMediaCore.framework"
  "$APP/Contents/Frameworks/OpenDuckFrameCaptionsUI.framework"
  "$APP/Contents/PlugIns/OpenDuckFrameQuickLook.appex"
  "$APP"
)
for code in "${EXPECTED_PATHS[@]}"; do
  [ -e "$code" ] || die "required signed code is missing: $code"
  verify_code "$code"
done

# Refuse an unexpected unsigned/ad-hoc executable if the bundle grows later.
MACHO_COUNT=0
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q 'Mach-O'; then
    MACHO_COUNT=$((MACHO_COUNT + 1))
    verify_code "$candidate"
  fi
done < <(find "$APP/Contents" -type f -print0)
[ "$MACHO_COUNT" -gt 0 ] || die "app contains no Mach-O executables"

MAIN_SANDBOX="$(entitlement_value "$APP" \
  com.apple.security.app-sandbox || true)"
[ "$MAIN_SANDBOX" != "true" ] || \
  die "Developer ID host app must remain outside the App Sandbox"

APPEX="$APP/Contents/PlugIns/OpenDuckFrameQuickLook.appex"
[ "$(entitlement_value "$APPEX" \
      com.apple.security.app-sandbox || true)" = "true" ] || \
  die "Quick Look extension must retain App Sandbox"
[ "$(entitlement_value "$APPEX" \
      com.apple.security.files.user-selected.read-only || true)" = "true" ] || \
  die "Quick Look extension must retain read-only file access"
[ "$(entitlement_value "$APPEX" \
      com.apple.security.files.user-selected.read-write || true)" != "true" ] || \
  die "Quick Look extension must not gain write access"

if [ -n "$BUNDLE_ID" ]; then
  MAIN_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$APP/Contents/Info.plist")"
  APPEX_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$APPEX/Contents/Info.plist")"
  MEDIA_ID="$(codesign -dv --verbose=4 \
    "$APP/Contents/Frameworks/OpenDuckFrameMediaCore.framework" 2>&1 |
    sed -n 's/^Identifier=//p')"
  CAPTIONS_ID="$(codesign -dv --verbose=4 \
    "$APP/Contents/Frameworks/OpenDuckFrameCaptionsUI.framework" 2>&1 |
    sed -n 's/^Identifier=//p')"
  [ "$MAIN_ID" = "$BUNDLE_ID" ] || \
    die "main bundle identifier mismatch: $MAIN_ID"
  [ "$APPEX_ID" = "$BUNDLE_ID.QuickLook" ] || \
    die "Quick Look bundle identifier mismatch: $APPEX_ID"
  [ "$MEDIA_ID" = "$BUNDLE_ID.MediaCore" ] || \
    die "media framework identifier mismatch: $MEDIA_ID"
  [ "$CAPTIONS_ID" = "$BUNDLE_ID.CaptionsUI" ] || \
    die "caption UI framework identifier mismatch: $CAPTIONS_ID"
fi

codesign --verify --deep --strict --verbose=4 "$APP" >/dev/null 2>&1 || \
  die "deep signature verification failed: $APP"

echo "==> Developer ID verification passed: $APP"
