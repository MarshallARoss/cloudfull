# Contributing to Cloudfull

Thank you for your interest in Cloudfull. This document explains how to
build the app, how to run the UI tests, and what to expect from a pull
request.

## Before you start

Cloudfull's name and icon are trademarks. Read [TRADEMARKS.md](TRADEMARKS.md)
before you fork or redistribute. Code contributions are licensed to the
maintainer under [CLA.md](CLA.md), and to everyone under
[GPL-3.0](LICENSE).

## Requirements

- Xcode 26 or later.
- An iOS 26 simulator (or an iOS 26 device, for on-device testing).

## Building the app

1. Open `Cloudfull.xcodeproj` in Xcode.
2. To run on a **simulator**, you can build and run right away.
3. To run on a **device**, change these three settings to your own:
   - The signing team, in the project's Signing & Capabilities tab.
   - The bundle identifier, from `com.cloudfull.app` to your own
     (for example `com.yourname.cloudfull`).
   - The iCloud container, from `iCloud.com.cloudfull.app` to your own,
     in both the entitlements file and the iCloud capability in Xcode.

You do not need to change any of this to build and run on a simulator.

## Running the UI tests

The UI tests need a seeded simulator photo library. Two scripts help with
this:

- `scripts/gate_all.sh` runs the full UI test gate — the same suite used
  before every milestone. Read its header comment for what each round
  covers.
- `scripts/make_seed_clip.sh` regenerates the synthetic video fixtures the
  tests need (the large `.mp4` files under `scripts/fixtures/seed4k/` are
  not checked into this repository — see `scripts/fixtures/seed4k/README.md`).

Four scripts — `scripts/gate_all.sh`, `scripts/purge_albums.sh`,
`scripts/seed_m3.sh`, and `scripts/seed_photos.sh` — currently point at a
specific simulator UDID and a specific bundle identifier. Before running
them, open the script and update the `UDID` (and, if you changed it,
`BUNDLE_ID`) to match your own simulator. Find your simulator's UDID with:

```
xcrun simctl list devices
```

These scripts never erase or reset a simulator. Read a script fully before
running it.

## Pull requests

- Keep pull requests focused on one change.
- Explain the "why," not just the "what," in your description.
- Add or update tests when you change behavior.
- Make sure `scripts/gate_all.sh` passes before you open a pull request that
  touches app behavior.
- Do not include large binary files, secrets, or personal file paths in a
  diff.

### Contributor License Agreement

First-time contributors must accept the Contributor License Agreement
before a pull request can be merged. The CLA Assistant bot posts a comment
on your first pull request with instructions. Read [CLA.md](CLA.md) before
you accept it.
