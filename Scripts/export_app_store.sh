#!/bin/bash
# Validate and export or upload an existing App Store archive.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: Scripts/export_app_store.sh \
  --archive-path PATH \
  --export-path PATH \
  --destination export|upload \
  --team-id TEAM_ID \
  --bundle-id FINAL_BUNDLE_ID \
  --marketing-version VERSION \
  --build-number BUILD \
  [--allow-provisioning-updates] \
  [--api-key-path PRIVATE_KEY.p8 --api-key-id KEY_ID --api-issuer-id ISSUER_ID]

The destination is mandatory. "export" creates a local App Store package;
"upload" sends the archive to App Store Connect. Supplying all three API
credential options automatically enables provisioning updates for xcodebuild.
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

absolute_existing_path() {
  local requested="$1"
  local candidate
  local parent

  case "$requested" in
    /*) candidate="$requested" ;;
    *) candidate="$ROOT/$requested" ;;
  esac
  parent="$(dirname "$candidate")"
  [ -d "$parent" ] || die "path parent does not exist: $parent"
  parent="$(cd "$parent" && pwd -P)"
  printf '%s/%s\n' "$parent" "$(basename "$candidate")"
}

absolute_output_path() {
  local requested="$1"
  local candidate
  local parent

  case "$requested" in
    /*) candidate="$requested" ;;
    *) candidate="$ROOT/$requested" ;;
  esac
  parent="$(dirname "$candidate")"
  /bin/mkdir -p "$parent"
  parent="$(cd "$parent" && pwd -P)"
  printf '%s/%s\n' "$parent" "$(basename "$candidate")"
}

ARCHIVE_PATH=""
EXPORT_PATH=""
DESTINATION=""
TEAM_ID=""
BUNDLE_ID=""
MARKETING_VERSION=""
BUILD_NUMBER=""
ALLOW_PROVISIONING_UPDATES=0
API_KEY_PATH=""
API_KEY_ID=""
API_ISSUER_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive-path)
      require_argument "$@"
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    --export-path)
      require_argument "$@"
      EXPORT_PATH="$2"
      shift 2
      ;;
    --destination)
      require_argument "$@"
      DESTINATION="$2"
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
    --marketing-version)
      require_argument "$@"
      MARKETING_VERSION="$2"
      shift 2
      ;;
    --build-number)
      require_argument "$@"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --allow-provisioning-updates)
      ALLOW_PROVISIONING_UPDATES=1
      shift
      ;;
    --api-key-path)
      require_argument "$@"
      API_KEY_PATH="$2"
      shift 2
      ;;
    --api-key-id)
      require_argument "$@"
      API_KEY_ID="$2"
      shift 2
      ;;
    --api-issuer-id)
      require_argument "$@"
      API_ISSUER_ID="$2"
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

[ -n "$ARCHIVE_PATH" ] || die "--archive-path is required"
[ -n "$EXPORT_PATH" ] || die "--export-path is required"
[ -n "$DESTINATION" ] || die "--destination must be explicitly set to export or upload"
[ -n "$TEAM_ID" ] || die "--team-id is required"
[ -n "$BUNDLE_ID" ] || die "--bundle-id is required"
[ -n "$MARKETING_VERSION" ] || die "--marketing-version is required"
[ -n "$BUILD_NUMBER" ] || die "--build-number is required"

case "$DESTINATION" in
  export|upload) ;;
  *) die "--destination must be exactly 'export' or 'upload'" ;;
esac
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || \
  die "--team-id must be a 10-character Apple Team ID"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || \
  die "--bundle-id must be a concrete reverse-DNS identifier"
[[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || \
  die "--marketing-version must contain one to three numeric components"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || \
  die "--build-number must be a positive integer"

API_ARGUMENT_COUNT=0
[ -n "$API_KEY_PATH" ] && API_ARGUMENT_COUNT=$((API_ARGUMENT_COUNT + 1))
[ -n "$API_KEY_ID" ] && API_ARGUMENT_COUNT=$((API_ARGUMENT_COUNT + 1))
[ -n "$API_ISSUER_ID" ] && API_ARGUMENT_COUNT=$((API_ARGUMENT_COUNT + 1))
[ "$API_ARGUMENT_COUNT" -eq 0 ] || [ "$API_ARGUMENT_COUNT" -eq 3 ] || \
  die "API authentication requires key path, key ID, and issuer ID together"
if [ "$API_ARGUMENT_COUNT" -eq 3 ]; then
  # xcodebuild only uses authentication-key credentials for provisioning
  # operations when -allowProvisioningUpdates is present.
  ALLOW_PROVISIONING_UPDATES=1
fi

ARCHIVE_PATH="$(absolute_existing_path "$ARCHIVE_PATH")"
EXPORT_PATH="$(absolute_output_path "$EXPORT_PATH")"
[ -d "$ARCHIVE_PATH" ] || die "archive does not exist: $ARCHIVE_PATH"
[ ! -e "$EXPORT_PATH" ] || \
  die "export path already exists; choose a new path: $EXPORT_PATH"

if [ "$API_ARGUMENT_COUNT" -eq 3 ]; then
  API_KEY_PATH="$(absolute_existing_path "$API_KEY_PATH")"
  [ -f "$API_KEY_PATH" ] || die "API private key does not exist: $API_KEY_PATH"
fi

echo "==> Re-validating archive without modifying it"
"$ROOT/Scripts/lib/verify_app_store_archive.sh" \
  --archive-path "$ARCHIVE_PATH" \
  --team-id "$TEAM_ID" \
  --bundle-id "$BUNDLE_ID" \
  --marketing-version "$MARKETING_VERSION" \
  --build-number "$BUILD_NUMBER"

TEMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM
EXPORT_OPTIONS="$TEMP_DIR/ExportOptions.plist"
/usr/bin/plutil -create xml1 "$EXPORT_OPTIONS"
/usr/bin/plutil -insert method -string app-store-connect "$EXPORT_OPTIONS"
/usr/bin/plutil -insert destination -string "$DESTINATION" "$EXPORT_OPTIONS"
/usr/bin/plutil -insert signingStyle -string automatic "$EXPORT_OPTIONS"
/usr/bin/plutil -insert teamID -string "$TEAM_ID" "$EXPORT_OPTIONS"
/usr/bin/plutil -insert manageAppVersionAndBuildNumber -bool NO "$EXPORT_OPTIONS"
/usr/bin/plutil -insert stripSwiftSymbols -bool YES "$EXPORT_OPTIONS"
/usr/bin/plutil -insert uploadSymbols -bool YES "$EXPORT_OPTIONS"
/usr/bin/plutil -lint "$EXPORT_OPTIONS" >/dev/null

XCODEBUILD_ARGS=(
  -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_PATH"
  -exportOptionsPlist "$EXPORT_OPTIONS"
)
if [ "$ALLOW_PROVISIONING_UPDATES" -eq 1 ]; then
  XCODEBUILD_ARGS+=( -allowProvisioningUpdates )
fi
if [ "$API_ARGUMENT_COUNT" -eq 3 ]; then
  XCODEBUILD_ARGS+=(
    -authenticationKeyPath "$API_KEY_PATH"
    -authenticationKeyID "$API_KEY_ID"
    -authenticationKeyIssuerID "$API_ISSUER_ID"
  )
fi

echo "==> Running App Store Connect $DESTINATION"
/usr/bin/xcodebuild "${XCODEBUILD_ARGS[@]}"

if [ "$DESTINATION" = "export" ]; then
  [ -d "$EXPORT_PATH" ] || die "Xcode did not create the export directory"
  EXPORTED_FILE="$(/usr/bin/find "$EXPORT_PATH" -maxdepth 1 -type f -print -quit)"
  [ -n "$EXPORTED_FILE" ] || die "Xcode created no exported package in $EXPORT_PATH"
  echo "==> App Store package exported: $EXPORT_PATH"
else
  echo "==> Archive uploaded to App Store Connect"
fi
