# Migrating from koha-plugin-getandloadmarc to koha-plugin-automate-marc-import

This guide is for libraries currently running **koha-plugin-getandloadmarc**
(single-vendor SFTP fetch-and-load) who want to move to
**koha-plugin-automate-marc-import** (multi-vendor SFTP/FTP/local automation).
It covers what changes, what to configure, and what to check before cutting
over.

## Should you migrate yet?

**automate-marc-import requires Koha 25.11.00.000 or later** (it depends on
`Koha::File::Transports`, which does not exist on older Koha). If you are on
an earlier Koha version, stay on getandloadmarc until you upgrade Koha.

## What's different

| Area | getandloadmarc | automate-marc-import |
|---|---|---|
| Vendors/sources | One, hardcoded | Unlimited, independent "settings" |
| Transport protocols | SFTP only | SFTP, FTP, local filesystem (via Koha's File Transports) |
| Credentials | Plaintext in plugin storage | Managed centrally in Koha's File Transports admin, reusable across settings |
| File routing | One filename regex for the whole plugin | Per-setting regex patterns, with one setting as fallback/default per transport+directory |
| Import mechanism | Shells out to `stage_file.pl` / `commit_file.pl` | Calls `C4::ImportBatch` directly, wrapped in DB transactions |
| Matching/overlay | One matcher ID, fixed `--item-action always_add` | Per-profile: matcher, overlay action, no-match action, 5 item-action strategies |
| MARC modification template | One global setting | Per-profile |
| Framework selection | Not supported | Per-setting: new-record and overlay frameworks |
| Auto-commit vs. manual review | Always auto-commits | Configurable per setting |
| Record types | Biblio only | Biblio, authority, or holdings (per profile) |
| Dedup | MD5 vs. archive + 6-month `import_batches` filename check + 160-day age cutoff | Real content-hash dedup against a permanent log table — only *successful* imports are deduplicated by hash; a failed import is always retried the next run rather than silently skipped |
| Archiving | Single archive dir, never pruned | Separate `Success/`/`Failed/` archive dirs per setting, each with its own configurable retention count (default 10, 0 disables) |
| Scheduling | Separate crontab entry, two phases (`retrieve` / `stage`) run independently | Hooks into Koha's built-in nightly cron plugin hook — no crontab entry needed |
| Manual trigger | Yes, via intranet tool UI (retrieve then stage) | No — nightly cron only, by design (see Gaps below) |
| Notifications | None (log files only) | Staff home-page banner when staged batches await review, plus a permanent, filterable **History** tab (Tools > Automate MARC Import > History) showing every processed file's outcome, content hash, and any error |
| Per-run log files | Yes, `Logs/<file>.log` per stage/commit | No per-file text logs, but the History tab is an equivalent — and more durable — audit trail (see Notifications row) |

## Gaps to be aware of

These are things getandloadmarc could do that automate-marc-import currently
cannot. None of them block migration, but plan around them:

- **No manual "run now" trigger.** getandloadmarc's intranet tool let staff
  force a retrieve/stage on demand. automate-marc-import only runs via the
  nightly cron hook. This is a deliberate design decision, not a temporary
  gap — a reliable on-demand trigger would need a background job, and if a
  background job is needed anyway, the nightly cron plus the History tab
  already cover the same need (check results in the morning) without the
  added complexity. If a workflow depends on ad-hoc runs, that will need to
  change (or wait for the file to land and be picked up on the next cron
  run).
- **No per-vendor schedule.** All settings run together on Koha's nightly
  cron; you can't run vendor A daily and vendor B weekly. Also deliberate —
  relying on Koha's own unified cron hook is by design, not an oversight.

Note: getandloadmarc's per-file `Logs/<file>.log` files are **not** a
remaining gap — automate-marc-import's History tab supersedes them with a
permanent, filterable, structured record instead (see the table above).

## Migration steps

### 1. Confirm Koha version

Check the Koha version is 25.11.00.000 or later. If not, upgrade Koha first.

### 2. Create a File Transport for the existing vendor connection

In **Administration > SFTP Servers**, create a new SFTP server entry using
the same connection details currently stored in getandloadmarc's
configuration:

| getandloadmarc field | Maps to File Transport field |
|---|---|
| `ftpaddress` | Host |
| `login` | Username |
| `passwd` | Password |
| `fdr` | Download directory |

Test the connection before proceeding.

### 3. Recreate the filename pattern

Both plugins match filename patterns as Perl-compatible regular expressions,
but they don't see the same amount of the filename, so a direct copy of
getandloadmarc's `fptn` is not always safe:

- getandloadmarc's `fptn` (e.g. `^ebook.*\.mrc`) is matched against the
  **full filename** as listed on the server, extension included.
- automate-marc-import only ever matches against the part of the filename
  **before its first dot** — the extension, and anything after any later
  dot, is stripped before matching happens. A pattern that expects to see a
  dot (like the `\.mrc` in the example above) will never match.

To translate: drop anything in the old pattern that relies on the extension,
keeping the rest:

- `^ebook.*\.mrc` → pattern `^ebook`
- Leave the pattern blank if the single vendor should be the default/fallback
  setting for that transport + directory combination.

Double-check any translated pattern against a sample of real filenames from
the vendor before relying on it in production.

### 4. Recreate the import behaviour as an Import Batch Profile

Bundle getandloadmarc's `matchrule` and `marctemplaterule` settings, plus its
fixed item behaviour, into one profile under **Cataloging > Stage MARC
records for import**:

| getandloadmarc field/behaviour | Profile setting |
|---|---|
| `matchrule` | Record matching rule |
| `marctemplaterule` | MARC modification template |
| Fixed `--item-action always_add` | Item action (choose the closest equivalent, or a different strategy if the old blanket "always add" wasn't actually desired) |
| Bib records only | Record type: Biblio |

Decide on overlay action (replace/create_new/ignore) and no-match action —
getandloadmarc conflated these into a single matcher ID, so this is a good
opportunity to make the intended behaviour explicit.

If getandloadmarc's `matchrule` relied on more than a simple ISBN or
exact-field match — e.g. anything resembling a tiered fallback, or
preserving specific local fields across an overlay — see
[MATCHING_AND_OVERLAY.md](MATCHING_AND_OVERLAY.md) before assuming that
behaviour can't be replicated. Several capabilities that look missing from
Koha's matcher/overlay system are actually just unconfigured (ISBN-normalized
matching ships by default; field-level preservation across an overlay is
available via the `MARCOverlayRules` system preference, off by default) —
that document covers exactly what's configurable and the one thing that
genuinely isn't.

### 5. Create the automate-marc-import setting

In **Tools > Automate MARC Import**, create a new setting that ties together
the transport, download directory, filename pattern, and import profile from
steps 2–4. Decide on auto-commit:

- If getandloadmarc was always auto-committing (it always commits after
  staging), auto-commit is the closer behavioural match.
- Consider disabling auto-commit initially for the first few nightly runs to
  verify the new profile's matching/overlay rules behave as expected, then
  enable it once confident.

### 6. Set archive retention

Configure the **archive retention count** and **failed-import archive
retention count** (Plugins > Automate MARC Import > Configure) — these
govern the `Success/` and `Failed/` archive directories independently.
getandloadmarc never pruned its archive at all; pick sensible numbers
(default 10 each) rather than carrying that behaviour forward. Note that
neither count affects deduplication accuracy — that's handled entirely by
the permanent log table now, independent of how many archived files you
choose to keep on disk.

### 7. Parallel run and cut over

1. Leave getandloadmarc's crontab entries in place but do not disable them
   yet.
2. Let automate-marc-import's nightly cron hook run alongside it for a few
   nights. Each plugin tracks what it's processed independently (getandloadmarc
   via its own archive/`import_batches` check, automate-marc-import via its
   own content-hash log), so running both briefly should not cause either
   plugin to *re-download* the same file twice — but neither plugin knows
   about the other, so if both stage/commit the same incoming file you can
   end up with a genuine duplicate biblio via your matcher/overlay settings.
   Confirm behaviour against actual staged/committed batches before relying
   on a real parallel-run period.
3. Compare staged/committed batches and automate-marc-import's History tab
   against getandloadmarc's log files (`Logs/<file>.log`) for the same
   nights.
4. Once satisfied, remove getandloadmarc's crontab entries and disable/
   uninstall the getandloadmarc plugin.

### 8. Decommission getandloadmarc

- Remove the crontab entries calling `cron/run_glm_autoresponse.pl`.
- Disable the plugin in **Administration > Plugins**.
- Retain its `Archive/` directory for a while for historical reference before
  deleting.

## Reference

- getandloadmarc: <https://github.com/openfifth/koha-plugin-getandloadmarc>
- automate-marc-import: <https://github.com/openfifth/koha-plugin-automate-marc-import>
