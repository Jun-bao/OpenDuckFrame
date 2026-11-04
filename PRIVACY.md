# Privacy policy

Effective date: November 4, 2026

OpenDuckFrame does not use advertising SDKs, accounts, or analytics. It does not
automatically transmit the windows or displays you capture, the media you open, playback
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

## Optional feedback

The Feedback link opens `https://openduckframe.cn/feedback/` in your browser.
When opened from the workbench, the form receives the app and macOS versions
locally through a URL fragment, which is not sent in the page request, and
displays the versions that will be included. Only pressing **Send feedback** submits your message,
optional contact email, the screenshot you explicitly attach, and those versions.
These are stored in the developer's private Feishu table for troubleshooting,
product improvements and necessary replies. They are not published to GitHub.
The form never takes a screenshot automatically or reads media files, browsing
content or application logs. Hide sensitive information before attaching an image.
The website and its network providers receive normal connection information;
the feedback service briefly uses the source address in memory to limit frequent
submissions and does not add it to the feedback table.

## Changes

If a future version adds purchases, network playback, crash reporting, update
statistics, or any other data processing, this policy must be updated before
that version is distributed.
