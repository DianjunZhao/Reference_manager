# LatticeLens 1.0.0 — same-Mac local artifact

This DMG is ad-hoc signed for local inspection.  It is not Developer ID signed,
not notarized, and it must not be presented as a public macOS release.

## Install without overwriting an existing app

1. Verify `manifest-v1.0.json` and `SHA256SUMS.txt` before mounting the DMG.
2. If `/Applications/LatticeLens.app` already exists, choose one action before
   dragging the new app: retain and rename the old app, cancel, or replace it
   only after you have verified a backup.  Never silently overwrite it.
3. Start the installed app with network disabled for the local acceptance flow:
   browse cached authors, search, note, PDF, Compare, Notebook and Bundle;
   quit and relaunch to confirm durable state.

## Data rollback and uninstall

- If no V8 migration occurred, quit 1.0, remove only the new app and relaunch
  the retained app.  Do not delete Application Support, PDFs, Keychain or a
  library as part of an app rollback.
- If a V7→V8 migration occurred, verify the pre-migration backup manifest and
  hashes first. Restore it only to a new explicit target, verify record/link
  counts, then choose the active library. Do not point an old app at a V8 store.
- Default uninstall removes only `/Applications/LatticeLens.app`; it retains
  libraries, PDFs and Keychain. A full data purge is a separate human action
  after a verified Research Bundle export.
