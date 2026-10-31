# ChuanFlow App Icon

`ChuanFlow-Xiaochuan-FullBleed-Original.png` is the current selected artwork.
It fills the square with a blue background; macOS supplies its own icon shape.
The original is untagged RGB, so its pixels are assumed to be sRGB. The
1024px `KhuaPlayer-StaticMaster-1024.png` is an opaque RGB sRGB master derived
from that artwork. Every AppIcon size is rendered directly from this master,
without transparency, and both the canonical and shipping sets must match.

`ChuanFlow-Xiaochuan-Original.png` is the previous artwork, kept for history.
`KhuaPlayer.icon` is the earlier Icon Composer artwork and is not the source
of the current icon.

```sh
python3 Design/AppIcon/export_static_appicon.py --refresh-master
python3 Design/AppIcon/export_static_appicon.py --output Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset
python3 Design/AppIcon/export_static_appicon.py --check
python3 Design/AppIcon/check_appicon.py --shipping Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset
```
