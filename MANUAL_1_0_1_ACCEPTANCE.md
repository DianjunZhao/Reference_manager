# LatticeLens 1.0.1 (101) — final manual acceptance

Status: **NOT_RUN**. This is a short, fail-closed worksheet for the current
`LatticeLens-1.0.1-local.dmg` candidate. It is not a receipt and cannot be
used by the seal verifier as one.

Use only `/Applications/LatticeLens.app` whose Finder information says
**Version 1.0.1 (101)**. Do not inspect, migrate, export, delete, or otherwise
open a real Application Support library, a research-PDF library, or Keychain.

## Required observations

Mark all four as `PASS` only after observing them on this 1.0.1 binary.

1. **Accessibility and layout.** With VoiceOver or Accessibility Inspector,
   verify primary label/value/action exposure and non-color-only status in the
   author list, Paper Lens (including readable mathematical text), Evidence
   Workbench, toolbar status capsule, settings, and long scroll regions. Check
   the three window sizes **820×640**, **1120×700**, and **1440×900**: controls
   remain reachable via keyboard/scrollbar and the toolbar capsule is aligned.
2. **Sanitized LQCD evidence rubric.** On three sanitized fixture papers,
   verify that every shown result is classified as `direct`, `inference`, or
   `missing`; `direct` has an anchor in the same paper, and a value without an
   anchor is never displayed as `direct`.
3. **Installed artifact.** Confirm the actual `/Applications` choice as one
   of `preserved_and_renamed_old_app`, `replaced_after_verified_backup`, or
   `no_old_app`. Verify app-only uninstall semantics: it does not remove a
   library, PDFs, or Keychain data.
4. **Disposable migration drill.** With only the authorized disposable V7
   store family, verify migration, backup/hash/semantic verification,
   recovery, and rollback to a *new explicit target*. Do not point the app at,
   or modify, a real active library.

## Operator handoff

After all four observations pass, state the following facts in one message:

```text
I confirm LatticeLens 1.0.1 (101) manual gates PASS:
VoiceOver/three window sizes PASS; sanitized LQCD direct/inference/missing
rubric PASS; /Applications choice is <one exact allowed value>; disposable V7
migration/backup/semantic verification/recovery/rollback PASS. No real
Application Support library, research data/PDF library, Keychain, live LLM,
or destructive data operation was used.
```

Only then may a machine-readable receipt be generated under `evidence/`.
It will include the hash of
`release-assets/Release-1.0.1-local/manifest-v1.0.1.json`; the subsequent
`zsh Scripts/verify_v1_0_1_seal.sh --manual-receipt ...` check rejects a
receipt with a different version, build, manifest hash, incomplete gate, or
placeholder installation choice.
