#!/bin/bash
# Fast public source, documentation, resource and metadata checks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ "$#" -eq 0 ] || { echo "usage: $0" >&2; exit 2; }

python3 Scripts/check_repo.py
while IFS= read -r script; do
  /bin/bash -n "$script"
done < <(find Scripts Apps/Mac/Scripts -type f -name '*.sh' | sort)

for json in ThirdParty/deps.lock.json Design/AppIcon/export-manifest.json \
            Apps/Mac/Resources/Assets.xcassets/Contents.json \
            Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json; do
  python3 -m json.tool "$json" >/dev/null
done
python3 Design/AppIcon/check_appicon.py --shipping Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset
python3 Scripts/l10n.py check --full
for plist in Apps/Mac/Info.plist Apps/Mac/OpenDuckFrame.entitlements \
             Apps/Mac/QuickLook/Info.plist Apps/Mac/QuickLook/OpenDuckFrameQuickLook.entitlements \
             Apps/Mac/Resources/PrivacyInfo.xcprivacy; do
  plutil -lint "$plist" >/dev/null
done
echo "Public repository checks passed."
