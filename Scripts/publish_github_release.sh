#!/bin/bash
# Publish a notarized Developer ID disk image as a GitHub release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: Scripts/publish_github_release.sh \
  --release-dir PATH \
  --team-id TEAM_ID \
  [--repo OWNER/NAME] \
  [--notes-file PATH] \
  [--draft]

Run after notarize_developer_id_dmg.sh has produced the final
OpenDuckFrame-<version>.dmg. The script verifies that disk image again, then
creates the release v<version> with three assets:

  OpenDuckFrame-<version>.dmg         versioned download
  OpenDuckFrame-<version>.dmg.sha256  its checksum
  OpenDuckFrame.dmg                   same bytes under a fixed name

The website's download button points at
https://github.com/OWNER/NAME/releases/latest/download/OpenDuckFrame.dmg,
which GitHub resolves to the fixed-name asset of the newest published
(non-draft, non-prerelease) release. Requires an authenticated `gh`.
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

RELEASE_DIR=""
TEAM_ID=""
REPO="Jun-bao/OpenDuckFrame"
NOTES_FILE=""
DRAFT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release-dir)
      require_argument "$@"
      RELEASE_DIR="$2"
      shift 2
      ;;
    --team-id)
      require_argument "$@"
      TEAM_ID="$2"
      shift 2
      ;;
    --repo)
      require_argument "$@"
      REPO="$2"
      shift 2
      ;;
    --notes-file)
      require_argument "$@"
      NOTES_FILE="$2"
      shift 2
      ;;
    --draft)
      DRAFT=1
      shift
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

[ -n "$RELEASE_DIR" ] || die "--release-dir is required"
[ -n "$TEAM_ID" ] || die "--team-id is required"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || \
  die "--team-id must be a 10-character Apple Team ID"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
  die "--repo must look like OWNER/NAME"
[ -d "$RELEASE_DIR" ] || die "release directory does not exist: $RELEASE_DIR"
RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd -P)"
if [ -n "$NOTES_FILE" ]; then
  [ -f "$NOTES_FILE" ] || die "notes file does not exist: $NOTES_FILE"
fi
command -v gh >/dev/null || die "GitHub CLI (gh) is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not signed in; run gh auth login"

APP="$RELEASE_DIR/OpenDuckFrame.app"
[ -d "$APP" ] || die "prepared app is missing: $APP"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$APP/Contents/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || \
  die "app has an invalid marketing version: $VERSION"

DMG="$RELEASE_DIR/OpenDuckFrame-$VERSION.dmg"
CHECKSUM="$DMG.sha256"
[ -f "$DMG" ] || \
  die "final disk image is missing; run notarize_developer_id_dmg.sh first: $DMG"
[ -f "$CHECKSUM" ] || die "final checksum is missing: $CHECKSUM"

echo "==> Verifying $(basename "$DMG")"
(cd "$RELEASE_DIR" && shasum -a 256 -c "$(basename "$CHECKSUM")") >/dev/null || \
  die "final disk image does not match its checksum"
xcrun stapler validate -v "$DMG"
"$ROOT/Scripts/lib/verify_developer_id_dmg.sh" \
  --dmg "$DMG" \
  --team-id "$TEAM_ID" \
  --bundle-id "$BUNDLE_ID" \
  --source-app "$APP"
SPCTL_OUTPUT="$(spctl --assess --type open \
  --context context:primary-signature --verbose=4 "$DMG" 2>&1)" || {
    printf '%s\n' "$SPCTL_OUTPUT" >&2
    die "Gatekeeper rejected the final disk image"
  }
grep -Fq 'source=Notarized Developer ID' <<<"$SPCTL_OUTPUT" || \
  die "Gatekeeper did not report Notarized Developer ID"

TAG="v$VERSION"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  die "release $TAG already exists in $REPO; bump the version instead of replacing assets"
fi

STAGE="$(mktemp -d "$RELEASE_DIR/.github-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -p "$DMG" "$STAGE/OpenDuckFrame.dmg"
cmp -s "$DMG" "$STAGE/OpenDuckFrame.dmg" || die "fixed-name copy differs"

if [ -z "$NOTES_FILE" ]; then
  NOTES_FILE="$STAGE/notes.md"
  SHA256="$(awk '{print $1}' "$CHECKSUM")"
  cat >"$NOTES_FILE" <<EOF
OpenDuckFrame $VERSION for macOS 14 or later on Apple silicon.

Download \`OpenDuckFrame.dmg\`, open it and drag OpenDuckFrame to Applications.
The disk image and the app are signed with Developer ID and notarized by Apple.

SHA-256 (\`OpenDuckFrame-$VERSION.dmg\`): \`$SHA256\`
EOF
fi

FLAGS=(--repo "$REPO" --title "OpenDuckFrame $VERSION" --notes-file "$NOTES_FILE")
if [ "$DRAFT" -eq 1 ]; then
  FLAGS+=(--draft)
fi

echo "==> Creating release $TAG in $REPO"
gh release create "$TAG" "${FLAGS[@]}" \
  "$DMG" "$CHECKSUM" "$STAGE/OpenDuckFrame.dmg"

if [ "$DRAFT" -eq 1 ]; then
  echo "Draft created. Publish it on GitHub to make the website download live."
else
  echo "Published. Website download:"
  echo "  https://github.com/$REPO/releases/latest/download/OpenDuckFrame.dmg"
fi
