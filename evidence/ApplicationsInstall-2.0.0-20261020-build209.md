# LatticeLens 2.0.0 Build 209 — Local Installation Receipt

**Installation status:** PASS — local candidate installed and verified.

**Release/acceptance status:** `PARTIAL_NOT_FINAL`; this is not a final-release receipt.

Candidate: `release-assets/Release-2.0.0-candidate-20261020-llm-hard-deadline-build209/`

Bound pre-package validation: `20261020T032132Z-8dd564aa` (`host_free_only`, 291 passed, 0 failed, 7 skipped).

Package manifest run: `20261020T032640Z-70615502` (`PARTIAL_NOT_FINAL`)

Installed bundle: `/Applications/LatticeLens.app`

Installed version/build: `2.0.0` / `209`

Bundle identifier: `org.latticelens.app`

Architectures: `x86_64 arm64`

Installed executable SHA-256: `1bef17af16654682ce9e4401a2617546f9d1745f4d50d4a2b41281f937fdeadf`

Candidate DMG SHA-256: `a17a22d4cfb6310a021d5b8de63ee174bcaa06c87365ef16919145f785e8a1b9`

The DMG checksum list and `hdiutil verify` passed. The DMG was mounted read-only; the mounted app and isolated staged app passed deep strict signature verification and matched the candidate executable hash. A synthetic fixture launch smoke passed with network, the real user's Library, Keychain service, and system temporary paths denied. The installed app passed deep strict signature verification and has the candidate executable hash. The app remains closed.

Build 209 addresses the reported cloud-model failure after about ten minutes by making the per-request hard deadline profile-configurable, with a 30-minute default for existing and new settings and choices of 10, 15, 20, 30, or 60 minutes. Deadline measurement uses a monotonic clock and preserves the separate connect, first-content, idle, and cancellation limits. This timing is consistent with the prior ten-minute client deadline, but no live provider request was run; a provider-side limit is not ruled out.

The previous Build 208 bundle was moved recoverably to `/Users/zhaodianjun/.Trash/LatticeLens.app.previous-build208-20261020T033000Z` before installation; its preserved executable SHA-256 is `bb7ddfd4ba4212b1233db398c8ba813ab7c7b2b02bd3d2e7abe601204e16fc85`. Developer ID signing and notarization are not present or claimed; this is an ad-hoc local candidate.

The bound validation report records 291 passed, 0 failed, and 7 skipped Swift tests, a passing warnings-as-errors Release build, 10/10 static checks, passing synthetic V10-to-V12 migration drill, and passing V12 disk benchmark. It also explicitly leaves Xcode/XCUITest, VoiceOver, three-paper human physics review, real user-library migration/workflow, and live INSPIRE/provider checks `NOT_RUN`. The package manifest marks DMG/hash/mount/signature and fixture launch checks `PASS`, while full user workflow, app/data rollback, and UI acceptance remain `NOT_RUN`. No real library was opened or modified.
