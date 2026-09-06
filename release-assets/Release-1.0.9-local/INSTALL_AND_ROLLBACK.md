# LatticeLens 1.0.9 (109) — same-Mac local candidate

This is an ad-hoc-signed local candidate, not a Developer ID signed or
notarized public release. It repairs exactly one model JSON formatting defect:
an omitted comma between two already-complete strings, or two already-complete
objects, in the same JSON array. The parser scans the entire result under
strict JSON rules after that insertion. It does not rewrite source text,
formula TeX, evidence IDs, anchor values, object fields, number literals,
escapes, or provenance.

Thus an anchored formula derivation can survive a response such as two adjacent
`derivation_steps` strings with the separator omitted. Missing commas between
object members, incomplete strings, malformed Unicode/JSON escapes, malformed
IDs, unknown keys, unanchored claims, and numeric claims not recoverable from
valid anchors remain rejected. No anchor is invented.

Before replacing `/Applications/LatticeLens.app`, quit every LatticeLens
process, verify `manifest-v1.0.9.json` and `SHA256SUMS.txt`, then drag
`LatticeLens.app` from the mounted DMG into `/Applications`. Confirm Finder
shows **Version 1.0.9 (109)**. This package was checked by two focused offline
host regressions, a clean-tree universal warnings-as-errors Xcode Release
build, a read-only mounted-DMG inspection, and an isolated no-network fixture
launch. The real provider, Keychain, Application Support library, research-PDF
cache, INSPIRE and live LLM were not accessed.

To roll back, quit the app and replace only the application bundle with a
previous verified bundle. Do not delete Application Support, PDF caches, or
Keychain data. The exact-binary worksheet is
`MANUAL_1_0_9_ACCEPTANCE.md` at repository root.
