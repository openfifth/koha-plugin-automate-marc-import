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
| File routing | One filename regex for the whole plugin | Per-setting substring patterns, with one setting as fallback/default per transport+directory |
| Import mechanism | Shells out to `stage_file.pl` / `commit_file.pl` | Calls `C4::ImportBatch` directly, wrapped in DB transactions |
| Matching/overlay | One matcher ID, fixed `--item-action always_add` | Per-profile: matcher, overlay action, no-match action, 5 item-action strategies |
| MARC modification template | One global setting | Per-profile |
| Framework selection | Not supported | Per-setting: new-record and overlay frameworks |
| Auto-commit vs. manual review | Always auto-commits | Configurable per setting |
| Record types | Biblio only | Biblio, authority, or holdings (per profile) |
| Dedup | MD5 vs. archive + 6-month `import_batches` check + 160-day age cutoff | MD5 vs. per-setting archive + 6-month `import_batches` check + mtime-since-last-run |
| Archiving | Single archive dir, never pruned | Per-setting archive dir with configurable retention (default 10, 0 disables) |
| Scheduling | Separate crontab entry, two phases (`retrieve` / `stage`) run independently | Hooks into Koha's built-in nightly cron plugin hook — no crontab entry needed |
| Manual trigger | Yes, via intranet tool UI (retrieve then stage) | No — nightly cron only |
| Notifications | None (log files only) | Staff home-page banner when staged batches await review |
| Per-run log files | Yes, `Logs/<file>.log` per stage/commit | No — Koha::Logger only |

## Gaps to be aware of

These are things getandloadmarc could do that automate-marc-import currently
cannot. None of them block migration, but plan around them:

- **No manual "run now" trigger.** getandloadmarc's intranet tool let staff
  force a retrieve/stage on demand. automate-marc-import only runs via the
  nightly cron hook. If a workflow depends on ad-hoc runs, that will need to
  change (or wait for the file to land and be picked up on the next cron run).
- **No per-vendor schedule.** All settings run together on Koha's nightly
  cron; you can't run vendor A daily and vendor B weekly.
- **No per-run log files.** getandloadmarc wrote a log file per stage/commit
  under `Logs/`. automate-marc-import logs only via Koha::Logger
  (`/var/log/koha/`), so there's no equivalent per-file artifact to inspect
  after the fact — use the staged-batch review UI and Koha's logs instead.

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

getandloadmarc's `fptn` field is a full regular expression (e.g.
`^ebook.*\.mrc`). automate-marc-import's filename patterns are **substring**
matches, not regex, so translate accordingly:

- `^ebook.*\.mrc` → pattern `ebook`
- Leave the pattern blank if the single vendor should be the default/fallback
  setting for that transport + directory combination.

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

Configure the **archive retention count** (Plugins > Automate MARC Import >
Configure). getandloadmarc never pruned its archive; pick a sensible number
(default 10) rather than carrying that behaviour forward.

### 7. Parallel run and cut over

1. Leave getandloadmarc's crontab entries in place but do not disable them
   yet.
2. Let automate-marc-import's nightly cron hook run alongside it for a few
   nights. Because both plugins de-duplicate independently (each maintains
   its own archive and 6-month `import_batches` filename check), running
   both briefly should not cause double-imports of the same file — but
   confirm this against actual staged/committed batches before relying on
   it.
3. Compare staged/committed batches and the staff notification banner
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
