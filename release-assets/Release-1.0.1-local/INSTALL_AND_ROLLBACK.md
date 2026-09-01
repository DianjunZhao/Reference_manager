# LatticeLens 1.0.1 (101) — local candidate

This is a same-Mac, ad-hoc signed candidate, not a notarized public release.
It contains `LatticeLens-1.0.1-local.dmg` and is intentionally distinguishable
from the older `1.0.0 (100)` application.

## Verify and install

1. Run `shasum -a 256 -c SHA256SUMS.txt` in this directory. The DMG hash must
   match `manifest-v1.0.1.json`.
2. Quit every running `LatticeLens` process before replacing an app bundle.
3. Open the DMG and drag `LatticeLens.app` to `/Applications`, choosing the
   explicit Finder replacement action only after the existing app is closed.
4. In Finder, choose **Get Info** for `/Applications/LatticeLens.app`. It must
   show **Version 1.0.1 (101)**. A `1.0.0 (100)` app is an older binary.
5. On a fresh library with network access, the first screen should show the
   pinned Zhao author and one initial page of papers. If it does not, use the
   visible retry/sync action and retain the on-screen error text.

## Rollback and data safety

- Replacing or removing the app bundle does not delete a library, PDFs or
  Keychain entries.
- Do not delete Application Support to troubleshoot a blank screen.
- A V7 migration rollback must restore only to a new, explicit target using a
  verified disposable backup; it must never overwrite an active library.

## Verification boundary

The package was mounted and launched against a new project-local disposable
store. That test wrote 1 author, 10 papers and 10 author-paper links after
real read-only INSPIRE requests. The refreshed DMG was subsequently copied to
`/Applications/LatticeLens.app` after confirming no running LatticeLens process;
the installed executable hash is recorded in `manifest-v1.0.1.json`. No real
library was opened, and no live LLM was used. Manual observations are recorded
separately in the bound acceptance receipt under `github/evidence/`.
