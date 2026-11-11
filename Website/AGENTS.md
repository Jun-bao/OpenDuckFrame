# Historical static website materials

This directory contains the earlier static page and assets retained by the app repository.
The production website is maintained in the separate [super-individual-ai/framegen-site repository](https://github.com/super-individual-ai/framegen-site).
Read that repository's current instructions and live implementation for production website work.
Changes here do not deploy the production site.

## Local ownership

[index.html](index.html), [main.js](main.js) and [styles.css](styles.css) form the retained static page.
Assets here can still be referenced by app-repository guides and README screenshots.
Check those references before moving or replacing an image.
Preserve screenshot provenance and the distinction between a concept illustration and a measured app result.

## Preview when explicitly relevant

[README.md](README.md) describes this local static page.
For an authorized local preview, run `python3 -m http.server 4178 --bind 127.0.0.1` from Website.
It serves this directory only and has no production release effect.
Confirm current product facts from source before reusing historical website copy.
Public download routes, site deployment and indexing checks belong to the production website task.
The app's packaging and update publication rules are in [Distribution](../Distribution/AGENTS.md).
