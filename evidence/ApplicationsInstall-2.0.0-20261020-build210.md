# LatticeLens 2.0.0 Build 210 — Local Installation Receipt

**Status:** Installed and locally verified; the candidate remains `PARTIAL_NOT_FINAL`, not a final-release or full-acceptance receipt.

| Item | Value |
| --- | --- |
| Candidate | `release-assets/Release-2.0.0-candidate-20261020-stream-timeout-build210` |
| Validation run | `20261020T073843Z-8ab0cfc1` (`PARTIAL_NOT_FINAL`) |
| Bound host-free validation | `20261020T072634Z-6eab7e5d` |
| Installed bundle | `/Applications/LatticeLens.app` |
| Installed version/build | `2.0.0` / `210` |
| Bundle identifier | `org.latticelens.app` |
| Architectures | `x86_64 arm64` |
| Installed executable SHA-256 | `3b2039f429ba1f459d3b19ca122e0d0f9c21e39837e5fc7b04f11187d21bf5a1` |
| Candidate DMG SHA-256 | `68c512413f2d7676951d9dee59537fc0eaf665be72545776242cd1acaea60acf` |

The candidate checksum list passed. The DMG passed `hdiutil verify`, was mounted read-only, and its app passed deep strict signature verification before copying. The mounted app, project-local staging copy, `/Applications` staging copy, and installed app had the same executable SHA-256. The installed app passed deep strict signature verification. Its signature is ad-hoc (`TeamIdentifier=not set`); Developer ID signing and notarization are not claimed.

The prior `/Applications/LatticeLens.app` Build 209 was moved recoverably to `/Users/zhaodianjun/.Trash/LatticeLens.app.previous-build209-20261020`. Its verified executable SHA-256 was `1bef17af16654682ce9e4401a2617546f9d1745f4d50d4a2b41281f937fdeadf`.

The app was left closed after installation. No live cloud-model request or real user library was opened or modified. XCUITest, interactive user workflow, quit/relaunch, app/data rollback, VoiceOver, three-paper physics review, live INSPIRE coverage, and real-library migration remain `NOT_RUN`; see the bound validation report in the candidate package. Local regression and synthetic fixture results do not establish live provider throughput or successful migration of an existing library.
