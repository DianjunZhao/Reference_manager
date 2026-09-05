# LatticeLens 1.0.7 (107) — same-Mac local candidate

This is an ad-hoc-signed local candidate, not a Developer ID signed or
notarized public release. It repairs Evidence formula derivation for ar5iv
HTML: HTML excerpts are not assigned invented PDF page numbers, but their
paper, document hash, anchor ID, quote, quote hash and extracted section remain
strictly bound to the one current restricted payload. PDF sources remain
page-addressable and retain their original page check.

Before replacing `/Applications/LatticeLens.app`, quit every LatticeLens
process, verify `manifest-v1.0.7.json` and `SHA256SUMS.txt`, then drag
`LatticeLens.app` from the mounted DMG into `/Applications`. Confirm Finder
shows **Version 1.0.7 (107)**. This package was checked by two focused offline
host regressions, a universal warnings-as-errors Xcode Release build, a
read-only mounted-DMG inspection, and an isolated no-network fixture launch.
The real provider, Keychain, Application Support library, research-PDF cache,
INSPIRE and live LLM were not accessed.

The graphical Xcode fixture UI case for this exact route was attempted once,
but this Mac's XCTest automation host timed out while enabling automation
mode, before any product assertion ran. That result is `BLOCKED`, not a UI
pass or a product failure.

To roll back, quit the app and replace only the application bundle with a
previous verified bundle. Do not delete Application Support, PDF caches, or
Keychain data. The exact-binary worksheet is
`MANUAL_1_0_7_ACCEPTANCE.md` at repository root.
