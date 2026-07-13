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

[Unreleased]: https://github.com/openfifth/koha-plugin-automate-marc-import/compare/v1.0.24...HEAD