# LatticeLens 1.0.1 (101) — local candidate

This DMG was rebuilt from the current source after the Evidence formula workflow responsiveness fix. It is ad-hoc signed for same-Mac local inspection; it is not Developer ID signed or notarized.

Before installing, quit any running LatticeLens process. Verify `manifest-v1.0.1.json` and `SHA256SUMS.txt`, then drag `LatticeLens.app` into `/Applications` according to your chosen install policy. The fixture smoke used only a project-local disposable store and did not read a real library, Keychain, INSPIRE, or live LLM.

The Evidence tab now reads only the selected paper\x27s bounded document/chunk/anchor projection. It shows connecting, first-content wait, receiving, validating, elapsed seconds, a cancel action, and finite deadlines (15 s connect, 45 s first content, 30 s idle, 120 s hard per request; deep mode uses at most two requests).
