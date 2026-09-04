# LatticeLens / Reference_manager 1.0 GitHub export

This directory is the public source worktree for this repository.  It contains
only the curated, copyable export; local development state, credentials, and
real application libraries remain outside this directory.

## Contents

- `Sources/`, `Tests/`, `Scripts/`, `Assets*/`, `LatticeLens.xcodeproj/`, and
  `Package.swift`: the buildable source and the core XCTest suite retained for
  2.0 work.
- `DisposableMigrationV7Source/`: the authorized synthetic V7 fixture family,
  not a user research library.
- `evidence/`: final local validation, seal, cleanup, manual-acceptance, and
  sanitized migration receipts.
- `release-assets/Release-1.0.3-local/`: the current local DMG, checksums,
  manifest, and installation/rollback instructions. Prefer attaching this
  directory's DMG to a GitHub Release rather than committing future binary
  builds into normal source history.

## Release boundary

The included 1.0 artifact is a same-Mac, ad-hoc local build.  It is neither
Developer-ID signed nor notarized, and the UI evidence is the selected
two-case scrolling delta gate, not a full 26-case UI regression suite.

The current package manifest is
`release-assets/Release-1.0.3-local/manifest-v1.0.3.json`; its DMG SHA-256 is
recorded in that manifest and in `SHA256SUMS.txt`.  Historical validation and
release directories remain outside this current handoff and must not be used
as provenance for the rebuilt package.

No license has been supplied with this export; choose and add one before
publishing the repository.

## Export sanitization

The five historical files that contained the original machine's absolute
project path have been redacted in this export only, replacing that path with
`$PROJECT_ROOT`.  The source project outside `github/` is unchanged.
