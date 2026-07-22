# Configuring record matching and overlay behaviour

This plugin doesn't implement its own record-matching or field-merging logic —
it delegates entirely to whatever Import Batch Profile and record matching
rule you select (see "Import Batch Profile Setup" in the [README](README.md)).
Koha's own matching and overlay system is more capable than it might first
appear, but several useful behaviours require configuration that isn't
obvious from the admin UI alone. This doc covers what's actually possible —
including a couple of things that look like missing features but are really
just under-documented configuration — and is explicit about the one thing
that genuinely needs a Koha core change.

## ISBN-normalized matching

Koha ships this by default — you don't need to build anything.

1. Go to **Administration > Record matching rules**.
2. The shipped **ISBN** rule (or a new one you create the same way) is defined
   as:
   - Matching rule code: `ISBN`
   - Match threshold: `1000`
   - Record type: Bibliographic record
   - One match point, search index `isbn`, score `1000`
   - One component on that match point: tag `020`, subfield `a`,
     normalization rule **`ISBN`**
3. Select this matching rule on your Import Batch Profile.

The `ISBN` normalization routine (`Koha::Util::Normalize::ISBN`, backed by
`C4::Koha::NormalizeISBN`) strips hyphens and converts between ISBN-10/13
variants before comparing, so incoming and catalogue ISBNs in different
formats still match correctly.

## Tiered/fallback matching (e.g. "try 001+003, then 001 alone, then ISBN")

Some legacy import tools (e.g. the standalone `ftp2koha` script) implement a
three-tier fallback: try an exact control-number match first, fall back to a
looser one, and only then fall back to ISBN. Koha's matcher doesn't have an
explicit "tier" concept, but you can get the same practical outcome by
understanding how it actually picks a winner — this is a configuration
technique, not a missing feature.

`C4::Matcher` uses an **additive scoring model**: every match point on a rule
runs unconditionally and its score is *added* to whatever biblio numbers it
finds (`C4::Matcher::get_matches`, `C4/Matcher.pm:706-856`). Critically,
though, the results are then **sorted by score descending**
(`C4/Matcher.pm:851`), and Koha's batch-import path auto-selects only the
**single highest-scoring candidate** for overlay — every candidate above
threshold is stored, but `SetImportRecordMatches` marks just the top scorer
as `chosen` (`C4/ImportBatch.pm:1581-1599`), and `BatchCommitRecords` acts
only on that one via `GetBestRecordMatch` (`C4/ImportBatch.pm:1822-1860`).

That "always take the single top score" behaviour is what makes tiering
work in practice: give your most-trusted match point (e.g. an exact
control-number match) a much higher score than a looser one (e.g. ISBN), and
whenever both happen to fire — even against two *different* candidate
biblios — the higher-tier candidate wins automatically. And when your
top-tier match point finds nothing at all, there's simply no competing
high-scoring candidate, so a lower-tier match point's hit wins on its own
merits. That's a real, working fallback, achieved entirely through match
point scores.

**The one thing this can't do:** require two independent fields (e.g. 001
*and* 003) to both match as a single condition. Multiple components within
one match point are concatenated into a single search phrase, not logically
ANDed, and the underlying search indexes for 001 (`control-number`) and 003
(`control-number-identifier`) are indexed as entirely separate fields
(`admin/searchengine/elasticsearch/mappings.yaml:1566-1589`) — so a
concatenated-phrase search against either index alone can never correctly
require both to match. There's no way to configure around this; it would
need a Koha core change.

**To set up tiered matching safely**, configure one matcher with a match
point per tier, and leave enough headroom between scores that no plausible
combination of lower-tier hits can outscore your top tier:

- Give your highest-priority match point a score **greater than the sum of
  every match point below it**, not just greater than each individually.
  Otherwise two low-tier match points landing on the same wrong candidate
  could stack (e.g. 2000 + 1000) and outrank a legitimate top-tier hit
  scored at only 1500.
- Example: control-number-alone at score `10000`, ISBN at score `100`,
  threshold `100`. No realistic combination of ISBN-only hits can reach
  `10000`, so the control-number tier always wins when it fires, and ISBN
  only decides things when control-number found nothing.

## Preserving existing catalogue data across an overlay (MARCOverlayRules)

This is the one that's easy to miss entirely: Koha has had **field-level
overlay rules** since 21.06 (bug 14957), and this plugin's import path
already calls into them — you just need to turn the feature on.

`C4::ImportBatch::BatchCommitRecords` (used by every setting in this plugin)
calls `ModBiblio` with `overlay_context => { source => 'batchimport', ... }`.
If the `MARCOverlayRules` system preference is enabled, `ModBiblio` merges
the existing catalogue record with the incoming one field-by-field
according to your configured rules, *before* saving — instead of the
incoming record always overwriting the existing one outright.

To use it:

1. Enable the **`MARCOverlayRules`** system preference (off by default).
2. Go to **Administration > Record overlay rules**.
3. Add a rule per MARC tag (a plain 3-digit tag, or a regex matching several,
   e.g. `59[0-9]` for a block of local note fields) you want to control:
   - **Module**: `source`, `categorycode`, or `userid` — checked in that
     priority order (`userid` wins if multiple rules could match, then
     `categorycode`, then `source`).
   - **Filter**: for imports done through this plugin, use module `source`
     with filter `batchimport` — that's the exact value the plugin's
     underlying `BatchCommitRecords` call sends. Use `*` to apply a rule
     regardless of source.
   - Pick a preset, or set the four flags yourself:
     - **Protect** (`add=0, append=0, remove=0, delete=0`) — the incoming
       record can never touch this field; local data always wins.
     - **Overwrite** (`add=1, append=1, remove=1, delete=1`) — incoming
       always wins. This is today's behaviour for any tag with no matching
       rule, or whenever the preference is off.
     - **Add new** (`add=1`, others off) — take the field only if the
       catalogue record doesn't already have one; never touch it otherwise.
     - **Add and append**, **Protect from deletion** — other useful presets
       available directly in the UI.

**Limitation to know about:** rules are field-level, not subfield-level — you
can protect all of field 856 from overlay, but you can't say "keep the local
856$u but accept an updated 856$z." This matches the granularity of similar
tools elsewhere (e.g. `ftp2koha`'s own `preserve_fields` is field-number
based too), it's just worth knowing the boundary before relying on it.

With no rules configured (or the preference off), behaviour is unchanged
from today: full record replacement.

## Summary

| Need | How to get it |
|---|---|
| ISBN-normalized matching | Select Koha's shipped `ISBN` matching rule on your Import Batch Profile |
| Delete/copy/move incoming fields conditionally | MARC modification templates (already supported per-profile) |
| Preserve specific existing catalogue fields across an overlay | Enable `MARCOverlayRules` + configure rules, module `source` / filter `batchimport` |
| Tiered/fallback matching (prefer a stronger match over a weaker one) | Achievable today via match point score separation — see above |
| Require two independent fields (e.g. 001 *and* 003) to both match as one condition | Not possible — separate search indexes, no cross-field AND in the matcher model; would need a Koha core change |
