# LatticeLens 1.0.5 (105) — same-Mac local candidate

This is an ad-hoc-signed local candidate, not a Developer ID signed or
notarized public release. It repairs an Evidence formula-derivation response
where the model writes a TeX command marker directly in JSON, for example
`\\alpha`, which previously caused `string escape无效`. The repair is not a
general permissive JSON mode: valid escapes are unchanged, malformed `\\u`
unicode escapes still fail, and the schema, source scope, anchor and numeric
provenance checks remain strict.

Before replacing `/Applications/LatticeLens.app`, quit every LatticeLens
process, verify `manifest-v1.0.5.json` and `SHA256SUMS.txt`, then drag
`LatticeLens.app` from the mounted DMG into `/Applications`. Confirm Finder
shows **Version 1.0.5 (105)**. The package was checked only by one offline
targeted regression, a universal warnings-as-errors Xcode Release build, and a
read-only mounted-DMG inspection. It was not launched and made no provider,
Keychain, Application Support library, research-PDF cache, INSPIRE, or LLM
access.

To roll back, quit the app and replace only the application bundle with a
previous verified bundle. Do not delete Application Support, PDF caches, or
Keychain data. The current 1.0.5 exact-binary manual worksheet is
`MANUAL_1_0_5_ACCEPTANCE.md` at repository root.
