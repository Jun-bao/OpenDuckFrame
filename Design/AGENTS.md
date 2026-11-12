# Icon and brand assets

[AppIcon/README.md](AppIcon/README.md) defines the current static export workflow.
The approved source is under `Branding/OpenDuckFrame-20261103/`.
The current master, export manifest and validation scripts are under AppIcon.
Prior artwork is history and must retain its provenance when preserved.

## Make changes through the source pipeline

Confirm the task's approved artwork before replacing a source or generating variants.
Use [AppIcon/export_static_appicon.py](AppIcon/export_static_appicon.py) for shipping sizes.
Its `--refresh-master` option rebuilds the master from the approved source.
Its `--output Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset` option writes the shipping set.
Keep the manifest, master and shipping export consistent with the reviewed asset.
Use the Pillow version pinned in [AppIcon/requirements.txt](AppIcon/requirements.txt).

## Verification

Run `python3 Design/AppIcon/export_static_appicon.py --check` for export consistency.
Run `python3 Design/AppIcon/check_appicon.py --shipping Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset` for the shipping icon set.
Inspect the actual app/Finder/Dock appearance when the task changes the shipped brand.
Coordinate resource and target changes through [Apps/Mac](../Apps/Mac/AGENTS.md).
Keep naming and attribution aligned with [TRADEMARK.md](../TRADEMARK.md) and [CONTRIBUTING.md](../CONTRIBUTING.md).
