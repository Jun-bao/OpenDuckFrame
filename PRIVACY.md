# Privacy policy

Effective date: November 3, 2026

OpenDuckFrame does not use advertising SDKs, accounts, or analytics. It does not
transmit the windows or displays you capture, the media you open, playback
history, subtitles, or language preferences to any server.

## Screen capture

OpenDuckFrame captures only the window or display you select, after macOS asks
for Screen Recording permission. Captured frames are processed in memory on this
Mac to generate in-between frames or upscale the picture, then shown in the
output window. Frames are not saved to disk or uploaded. Diagnostic logs written
on this Mac record timing, sizes and the selected window title, not picture
content, and stay on this Mac.

## Media files and playback

Media files are opened only after an explicit user action, such as selecting a
file, dropping a file onto the app, or opening it from Finder. Playback resume
positions and language preference are stored locally in macOS user defaults.
Screenshots are written only to a location explicitly selected in the system
Save panel. The **Clear All History** command removes playback positions and
recent-file history managed by the app and the system.

## Subtitles

On supported macOS versions, subtitle generation and translation use Apple's
on-device speech and translation services. OpenDuckFrame does not upload the
selected media or subtitle text. macOS may download required language models
through its system services; those downloads follow Apple's prompts and system
settings. No microphone recording is used.

## Software updates

Community downloads check the signed version feed at
`https://jun-bao.github.io/OpenDuckFrame/appcast.xml` and download updates from
`https://github.com/Jun-bao/OpenDuckFrame/releases`. These requests expose normal
connection information such as IP address and an updater User-Agent to GitHub.
System profiling and installation statistics are disabled; no media, screen
content, subtitles, playback history or persistent installation identifier is sent.

Automatic checking can be disabled in **OpenDuckFrame → Automatically Check for
Updates**. **Check for Updates** remains available for a manual check. Checking
does not force installation. Custom source builds can disable update networking
by explicitly setting both `ODF_SPARKLE_FEED_URL` and
`ODF_SPARKLE_PUBLIC_ED_KEY` to empty strings at build time. App Store builds do
not include this updater.

## Build-time downloads

The build scripts download checksum-pinned open-source dependencies when a
developer compiles the app. That build-time activity is separate from the
running application.

## Changes

If a future version adds purchases, network playback, crash reporting, update
statistics, or any other data processing, this policy must be updated before
that version is distributed.
