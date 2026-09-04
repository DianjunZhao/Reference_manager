# LatticeLens 1.0.4 (104) — same-Mac local candidate

This is an ad-hoc-signed local candidate, not a Developer ID signed or
notarized public release. It fixes the Evidence formula-derivation rejection
caused solely by an absent original abstract: the strict v2 schema accepts
only `abstract_zh: ""` for that specific source condition. It still rejects a
missing, `null`, whitespace-only, overlong, or invented abstract, and preserves
the anchor/source-scope/numeric-provenance boundaries.

Before replacing `/Applications/LatticeLens.app`, quit every LatticeLens
process, verify `manifest-v1.0.4.json` and `SHA256SUMS.txt`, then drag
`LatticeLens.app` from the mounted DMG into `/Applications`. Confirm Finder
shows **Version 1.0.4 (104)**. The package was checked only by one offline
targeted regression, a universal warnings-as-errors Xcode Release build, and a
read-only mounted-DMG inspection. It was not launched and made no provider,
Keychain, Application Support library, research-PDF cache, INSPIRE, or LLM
access.

To roll back, quit the app and replace only the application bundle with a
previous verified bundle. Do not delete Application Support, PDF caches, or
Keychain data. The current 1.0.4 exact-binary manual worksheet is
`MANUAL_1_0_4_ACCEPTANCE.md` at repository root.
