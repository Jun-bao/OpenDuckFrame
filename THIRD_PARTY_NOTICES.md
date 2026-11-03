# Third-party notices

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
