# LatticeLens 1.0.3 (103) — current same-Mac local candidate

This candidate preserves normal macOS HTTPS certificate validation.  If an
Evidence formula derivation cannot establish a trusted TLS connection, it now
shows a Chinese diagnosis containing only the configured endpoint host and
port, confirms that no full-text evidence was automatically resubmitted, and
directs the user to Settings **测试连接**.  It does not accept arbitrary
certificates and it does not fall back to HTTP.

It is ad-hoc signed for same-Mac local inspection.  It is not Developer ID
signed or notarized.  Before replacing `/Applications/LatticeLens.app`, quit
every LatticeLens process, verify `manifest-v1.0.3.json` and `SHA256SUMS.txt`,
then drag `LatticeLens.app` from the mounted DMG into `/Applications`.

The package was validated only with an offline targeted test, a universal
warnings-as-errors Xcode Release build, and a read-only mounted-DMG inspection.
No real Application Support library, research PDF cache, Keychain, INSPIRE, or
LLM provider was read or contacted.  Normal uninstall removes only the app
bundle; it does not remove Application Support, PDF caches, or Keychain.

For a TLS observation, open Settings, use **测试连接** explicitly, and record
the displayed host/port-only result.  That probe sends no paper full text;
neither it nor the formula button may be used to weaken HTTPS trust checks.
