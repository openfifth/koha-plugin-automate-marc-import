# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add user-visible changes under the `[Unreleased]` heading below as you work.
On the next `npm run release:*`, `increment_version.js` promotes `[Unreleased]`
to a dated `[X.Y.Z]` section and inserts a fresh empty `[Unreleased]` above it
along with the comparison links — do not edit the heading or the links by hand.

## [Unreleased]

### Added
- Optional remote file cleanup after a successful import: per-setting choice to delete, rename (with a configurable suffix, e.g. `.done`), or move the file on the remote server. A failed import always leaves the remote file untouched, so existing retry behaviour is unaffected. (#2)

## [1.5.0] - 2026-07-22

### Added
- Content-hash based deduplication: an import is skipped if its file's content matches the last *successful* import under that filename, while a file whose last attempt failed is always retried, even with identical content. Backed by a new plugin-owned log table, created via an `install()` hook.
- Processed files are now archived into `Archive/{setting_id}/Success/` or `Archive/{setting_id}/Failed/`, each with its own configurable retention count, instead of a single shared archive directory.
- An Import History tab on the tool page, listing past processing attempts with outcome, linked batch, and error detail, filterable by setting and outcome.

### Changed
- A one-time `upgrade()` migration moves any files already archived under the old flat layout into the new `Success/` subdirectory, so nothing is orphaned by the restructure.

## [1.4.0] - 2026-07-22

### Changed
- Filename patterns are now matched as Perl-compatible regular expressions instead of plain substrings, enabling anchors (`^`/`$`), alternation (`daily|weekly`), character classes, and quantifiers. Matching stays case-insensitive. Existing patterns are migrated automatically on upgrade (see below), so no admin action is required to keep current behaviour.
- `tool.tt` filename patterns field now documents regex syntax with examples and a link to the perlre documentation.

### Added
- A one-time `upgrade()` migration that rewrites every existing setting's filename patterns to their `quotemeta`-escaped equivalent, guaranteeing they keep matching exactly the same filenames they did under the old substring behaviour. Guarded against re-running on later, unrelated version bumps.
- Filename pattern validation on save: each line must compile as a regex, and embedded-code constructs (`(?{ ... })` / `(??{ ... })`) are explicitly rejected regardless of Perl taint mode.
- A per-pattern timeout guard (`alarm`-based) around filename matching, so a pathological regex (catastrophic backtracking) is skipped and logged rather than hanging the nightly cron run for every configured vendor.

## [1.3.0] - 2026-07-21

### Added
- A "New profile" modal on the add/edit setting form, letting admins create an import profile inline — via the existing `import_batch_profiles` REST API — without leaving the page.

## [1.2.1] - 2026-07-21

### Fixed
- The "Add a new transport" link on the tool page pointed at a non-existent path; it now correctly points at `file_transports.pl`.

### Changed
- General layout tidy-up of the tool page.

## [1.2.0] - 2026-07-21

### Added
- Per-setting override of the transport's download directory, so one transport can serve multiple settings that each fetch from a different remote directory. Each transport/directory combination is polled independently during the nightly cronjob, and the effective directory is shown in the settings list.

## [1.1.0] - 2026-07-21

_Bumped and committed but never tagged or published — the release script appears to have been re-run immediately afterwards. Its intended content (the download directory override above) shipped as [1.2.0] instead._

## [1.0.28] - 2026-07-20

### Changed
- CI now tests against OpenFifth's own Koha fork instead of the community image.

## [1.0.27] - 2026-07-20

### Fixed
- A directory whose name happens to match a supported MARC extension (e.g. a folder called `archive.mrc`) is no longer mistaken for a real file. All three `Koha::File::Transport` backends (FTP, Local, SFTP) now include directories in `list_files()` results, so only the transport's `type` field (not the filename) can tell them apart.

### Changed
- `_file_entry_size`/`_file_entry_mtime` no longer fall back to reading a `$filehash->{a}` SFTP Attributes object directly; `Koha::File::Transport::SFTP::list_files()` now always returns flat `size`/`mtime` fields like FTP and Local. Requires the Koha core fix for bug 43078 (unified `list_files()` shape across FTP/Local/SFTP, including directories and a `type` field) - currently only available on 25.11.o5th and above, ahead of its upstream release.

## [1.0.26] - 2026-07-13

### Fixed
- A transport method that throws (rather than returns undef) on an older Koha version — e.g. a missing core dependency — no longer aborts the whole cronjob run; it's now caught and logged like any other transport failure.

## [1.0.25] - 2026-07-13

### Fixed
- CSRF tokens and POST submission for the configure, save and delete forms
- Transport connect/list/download failures now detected and logged instead of silently ignored
- FTP filenames and file metadata read correctly from all transport listing formats
- Download and archive directories created reliably before use
- Batch match actions default sensibly when the import profile leaves them unset
- Original framework kept on overlay when "keep original" is chosen
- Matching progress callback passed correctly to the duplicate finder

## [1.0.24] - 2026-02-04

### Changed
- Bumped the plugin's declared minimum supported Koha version.

## [1.0.23] - 2026-01-29

### Changed
- The tool page controller now passes MARC modification template and record matcher data directly, instead of routing it through an API the plugin doesn't itself expose.

## [1.0.22] - 2026-01-29

### Changed
- Internal lookups now use `find()` instead of `search()` where a single record is expected.

## [1.0.21] - 2026-01-20

### Fixed
- Removed a hardcoded fallback to ISBN/title matching when no matcher was configured on the import profile, which could produce unintended record matches.

## [1.0.20] - 2026-01-20

### Fixed
- Profile overlay and no-match actions weren't being applied correctly during MARC staging.

## [1.0.19] - 2026-01-20

### Added
- Per-setting archive directories with a configurable retention policy for processed files.

## [1.0.18] - 2026-01-20

### Added
- Name and description fields on import settings, so multiple settings can be told apart at a glance.

## [1.0.17] - 2026-01-20

### Changed
- Converted from a `configure`-type plugin to a `tool`-type plugin, moving its UI under Tools rather than plugin configuration.
- Moved the plugin to the `Koha::Plugin::Com::OpenFifth` namespace.

## [1.0.16] - 2026-01-19

### Added
- Framework selection (new-record and overlay framework) for auto-committed imports.

### Fixed
- Staged-batch notifications on the main page no longer count Z39.50 or web service import batches.

## [1.0.15] - 2026-01-19

### Fixed
- Staged MARC batches now use the original filename instead of the full local file path.
- The import profile is now correctly associated with its staged batch.

## [1.0.14] - 2026-01-19

### Added
- A database check against `import_batches` to prevent re-importing files that were already staged.
- Configuration page UX improvements, displaying friendly names instead of raw IDs.

### Fixed
- Corrected filename pattern matching logic in setting lookup.

## [1.0.13] - 2026-01-19

### Fixed
- Improved the breadcrumb trail on the tool page.

## [1.0.12] - 2026-01-19

### Fixed
- Switched to Koha's own Select2 component and fixed the profile change handler.

## [1.0.11] - 2026-01-16

### Fixed
- Profile ID matching in the setting select handler now uses a lookup map instead of a less reliable comparison.

## [1.0.10] - 2026-01-16

_No user-visible change — version bump only._

## [1.0.9] - 2026-01-16

### Fixed
- Resolved bugs in edit-form pre-population and the profile select field.

## [1.0.8] - 2026-01-16

### Added
- Edit functionality for existing configuration settings.

## [1.0.7] - 2026-01-16

### Fixed
- Removed a meaningless breadcrumb level.

## [1.0.6] - 2026-01-16

### Fixed
- Fixes to the dynamic column-name detection added in 1.0.2.

## [1.0.5] - 2026-01-16

_No user-visible change — added a `package-lock.json` for CI reliability._

## [1.0.4] - 2026-01-16

_No user-visible change — added a `yarn.lock` for CI reliability._

## [1.0.3] - 2026-01-16

### Fixed
- No longer attempts to build against Koha oldstable, whose codebase doesn't have the classes this plugin depends on.

## [1.0.2] - 2026-01-16

### Added
- Dynamic column name detection for Koha version compatibility, automatically adapting to different file transport table schemas (`id` vs `file_transport_id` column naming).

## [1.0.1] - 2025-11-19

### Added
- File archiving and MD5-based deduplication for downloaded files.
- Auto-commit configuration UI.

## [1.0.0] - 2025-11-03

### Added
- The plugin now throws a clear error if no import profile is found, instead of failing silently.

### Fixed
- Corrected references to a database column name.

### Changed
- Refactored the `configure` and `stage` subroutines for clarity.

## [0.0.1] - 2025-07-02

### Added
- Initial release of Automate MARC Import plugin
- Comprehensive input validation and sanitization
- Try::Tiny error handling for SFTP operations
- Modern database transaction patterns with automatic rollback
- Robust file extension detection using File::Basename
- Support for .mrc, .mrcx, .xml, and .marcxml file formats
- Graceful error handling and logging throughout
- jQuery Validate integration for client-side validation
- Modern CI/CD pipeline with GitHub Actions
- Automated testing framework with koha-testing-docker
- Automated release management and kpz generation

### Security
- Protection against SQL injection via comprehensive input validation
- Path traversal attack prevention in filename processing
- XSS prevention with proper template escaping
- DoS prevention with input length limits

### Technical Improvements
- Modern Koha plugin architecture following current standards
- Proper dependency management and import organization
- Comprehensive error logging and debugging support
- Atomic database transactions ensuring data integrity

[Unreleased]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.28...v1.1.0
[1.0.28]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.27...v1.0.28
[1.0.27]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.26...v1.0.27
[1.0.26]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.25...v1.0.26
[1.0.25]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.24...v1.0.25
[1.0.24]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.23...v1.0.24
[1.0.23]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.22...v1.0.23
[1.0.22]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.21...v1.0.22
[1.0.21]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.20...v1.0.21
[1.0.20]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.19...v1.0.20
[1.0.19]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.18...v1.0.19
[1.0.18]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.17...v1.0.18
[1.0.17]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.16...v1.0.17
[1.0.16]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.15...v1.0.16
[1.0.15]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.14...v1.0.15
[1.0.14]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.13...v1.0.14
[1.0.13]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.12...v1.0.13
[1.0.12]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.11...v1.0.12
[1.0.11]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.10...v1.0.11
[1.0.10]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.9...v1.0.10
[1.0.9]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.8...v1.0.9
[1.0.8]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.7...v1.0.8
[1.0.7]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.6...v1.0.7
[1.0.6]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/450f68a4abed27647dbde83bb1778f773057b9d4...v1.0.0
