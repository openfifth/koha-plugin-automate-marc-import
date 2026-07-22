# Configuring record matching and overlay behaviour

This plugin doesn't implement its own record-matching or field-merging logic —
it delegates entirely to whatever Import Batch Profile and record matching
rule you select (see "Import Batch Profile Setup" in the [README](README.md)).
Koha's own matching and overlay system is more capable than it might first
appear, but several useful behaviours require configuration that isn't
obvious from the admin UI alone. This doc covers what's actually possible,
and is explicit about the one thing that genuinely isn't.

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

## Tiered/fallback matching (e.g. "try 001+003, then 001 alone, then ISBN") — not possible

Some legacy import tools (e.g. the standalone `ftp2koha` script) implement a
three-tier fallback: try an exact control-number match first, fall back to a
looser one, and only then fall back to ISBN. **Koha's matcher cannot express
this, and no amount of matching-rule configuration will produce it.**

Why: `C4::Matcher` uses a single **additive scoring model**, not a sequential
one. Every match point you configure on a rule runs unconditionally, and its
score is *added* to whatever biblio numbers it finds; only after all match
points have run does Koha filter by threshold (`C4::Matcher::get_matches`).
There is no "only try match point B if match point A found nothing" concept
anywhere in the model. Two specific consequences:

- **You can't AND two fields together as one check.** Multiple components
  within a single match point are concatenated into one search phrase, not
  logically ANDed — a "001+003" component pair doesn't mean "both must
  match," it means "search for this concatenated string."
- **Stacking several match points on one rule to approximate tiering is
  unsafe, not just inelegant.** Because every match point runs regardless of
  the others' results, a record intended to match on control numbers can
  also pick up an unrelated ISBN hit against a *different* biblio, and both
  come back as candidates above threshold — there's no guarantee the
  "intended" tier's match is the one that wins.

At the API level, `C4::ImportBatch::BatchFindDuplicates` takes one matcher ID
and processes the whole batch in a single pass; nothing in this plugin or in
Koha core retries no-match records against a second matcher. Getting true
tiered fallback would require new plugin logic to orchestrate multiple
matchers in sequence — it is not a configuration gap, it's a missing
capability.

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
| Tiered/sequential fallback matching across multiple rules | Not possible today — would need new plugin logic |
