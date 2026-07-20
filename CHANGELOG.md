# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add user-visible changes under the `[Unreleased]` heading below as you work.
On the next `npm run release:*`, `increment_version.js` promotes `[Unreleased]`
to a dated `[X.Y.Z]` section and inserts a fresh empty `[Unreleased]` above it
along with the comparison links — do not edit the heading or the links by hand.

## [Unreleased]

## [1.0.27] - 2026-07-20

### Fixed
- A directory whose name happens to match a supported MARC extension (e.g. a folder called `archive.mrc`) is no longer mistaken for a real file. All three `Koha::File::Transport` backends (FTP, Local, SFTP) now include directories in `list_files()` results, so only the transport's `type` field (not the filename) can tell them apart.

### Changed
- `_file_entry_size`/`_file_entry_mtime` no longer fall back to reading a `$filehash->{a}` SFTP Attributes object directly; `Koha::File::Transport::SFTP::list_files()` now always returns flat `size`/`mtime` fields like FTP and Local. Requires the Koha core fix for bug 43078 (unified `list_files()` shape across FTP/Local/SFTP, including directories and a `type` field) - currently only available on 25.11.o5th and above, ahead of its upstream release.

## [1.0.26] - 2026-07-13

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

### Added
- Dynamic column name detection for Koha version compatibility
- Automatic adaptation to different file transport table schemas (id/file_transport_id)
- Edit functionality for existing configuration settings

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

[Unreleased]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.27...HEAD
[1.0.27]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.26...v1.0.27
[1.0.26]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.25...v1.0.26
[1.0.25]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.24...v1.0.25
[1.0.24]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.23...v1.0.24