# OpenDuckFrame for iPhone and iPad — planned

This directory reserves the product boundary for a future iPhone and iPad
app. It currently contains no Xcode target, runnable app, bundle identifier,
signing configuration, or purchase integration. OpenDuckFrame currently supports macOS
only.

The intended direction is one mobile product with interface adaptations for
iPhone and iPad, reusing media and subtitle source where practical. The
existing `Modules` directories are source groupings, not iOS-ready packages.
Display and playback hosting, audio routes, document access, subtitle-task
presentation, and third-party device/simulator builds still require platform
work. Mac behavior must remain supported as those interfaces evolve.

See [the repository layout](../../REPOSITORY_LAYOUT.md) for the current
ownership and build boundaries. No mobile build or release command is
available yet.
