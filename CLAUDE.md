# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Koha plugin called "Automate Marc Import" that enables nightly retrieval and staging of MARC files via SFTP from vendor sites. The plugin automates the import process by connecting to configured SFTP servers, downloading MARC files, and staging them using predefined profiles.

## Key Commands

### Release Management
- `npm run release` - Creates a .kpz plugin file and manages git tagging/pushing
- `bash ./release_kpz.sh` - Direct script execution for plugin packaging

### Version Management
- `node checkVersionNumber.js version` - Extract version from plugin file
- `node checkVersionNumber.js filename` - Generate .kpz filename
- `node checkRemotes.js check` - Validate git remotes for release

## Architecture

### Core Plugin Structure
- **Main Plugin File**: `Koha/Plugin/AutomateMarcImport.pm` - The primary Perl module containing all plugin logic
- **Configuration Template**: `Koha/Plugin/AutomateMarcImport/configure.tt` - Template Toolkit file for the admin interface
- **Release Scripts**: Node.js utilities for packaging and version management

### Key Components

#### Plugin Class (`AutomateMarcImport.pm`)
The main plugin inherits from `Koha::Plugins::Base` and implements:

- **Configuration Interface** (`configure` method) - Manages transport/profile settings via web interface
- **Nightly Cronjob** (`cronjob_nightly` method) - Automated file retrieval and staging
- **Intranet JavaScript** (`intranet_js` method) - Displays alerts for staged imports on main page

#### Data Flow
1. Plugin stores settings as JSON in Koha's plugin_data table
2. Settings link SFTP transports to import batch profiles with optional filename filters
3. Nightly cronjob processes each configured transport:
   - Connects to SFTP server
   - Lists files in download directory
   - Filters for .mrc/.mrcx/.xml files
   - Checks modification times to avoid re-processing
   - Downloads files to plugin directory
   - Stages using appropriate profile based on filename matching

#### Key Dependencies
- `Koha::File::Transports` - SFTP server management
- `Koha::ImportBatchProfiles` - MARC import profiles
- `C4::ImportBatch` - Core MARC staging functionality
- `Koha::UploadedFile` - File handling

#### Settings Management
Settings are stored with incremental IDs and referenced via `selected_setting_ids` list. Each setting contains:
- Transport ID (SFTP server)
- Profile ID (import batch profile)
- Filename patterns (optional, defaults applied if empty)

#### File Processing Logic
Files are matched to profiles by:
1. Exact filename match (case-insensitive)
2. Fallback to default profile for transport if no filename match
3. Support for .mrc, .mrcx, and .xml extensions only

## Plugin Packaging

The plugin uses a custom build system:
- `release_kpz.sh` creates a .kpz (zip) file containing the Koha/ directory
- Version validation ensures plugin version has been incremented
- Git tagging and remote pushing handled automatically
- Remote validation prevents pushing to template repository