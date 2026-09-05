# LatticeLens 1.0.6 (106) — same-Mac local candidate

This is an ad-hoc-signed local candidate, not a Developer ID signed or
notarized public release. It repairs an Evidence formula-derivation response
where a provider emits `physics.research_question` as a JSON string rather than
as an anchored claim object. The scalar text is not promoted to a physics
claim: it is represented only as unavailable, while the remaining formula
derivations still require their own full-text evidence anchors and all other
strict schema checks.

Before replacing `/Applications/LatticeLens.app`, quit every LatticeLens
process, verify `manifest-v1.0.6.json` and `SHA256SUMS.txt`, then drag
`LatticeLens.app` from the mounted DMG into `/Applications`. Confirm Finder
shows **Version 1.0.6 (106)**. The package was checked by two focused offline
workflow regressions, one real Xcode fixture UI regression, a universal
warnings-as-errors Xcode Release build, and a read-only mounted-DMG inspection.
It was not launched with a real provider, Keychain, Application Support
library, research-PDF cache, INSPIRE, or LLM request.

To roll back, quit the app and replace only the application bundle with a
previous verified bundle. Do not delete Application Support, PDF caches, or
Keychain data. The exact-binary worksheet is
`MANUAL_1_0_6_ACCEPTANCE.md` at repository root.
