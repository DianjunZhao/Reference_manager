# LatticeLens 1.0.1 (101) — current same-Mac local candidate

This refreshed DMG contains the completed hep-lat/hep-th author-index recovery,
formula-focused Evidence reader, native TeX/MathML/Greek-symbol display, Chinese
Evidence labels, and long-stream Evidence progress. Evidence has no
application-imposed total deadline: it keeps a 120-second connection budget,
180-second first-content budget, and 120-second idle budget. During a healthy
stream it shows cumulative characters, UTF-8 bytes, elapsed seconds, and average
characters per second; **Cancel** remains available.

It is ad-hoc signed for same-Mac local inspection. It is not Developer ID signed
or notarized. Before replacing `/Applications/LatticeLens.app`, quit every running
LatticeLens process, then verify `manifest-v1.0.1.json` and `SHA256SUMS.txt` and
drag `LatticeLens.app` from the DMG into `/Applications`. The DMG smoke used only
a project-local fixture store and made no real-library, Keychain, INSPIRE, or live
LLM request.

The current installed application was deliberately not replaced while it was
running. A new manual acceptance receipt must bind this exact manifest/DMG before
calling the final seal verifier; the earlier receipt must not be treated as byte
evidence for this refreshed package.
