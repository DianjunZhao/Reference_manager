# LatticeLens 1.0.1 (101) — local candidate

This DMG was rebuilt with a 120-second connection allowance and a 600-second hard deadline for long Evidence formula derivations. It is ad-hoc signed for same-Mac local inspection; it is not Developer ID signed or notarized.

Before installing, quit any running LatticeLens process. Verify `manifest-v1.0.1.json` and `SHA256SUMS.txt`, then drag `LatticeLens.app` into `/Applications`. The fixture smoke uses only a project-local disposable store and does not read a real library, Keychain, INSPIRE, or live LLM.

The Evidence tab reads only the selected paper's bounded document/chunk/anchor projection and shows connecting, first-content wait, receiving, validating, elapsed seconds, a cancel action, and finite deadlines (120 s connect, 180 s first content, 120 s idle, 600 s hard per request; deep mode uses at most two requests).
