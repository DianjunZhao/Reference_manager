# LatticeLens 1.0.10 (110) — same-Mac local candidate

This ad-hoc-signed universal app is not Developer ID signed or notarized.
The change is offline formula typesetting and scrolling, not a provider,
schema, evidence, or storage migration change.

Quit LatticeLens before replacing /Applications/LatticeLens.app. Check
SHA256SUMS.txt and manifest-v1.0.10.json, mount LatticeLens-1.0.10-local.dmg,
then copy LatticeLens.app into /Applications. Finder must show 1.0.10 (110).

Open a previously generated formula derivation: it is typeset immediately
with bundled KaTeX and local fonts, without regenerating or sending data.
Use the permanent right scrollbar or wheel to read all steps; use the
horizontal scrollbar inside an over-wide equation. “展开阅读” opens a larger
reader; “关闭” or Escape returns. The original text/TeX is selectable in one
collapsed section per formula. Ambiguous or unsupported math remains visible
as source rather than being silently rewritten into approximate physics.

Narrow windows use compact filter/tab menus. Full-text sources and anchors
remain available in a separate scrolling panel, without crowding the reader.

Focused automated tests and synthetic graphical observations are documented
in evidence/FormulaReader-1.0.10-validation.md in the source repository. No
live LLM, INSPIRE, Keychain credential, real Application Support library or
research-PDF cache was accessed. Source-panel graphical inspection was blocked
by the native inspection tool; it is not claimed as passed. Manual acceptance
and physics correctness are not established by a successful local build.

To roll back, quit the app and restore only a previously verified app bundle.
Do not remove or overwrite Application Support, paper caches or Keychain data.
This build does not change the active library schema. The prior 1.0.9 package
remains in the repository's release-assets/Release-1.0.9-local/ history.
