# LatticeLens / Reference_manager 1.0 GitHub export

This directory is a clean, copyable source export.  It deliberately contains
no `.git` repository metadata; initialize and choose the remote yourself.

## Contents

- `Sources/`, `Tests/`, `Scripts/`, `Assets*/`, `LatticeLens.xcodeproj/`, and
  `Package.swift`: the buildable source and the core XCTest suite retained for
  2.0 work.
- `DisposableMigrationV7Source/`: the authorized synthetic V7 fixture family,
  not a user research library.
- `evidence/`: final local validation, seal, cleanup, manual-acceptance, and
  sanitized migration receipts.
- `release-assets/Release-1.0.0-local/`: the current local DMG, matching dSYM,
  checksums, manifest, and installation/rollback instructions.  Prefer
  attaching this directory's DMG and dSYM ZIP to a GitHub Release rather than
  committing future binary builds into normal source history.

## Release boundary

The included 1.0 artifact is a same-Mac, ad-hoc local build.  It is neither
Developer-ID signed nor notarized, and the UI evidence is the selected
two-case scrolling delta gate, not a full 26-case UI regression suite.

The final seal in `evidence/validation-v5-20260828T130035Z-14442.json` binds
the current source tree hash
`17fa101852400699a9a9f3dd1740e1608aaaf0d34e047caa12f71192d50a7df5` to the
release manifest hash
`db7c4f483f1e03aac710fe09b8fe02bbec76c6dac4678beec0dfdce67c315449`.  The
DMG SHA-256 is `a88bccbddfc134c5f826343779ec5196cc2c8ec0ef8cc2b97049f56236f40c06`.

No license has been supplied with this export; choose and add one before
publishing the repository.

## Export sanitization

The five historical files that contained the original machine's absolute
project path have been redacted in this export only, replacing that path with
`$PROJECT_ROOT`.  The source project outside `github/` is unchanged.
