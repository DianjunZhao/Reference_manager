# Offline math typesetting

KaTeX 0.16.22, MIT (see KATEX-LICENSE.txt), from the official npm package:
https://registry.npmjs.org/katex/-/katex-0.16.22.tgz

Verified npm tarball integrity (SHA-512, base64):
XCHRdUw4lf3SKBaJe4EvgqIuWwkPSo9XoeO8GjQW94Bp7TWv9hNhzZjZ+OH9yf1UmLygb7DIT5GSFQiyt16zYg==

Unmodified katex.min.js, katex.min.css and fonts/*.woff2 are vendored here.
WebKit on the minimum supported macOS uses WOFF2; unused CSS fallback font
formats are not bundled. reader.js and reader.css are LatticeLens code.

No CDN, provider calls, external navigation, or remote assets. Math is rendered
with trust:false, bounded macro expansion and a fresh macro map per formula.
All imported text is HTML-escaped; a CSP and allowlisted custom URL scheme
restrict the document to these bundled scripts, styles and fonts. Unsupported
TeX stays visible as raw source, never a silent approximate physics formula.
