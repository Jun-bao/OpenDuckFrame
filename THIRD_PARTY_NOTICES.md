# Third-party notices

OpenDuckFrame is derived from [Khua Player](https://github.com/nake13/khuaplayer),
whose MIT copyright notice is preserved in [LICENSE](LICENSE) and the bundled
`OpenDuckFrame-MIT.txt` notice.

## Frame generation, models and optional runtimes

| Component | Version / source | License / notice |
|---|---|---|
| RIFE Metal | 0.1.8, `cinemore/rife-metal` | Apache-2.0 |
| Practical-RIFE weights | 4.25 (package resource), 4.26 (app resource) | MIT, hzwer |
| Anime4K shader | 4.0.1, `bloc97/Anime4K` | MIT |
| ArtCNN C4F16 / C4F32 | Original coefficients, `Artoriuz/ArtCNN` at `0837e5326e710f49e2ab0a8d995da0708047442e`; Core ML format conversion | MIT |
| Real-CUGAN weights | Bundled 2× models, bilibili | MIT |
| Real-CUGAN ncnn adapter | `nihui/realcugan-ncnn-vulkan` | MIT |
| ncnn | Pinned by the optional runtime recipe | BSD-3-Clause |
| DistilDRBA | Optional V1 model, `routineLife1/DistilDRBA` | MIT |
| libplacebo | Optional Anime4K runtime | LGPL-2.1-or-later |
| Shaderc, glslang, Vulkan headers, MoltenVK | Optional animation runtimes | Upstream Apache / BSD / MIT notices |
| Little CMS | Optional Anime4K runtime | MIT |

Full license texts, source revisions, conversion details and available checksums
are included in [`Apps/Mac/Resources/Notices`](Apps/Mac/Resources/Notices).
The build definition pins RIFE Metal to 0.1.8. Optional runtime recipes pin their
own source or binary expectations; they are separate from the default media
dependency lock. No third-party code or weights are relicensed by this project's MIT license.

## Media dependencies

OpenDuckFrame builds the following libraries from the versions and source hashes
recorded in [`ThirdParty/deps.lock.json`](ThirdParty/deps.lock.json).

| Component | Version | Selected license |
|---|---:|---|
| FFmpeg | 8.1.2 | LGPL-2.1-or-later |
| dav1d | 1.5.1 | BSD-2-Clause |
| Speex | 1.2.1 | BSD-3-Clause |
| libass | 0.17.5 | ISC |
| libpng | 1.6.58 | PNG Reference Library License 2.0 |
| FreeType | 2.14.3 | FreeType Project License |
| FriBidi | 1.0.16 | LGPL-2.1-or-later |
| libunibreak | 7.0 | zlib-style license |
| Graphite2 | 1.3.15 | MIT option |
| HarfBuzz | 14.3.0 | Old MIT license |
| Sparkle | 2.9.6 | MIT and bundled third-party notices |

The complete notices and license texts shipped with these upstream releases are
in [`ThirdParty/Licenses`](ThirdParty/Licenses) and are copied into the app
bundle. The locked source URLs, checksums, build options, and downstream FFmpeg
patches are part of this repository. The notice set includes dav1d's patent
license, the FreeType BDF/PCF driver notices, and the HarfBuzz Microsoft
Universal Shaping Engine data notice.

This software is based in part on the work of the Independent JPEG Group.
This software is based in part on the work of the FreeType Team
(https://freetype.org).

Sparkle is built only for the optional direct-distribution update lane. The
Mac App Store configuration excludes the framework and all updater settings.

FFmpeg, dav1d, and Speex are currently linked statically into the media framework.
Anyone distributing binaries must independently satisfy the LGPL requirements,
including corresponding-source and relinking obligations where applicable.
The repository's reproducible recipes help with compliance but are not a
substitute for legal review, especially for Mac App Store distribution.
