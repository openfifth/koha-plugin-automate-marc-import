# Koha Plugin: Automate MARC Import

A Koha plugin to automate the import and staging of MARC files by enabling nightly retrieval via SFTP/FTP from vendor sites. Features include MD5-based file deduplication, automatic archiving of processed files, MARC modification template support, and optional auto-commit for automated importing.

## Features

- **Automated MARC Import**: Nightly retrieval of MARC files from configured SFTP/FTP servers
- **Flexible File Matching**: Configure import rules using regular-expression filename patterns
- **MD5 Deduplication**: Prevents reprocessing of identical files
- **Auto-Commit Option**: Automatically commit staged records without manual review
- **Framework Selection**: Configure bibliographic frameworks for new and replacement records when auto-committing
- **Archive Management**: Per-setting archive directories with configurable retention policy
- **MARC Modification Support**: Apply MARC modification templates during import
- **Multi-Format Support**: Handles ISO2709 (.mrc, .mrcx) and MARCXML (.xml, .marcxml) files
- **Duplicate Detection**: Configurable record matching and overlay rules
- **Staff Notifications**: Alerts staff when staged files are ready for review

## Requirements

- Koha 25.11.00.000 or later (requires Koha::File::Transport infrastructure)
- Configured transport servers (Administration > SFTP Servers)
- Import batch profiles configured (Tools > Import Batch Profiles)
- Sufficient disk space for file downloads and archives
- Cron job configured to run nightly plugin tasks

## Installation

1. Download the latest `.kpz` file from the releases
2. Go to Koha Staff Interface > Administration > Plugins
3. Click "Upload plugin"
4. Select the downloaded `.kpz` file
5. Enable the plugin
6. Configure the plugin settings (see Configuration section)

## Configuration

### Transport Server Setup

Before configuring the plugin, ensure transport servers are properly configured:

1. Go to **Administration > SFTP Servers**
2. Click "Add a new SFTP server" or "New FTP server"
3. Fill in the connection details:
   - **Server name**: A descriptive name for the server
   - **Host**: The server hostname or IP address
   - **Port**: Connection port (default 22 for SFTP, 21 for FTP)
   - **Username**: Login username with read access to MARC files
   - **Password**: Login password (stored securely)
   - **Download directory**: Directory path on remote server containing MARC files
4. Test the connection to ensure it works
5. Save the configuration

### Import Batch Profile Setup

Create or configure import batch profiles that define how MARC records are processed:

1. Go to **Cataloging > Stage MARC records for import**
2. Upload a MARC file to allow the creation of an import profile
3. Configure the import settings:
   - **Record type**: Biblio, Authority, or Holdings
   - **MARC format**: ISO2709 or MARCXML
   - **Character encoding**: UTF-8, MARC8, etc.
   - **MARC modification template**: Optional template to modify records during import
   - **Record matching rule**: How to match incoming records to existing ones
   - **Actions**: What to do with matches, non-matches, and items
4. Add a **Profile name** and click 'Save the profile'

### Plugin Configuration

Configure the plugin to connect transport servers with import profiles:

1. Go to **Tools > Automate MARC Import** (under Plugins section)
2. Click "New Automate MARC Import Setting"
3. Configure the automation rule:
   - **Transport server**: Select the configured SFTP/FTP server
   - **Import profile**: Select the batch profile to use for files from this server
   - **Filename patterns**: Optional regular expressions to match specific files (one per line)
     - Leave blank to process all supported MARC files from the server
     - Patterns are Perl-compatible regular expressions, matched case-insensitively
     - Only the part of the filename **before its first dot** is compared — the file extension, and anything after any later dots, is not visible to these patterns
     - Simple examples (still work exactly like plain text): `daily_update`, `weekly_marc`, `vendor_export`, `ebooks`
     - Regex examples: `^dispatch` (starts with), `_final$` (ends with, before the extension), `daily|weekly` (either), `report_\d{4}` (four digits)
     - Characters with special regex meaning (`. * + ? ^ $ ( ) [ ] { } | \`) must be escaped with a backslash to match them literally, e.g. `report\[2024\]`
     - See the [perlre documentation](https://perldoc.perl.org/perlre) for full syntax
   - **Auto-commit**: Enable to automatically commit staged records (bypass manual review)
   - **Framework options** (when auto-commit is enabled):
     - **New record framework**: Bibliographic framework to use for newly created records (default: Default framework)
     - **Replacement record framework**: Framework to use when overlaying existing records
       - "Keep original framework" preserves the existing record's framework
       - "Default" uses the system default framework
       - Or select a specific framework
4. Save the setting
5. Repeat for additional transport servers/profiles as needed

### Archive Retention Settings

Configure archive retention to manage disk space:

1. Go to **Plugins > Manage Plugins**
2. Find "Automate MARC Import" and click **Configure**
3. Set the **Archive retention count**:
   - Default: **10** files per import setting
   - Maximum: **100** files
   - Set to **0** to disable archiving (files deleted after processing)
4. Click "Save Configuration"

**Note**: Each import setting has its own archive directory (`Archive/{setting_id}/`). The retention count applies independently to each setting's archive. When the limit is exceeded, the oldest files are automatically deleted.

## Usage

### Nightly Automated Processing

The plugin runs automatically as part of Koha's nightly cron jobs:

1. **Connection**: Connects to each configured transport server
2. **File Discovery**: Lists files in the configured download directory
3. **File Filtering**: Identifies supported MARC files (.mrc, .mrcx, .xml, .marcxml)
4. **Deduplication**: Skips files that haven't changed since last run or are duplicates
5. **Download**: Retrieves new MARC files to local storage
6. **Staging**: Parses and stages MARC records using configured profiles
7. **Optional Commit**: Automatically commits records if auto-commit is enabled
8. **Archiving**: Moves processed files to per-setting archive directory
9. **Retention**: Deletes oldest archived files when retention limit is exceeded
10. **Cleanup**: Removes temporary files

### Manual Review Workflow (When Auto-Commit Disabled)

When auto-commit is disabled, staged records require manual review:

1. **Notifications**: Check the main staff page for alerts about staged files
2. **Review Staged Batches**: Go to **Cataloging > Manage Staged MARC Records**
3. **Inspect Records**: Review imported records, check for errors or issues
4. **Resolve Duplicates**: Handle record matches according to configured rules
5. **Commit or Revert**: Commit valid records or revert the batch if needed

### Common Workflows for Librarians

#### Monitoring Daily Vendor Updates

- Configure transport servers for each vendor providing MARC updates
- Set up filename patterns to match daily/weekly update files
- Use auto-commit for trusted, high-quality vendor data
- Monitor staff interface notifications for any staging issues
- Review committed records periodically to ensure data quality

#### Managing Multiple Data Sources

- Create separate import profiles for different types of records (biblio, authority, holdings)
- Use filename patterns to route files to appropriate profiles
- Configure different overlay rules for different data sources
- Set up separate transport servers for different vendors or data feeds

#### Quality Control and Error Handling

- Disable auto-commit for new data sources initially
- Review staged records for data quality and consistency
- Check MARC modification templates are working as expected
- Monitor logs for parsing errors or connection issues
- Use the archive directory to review processed files if needed

### Common Workflows for Administrators

#### Setting Up New Vendor Connections

- Obtain connection credentials from vendors
- Configure transport server settings in Koha
- Test connections and file access permissions
- Create appropriate import batch profiles
- Configure plugin rules with appropriate filename patterns
- Test with sample files before enabling auto-commit

#### System Maintenance and Monitoring

- Configure archive retention count to manage disk space automatically
- Monitor disk space usage for downloads and archives
- Review per-setting archive directories (`Archive/{setting_id}/`) periodically
- Check cron job logs for nightly processing status
- Update credentials when vendor passwords change
- Review and update import profiles as cataloging rules evolve

#### Troubleshooting Data Issues

- Use archived files to investigate processing problems
- Check MD5 hashes to verify file integrity
- Review import batch logs for parsing errors
- Test modified import profiles with archived files
- Coordinate with vendors for file format or content issues

## Troubleshooting

### Connection Issues

**Problem**: "Failed to connect to transport server"

- **Solution**: Check server configuration (host, port, credentials)
- **Solution**: Verify server is online and accessible from Koha server
- **Solution**: Confirm firewall allows connections to the server/port
- **Solution**: Test connection manually using command line tools (ssh, ftp)

**Problem**: "Authentication failed"

- **Solution**: Verify username and password are correct
- **Solution**: Check if account is locked or expired
- **Solution**: Confirm authentication method supported by server

### File Processing Issues

**Problem**: "No supported MARC files found"

- **Solution**: Verify download directory path is correct
- **Solution**: Check file extensions are supported (.mrc, .mrcx, .xml, .marcxml)
- **Solution**: Ensure files have read permissions for the transport user
- **Solution**: Check filename patterns match actual file names

**Problem**: "MARC parsing failed"

- **Solution**: Verify MARC file format matches profile configuration (ISO2709 vs MARCXML)
- **Solution**: Check character encoding settings
- **Solution**: Review MARC records for structural issues
- **Solution**: Contact vendor if files are corrupted

**Problem**: "Failed to stage records"

- **Solution**: Check import batch profile configuration
- **Solution**: Verify MARC modification template syntax
- **Solution**: Ensure sufficient database permissions
- **Solution**: Check available disk space for staging

### Duplicate and Matching Issues

**Problem**: Records not matching as expected

- **Solution**: Review record matching rules in import profile
- **Solution**: Check MARC tag/field mappings for matching criteria
- **Solution**: Verify record types (biblio, authority, holdings) are correct

**Problem**: Unexpected duplicate detection

- **Solution**: Review overlay action settings (ignore vs replace)
- **Solution**: Check matching thresholds and required fields
- **Solution**: Examine sample records to understand matching behavior

### Performance Issues

**Problem**: Nightly processing takes too long

- **Solution**: Enable auto-commit to reduce manual review time
- **Solution**: Split large files into smaller batches
- **Solution**: Optimize MARC modification templates
- **Solution**: Consider processing fewer files per night

**Problem**: Large archive directory

- **Solution**: Reduce the archive retention count in plugin configuration
- **Solution**: Set retention to 0 to disable archiving entirely
- **Solution**: Manually clean up old per-setting archive directories (`Archive/{setting_id}/`)
- **Solution**: Move old archives to long-term storage

### Configuration Issues

**Problem**: Settings not saving

- **Solution**: Check form validation errors
- **Solution**: Ensure transport servers and profiles exist
- **Solution**: Verify user has tools permissions (tools module access)

**Problem**: "Filename pattern is not a valid regular expression" / "not allowed: embedded code blocks"

- **Solution**: Filename patterns are Perl-compatible regular expressions, one per line. Check each line compiles as a regex — see the [perlre documentation](https://perldoc.perl.org/perlre).
- **Solution**: Escape characters with special regex meaning (`. * + ? ^ $ ( ) [ ] { } | \`) with a backslash if you want them matched literally, e.g. `report\[2024\]`. Remember only the part of the filename before its first dot is ever compared.
- **Solution**: Patterns containing `(?{ ... })` or `(??{ ... })` are always rejected — these embed executable code in a regex and are never valid here.

**Problem**: Plugin not running in cron

- **Solution**: Check cron job configuration includes plugin execution
- **Solution**: Verify plugin is enabled
- **Solution**: Review cron logs for execution errors

### Getting Help

If you encounter issues not covered here:

1. Check Koha logs for detailed error messages (`/var/log/koha/koha.log`)
2. Review plugin-specific logs in the staff interface
3. Check archived files for processing history
4. Contact your Koha system administrator
5. Report bugs via the project repository

## Building from Source

```bash
# Install dependencies (if not already installed)
npm install

# Create a release package
npm run release
```

This will create a `koha-plugin-automate-marc-import-vX.Y.Z.kpz` file.

## Version Management

```bash
# Increment patch version (1.0.0 -> 1.0.1)
npm run version:patch

# Increment minor version (1.0.0 -> 1.1.0)
npm run version:minor

# Increment major version (1.0.0 -> 2.0.0)
npm run version:major
```

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Author

Open Fifth

