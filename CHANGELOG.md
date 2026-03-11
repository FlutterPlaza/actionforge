# Changelog

All notable changes to ActionForge are documented in this file.

## [1.4.3] — 2026-03-11

### Added
- `--platform` flag for Docker mode — allows specifying the Docker platform
  (e.g., `--platform=linux/amd64`) for cross-architecture builds
- `gh auth token` fallback — when no PAT is provided, automatically uses
  the GitHub CLI's authenticated token if available

### Changed
- Dockerfile: added `sudo`, `ninja-build`, and `pkg-config` to pre-installed
  dependencies for CI workflows that build native code
- Docker resource limits increased (4 CPUs / 8GB per runner, up from 2 / 4GB)

## [1.4.2] — 2026-03-09

### Fixed
- All ShellCheck warnings resolved in setup.sh

## [1.4.1] — 2026-03-09

### Fixed
- Skip unresolvable GitHub Actions expressions in workflow version detection

## [1.4.0] — 2026-03-08

### Added
- Workflow-driven SDK setup — automatically detects Flutter/Dart/Node versions
  from your repository's workflow files
- Auto-respawn — runners automatically restart after completing a job
- Secure PAT handling with 600 file permissions
- Interactive live dashboard with runner controls
- Bare-metal persistent mode (`--persistent` flag)
- Homebrew tap distribution (`brew install flutterplaza/tap/actionforge`)
