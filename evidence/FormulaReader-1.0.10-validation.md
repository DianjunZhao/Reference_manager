# Formula reader 1.0.10 — scoped local checks

Scope: presentation and scrolling, using synthetic fixtures only. No real
Application Support library, paper/PDF cache, Keychain credential, INSPIRE or
LLM request was accessed. Existing provider/schema/workflow code is unchanged.

## Focused automated checks

- `CoreContractTests.testLocalMarkdownTeXPreservesRawSourceAndUsesOnlyNativePreview`:
  PASS (1 test). Legacy rendering outside the new formula reader is unchanged.
- `CoreContractTests.testFormulaReaderNormalizesMathWithoutExecutingImportedMarkup`:
  PASS (1 test). Inline/display/bare TeX, escaped imported markup, currency/prose
  exclusion, one raw disclosure per card, and no inference-to-direct promotion.
- `CoreContractTests.testFormulaReaderOfflineTypesettingAndScrolling`:
  PASS after one implementation correction. The initial run exposed a native
  scrollbar update lost when WebKit suspends animation frames in hidden windows;
  the corrected run passed in 1.131 s. Actual WebKit loads local KaTeX/fonts,
  renders the synthetic math without fallback, keeps inline math inline,
  confines horizontal overflow to equations, reaches the last marker, updates
  the native scroller, resizes, and opens raw source. Asset path traversal and
  external URLs are rejected. This is not merely an HTML string test.

## Graphical fixture observations

Used an explicitly isolated app with `LATTICELENS_USE_FIXTURES=1`,
`LATTICELENS_FIXTURE_FORMULA_LAYOUT=1`, initial Evidence tab, and a project-local
fixture cache. The visible UI confirmed fixture mode before selecting a paper.

- Three synthetic cards contain inline bilinears, bare TeX fractions, a long
  three-point-correlator expression, aligned equations, matrices, and 12 steps
  per card. Text, punctuation and math now share their intended lines.
- Dragging the native right scrollbar changed both native/WebKit scroll values
  from 0 to 1 and visibly reached “推导结束”. Wheel scrolling moved the content
  and matching native value (0.761807 to 0.540673 after opening raw source).
- A wide equation displayed its own horizontal scrollbar. Raw-source disclosure
  expands without resetting the document or requesting the model.
- “展开阅读” opens a larger reading sheet. Page Down changed both scroll values
  from 0 to 0.154579; Escape closed the sheet. The selected fixture remained.
- A resize check found the historical segmented filters forced the workspace
  wider than an 820-pixel window. Adaptive menus and column sizing corrected
  this; the reader, scrollbar and expand button were then visible inside that
  narrow window. This is not a full three-size/VoiceOver acceptance suite.

Preview: [synthetic expanded reader](formula-reader-1.0.10.png).

Tests were kept to the changed surface. No full UI suite, repeated benchmark,
live-provider run, physics validation or manual acceptance is implied. Source
controls use their own scrolling sheet after generation so they cannot squeeze
the formula viewport out of a compact window.

The native inspection tool returned “native pipe closed before response” while
opening the source-controls surface (both before and after separating it into
a sheet); the app process remained running. Source-sheet graphical acceptance
is therefore NOT_VERIFIED, not recorded as a successful observation. Formula
reader observations above were obtained from readable UI state/screenshots.
