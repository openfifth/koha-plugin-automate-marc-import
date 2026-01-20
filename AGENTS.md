# AGENTS.md - Development Guidelines for koha-plugin-automate-marc-import

This document provides comprehensive guidelines for coding agents (such as yourself) working on the koha-plugin-automate-marc-import project. Follow these guidelines to maintain code quality, consistency, and best practices.

## Table of Contents

1. [Build, Lint, and Test Commands](#build-lint-and-test-commands)
2. [Code Style Guidelines](#code-style-guidelines)
   - [Perl Code Style](#perl-code-style)
   - [JavaScript/Node.js Code Style](#javascriptnodejs-code-style)
   - [HTML/Template Code Style](#htmltemplate-code-style)
   - [General Conventions](#general-conventions)

## Build, Lint, and Test Commands

### Testing

**Run all tests:**
```bash
export KOHA_PLUGIN_DIR=/path/to/plugin && prove t/
```

**Run a specific test file:**
```bash
export KOHA_PLUGIN_DIR=/path/to/plugin && prove t/00-load.t
```

**Run tests in CI environment:**
The project uses koha-testing-docker for testing. Tests are automatically run in GitHub Actions against multiple Koha versions (main, stable, oldstable).

### Building and Deployment

**Build plugin package (.kpz file):**
```bash
npm run release
```

**Version bumping:**
```bash
npm run version:patch  # For patch releases (1.0.0 -> 1.0.1)
npm run version:minor  # For minor releases (1.0.0 -> 1.1.0)
npm run version:major  # For major releases (1.0.0 -> 2.0.0)
```

**Create release with full workflow:**
```bash
npm run release:patch  # Bump version, commit, tag, and push
npm run release:minor
npm run release:major
```

### Code Quality

The project does not currently have dedicated linting tools configured. However, code should pass Perl syntax checks:

**Check Perl syntax:**
```bash
perl -c Koha/Plugin/Com/OpenFifth/AutomateMarcImport.pm
```

## Code Style Guidelines

### Perl Code Style

#### Package Structure and Imports

- Use `Modern::Perl` pragma at the top of all Perl files
- Group imports by category with comments:
  ```perl
  # Core Perl modules
  use Digest::MD5;
  use File::Basename qw(fileparse);

  # Koha modules
  use C4::Context;
  use Koha::Database;
  ```
- Use full module paths for Koha modules to avoid ambiguity
- Import only necessary functions from modules

#### Variable Naming

- Use lowercase with underscores for variables: `$variable_name`
- Use descriptive names that indicate purpose
- Prefix hash/array references with type hints when helpful: `%settings_hash`, `@transport_list`

#### Subroutine Structure

- Use 4-space indentation (following existing code)
- Use meaningful subroutine names with `snake_case`
- Document subroutine purpose with comments when not obvious
- Follow this parameter pattern:
  ```perl
  sub subroutine_name {
      my ($self, $param1, $param2) = @_;

      # Implementation
  }
  ```

#### Error Handling

- Use `Try::Tiny` for exception handling:
  ```perl
  try {
      # Risky operation
  } catch {
      $self->{logger}->error("Operation failed: $_");
  };
  ```
- Always log errors with appropriate log levels (error, warn, info)
- Use die() for fatal errors that should stop execution
- Return meaningful error messages from validation functions

#### Database Transactions

- Use Koha's database transaction pattern:
  ```perl
  my $schema = Koha::Database->new()->schema();
  my $result = $schema->storage->txn_do(sub {
      # Database operations
      return $data;
  });
  ```

#### Logging

- Use Koha::Logger for all logging:
  ```perl
  $self->{logger}->info("Informational message");
  $self->{logger}->error("Error message: $details");
  ```
- Log levels: trace, debug, info, warn, error
- Include relevant context in log messages

### JavaScript/Node.js Code Style

#### Module Structure

- Use ES5+ syntax compatible with Node.js
- Use `const` and `let` instead of `var`
- Use descriptive variable names in camelCase: `newVersion`, `packageJson`

#### Error Handling

- Use try-catch blocks for file operations
- Provide meaningful error messages
- Exit with appropriate codes for CLI tools

#### File Operations

- Use synchronous methods for simple scripts (like version bumping)
- Validate file existence before operations
- Use UTF-8 encoding for text files

#### Console Output

- Use `console.log()` for informational output
- Use `console.error()` for error messages
- Provide clear feedback for script operations

### HTML/Template Code Style

#### Template::Toolkit Structure

- Use proper indentation (2 spaces for HTML elements)
- Follow existing patterns for Koha template integration
- Use semantic HTML5 elements
- Include accessibility attributes where appropriate

#### JavaScript in Templates

- Use proper script tag placement
- Follow jQuery best practices (Koha standard)
- Include error handling in JavaScript functions
- Use descriptive variable names

#### Form Validation

- Use jQuery Validate plugin (Koha standard)
- Provide clear error messages
- Include required field indicators

### General Conventions

#### File Organization

- Keep related functionality together
- Use clear, descriptive filenames
- Follow existing directory structure:
  - `Koha/Plugin/Com/OpenFifth/` - Main plugin code
  - `t/` - Test files
  - Root level - Configuration and build files

#### Documentation

- Use inline comments for complex logic
- Document subroutine purposes when not obvious from name
- Keep README.md updated with major changes
- Update CHANGELOG.md for version releases

#### Security

- Validate all user inputs
- Sanitize file paths and names
- Use parameterized queries for database operations
- Log security-relevant events

#### Version Management

- Update both package.json and plugin file versions
- Update date_updated in plugin metadata
- Follow semantic versioning (major.minor.patch)
- Keep version numbers synchronized

#### Git Workflow

- Use descriptive commit messages
- Follow conventional commit format when possible
- Test changes before committing
- Use feature branches for new development

#### Code Reviews

- Ensure all tests pass
- Check for syntax errors
- Verify logging is appropriate
- Confirm error handling is robust
- Validate input sanitization

### Dependencies

**Runtime Dependencies:**
- Koha (ILMS)
- Perl modules: Modern::Perl, Try::Tiny, JSON, etc.
- Koha-specific modules: C4::*, Koha::* namespaces

**Development Dependencies:**
- Node.js (for version management scripts)
- koha-testing-docker (for CI testing)

### Environment Variables

- `KOHA_PLUGIN_DIR` - Required for running tests locally
- Standard Koha environment variables (automatically set in Koha context)

### Plugin-Specific Patterns

- Use plugin data storage for configuration persistence
- Implement proper plugin hooks (configure, cronjob_nightly, intranet_js)
- Follow Koha plugin architecture patterns
- Handle plugin directory creation and permissions properly

---

This document should be updated as the project evolves. When making changes to these guidelines, ensure they reflect the current codebase practices and maintain backward compatibility.</content>
<parameter name="filePath">/home/martin/Projects/koha-plugins/koha-plugin-automate-marc-import/AGENTS.md