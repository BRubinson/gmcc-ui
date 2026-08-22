---
name: vendor-daemonkit
description: Refresh the vendored GMCCDaemonKit sources in Vendor/GMCCDaemonKit by hard-copying them from the gmcc-marketplace repo. Use when the daemon kit changed upstream, the vendored copy is stale, or GMVibes fails to build against GMCCDaemonKit types.
---

# Vendor GMCCDaemonKit

GMVibes links `GMCCDaemonKit` from a **vendored hard copy** at
`Vendor/GMCCDaemonKit/` — a local Swift package committed to this repo. It is
deliberately NOT a cross-repo relative-path reference into a sibling
`gmcc-marketplace` checkout; never re-point the Xcode project at
`../gmcc-marketplace/plugins/gmcc/daemon`.

## Refresh procedure

1. Run the sync script:

   ```bash
   scripts/vendor-daemonkit.sh [branch]
   ```

   - `branch` defaults to `main`.
   - The script shallow-clones the marketplace's git remote
     (`https://github.com/BRubinson/gmcc-marketplace.git`) into a temp dir —
     it never reads a local checkout, so it works on any machine with git.
     Override the source with `GMCC_MARKETPLACE_REPO=<git URL or local path>`
     (forks, or testing local protocol work before pushing).
   - Only **committed** history is copied — uncommitted upstream edits are
     never picked up, even with a local-path override. If the user wants
     work-in-progress changes, tell them to commit in gmcc-marketplace first
     (and push, unless using a local-path override).

2. The script replaces `Vendor/GMCCDaemonKit/Sources/GMCCDaemonKit/`, rewrites
   the library-only `Package.swift` (do not hand-edit it — it intentionally
   omits the upstream `gm`/`gmcc_daemon` executables and their ArgumentParser
   dependency), and stamps `VENDORED.md` with the source branch + commit.

3. Verify the app still builds:

   ```bash
   xcodebuild build -project GMVibes.xcodeproj -scheme GMVibes -destination 'platform=macOS' -quiet
   ```

   If the build breaks on new/renamed GMCCDaemonKit API, fix the GMVibes call
   sites (Vendor/ sources are upstream-owned; never patch them here).

4. Review `git status` — the refreshed `Vendor/GMCCDaemonKit/` diff should be
   committed to this repo alongside any call-site fixes.

## Notes

- `Vendor/GMCCDaemonKit/VENDORED.md` records which marketplace branch/commit
  the current copy came from — check it before re-vendoring to explain drift.
- Xcode caches package state; if Xcode shows stale errors after a refresh,
  quit Xcode, delete `~/Library/Developer/Xcode/DerivedData/GMVibes-*`, and
  reopen.
