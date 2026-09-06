# LatticeLens 1.0.8 (108) — same-Mac local candidate

This is an ad-hoc-signed local candidate, not a Developer ID signed or
notarized public release. It handles a model's structurally valid but
unanchored `direct` / `inference` supplemental claims safely: their original
text is discarded rather than saved or displayed as a paper conclusion. The
strict evidence contract for surviving content is unchanged: current-paper,
current-document hash, anchor ID, quote, quote hash, section, and (for PDFs)
page must validate; numeric claims must remain checkable against that anchor.

Before replacing `/Applications/LatticeLens.app`, quit every LatticeLens
process, verify `manifest-v1.0.8.json` and `SHA256SUMS.txt`, then drag
`LatticeLens.app` from the mounted DMG into `/Applications`. Confirm Finder
shows **Version 1.0.8 (108)**. This package was checked by three focused
offline host regressions, a universal warnings-as-errors Xcode Release build,
a read-only mounted-DMG inspection, and an isolated no-network fixture launch.
The real provider, Keychain, Application Support library, research-PDF cache,
INSPIRE and live LLM were not accessed.

The graphical Xcode fixture UI case for this route was attempted once, but
this Mac's XCTest automation host timed out while enabling automation mode,
before any product assertion ran. That result is `BLOCKED`, not a UI pass or a
product failure.

To roll back, quit the app and replace only the application bundle with a
previous verified bundle. Do not delete Application Support, PDF caches, or
Keychain data. The exact-binary worksheet is
`MANUAL_1_0_8_ACCEPTANCE.md` at repository root.
