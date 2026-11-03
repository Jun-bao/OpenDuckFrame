# OpenDuckFrame App Icon

The approved `Design/Branding/OpenDuckFrame-20261103/OpenDuckFrame-1024.png` is the full-bleed source. The opaque sRGB master and all shipping sizes are generated with the existing static pipeline. The prior ChuanFlow artwork and Icon Composer files remain for history.

```sh
python3 Design/AppIcon/export_static_appicon.py --refresh-master
python3 Design/AppIcon/export_static_appicon.py --output Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset
python3 Design/AppIcon/export_static_appicon.py --check
python3 Design/AppIcon/check_appicon.py --shipping Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset
```
