# LatticeLens 1.0.2 (102) — current same-Mac local candidate

This package fixes the Evidence response failure shown as root contains unknown
or missing key: harmless gateway metadata at the response root is discarded, and
exactly one complete object under data, result, output, paper_insight, or
paper_insight_v2 is accepted. The required paper-insight-v2 fields,
duplicate-key rejection, source scope, anchor allowlist, and numeric-provenance
checks are unchanged.

It is ad-hoc signed for same-Mac local inspection. It is not Developer ID signed
or notarized. Before replacing /Applications/LatticeLens.app, quit every
LatticeLens process, verify manifest-v1.0.2.json and SHA256SUMS.txt, then drag
LatticeLens.app from the mounted DMG into /Applications.

The package was fixture-smoked only with a disposable project-local SwiftData
root and no network. Normal uninstall removes only the app bundle; it does not
remove Application Support, PDF caches, or Keychain. Migration rollback must
target only a separately identified disposable store and a new recovery target.
