# Changelog

All notable changes to ActionForge are documented in this file.

## [1.4.6] — 2026-08-21

### Fixed
- **Autoscaler no longer churns runners or disrupts running jobs.** The pool
  could oscillate (e.g. `5→3→2→5`) as demand fluctuated, and each scale-down
  (`docker compose --scale`) removes containers by index — occasionally tearing
  down a runner that had just picked up a job. The autoscaler now scales **up**
  immediately but scales **down** only after `AF_SCALE_DOWN_DELAY` consecutive
  ticks (default 3) of lower demand, so transient dips no longer shrink the
  pool. `desired` is still clamped to at least the busy-runner count.

## [1.4.5] — 2026-08-21

### Added
- **Queue-based autoscaling** (Docker mode): `--autoscale` scales the runner
  pool up and down to match GitHub Actions demand, between `--min` (default 1)
  and `--max` (default 8), with `--interval` (default 20s). A host-side poll
  loop (`autoscale.sh`) counts the self-hosted jobs in flight — busy runners
  plus queued runs on the org's private repos — and adjusts
  `docker compose --scale runner=N` each tick. Since runners are ephemeral,
  scaling down just drops idle replicas; in-progress jobs finish via the
  compose grace period. The daemon writes a pid/log to `~/.actionforge/` and is
  stopped by `actionforge --teardown`.

## [1.4.4] — 2026-08-21

### Fixed
- Runner disk no longer grows unbounded across jobs. The runner is ephemeral
  (one job per container start), but `restart: unless-stopped` restarts the
  *same* container rather than recreating it, so `_work` (checkouts, the tool
  cache, build output — often GBs per job) accumulated across restarts and could
  fill the host's Docker disk (`ENOSPC` mid-job, e.g. while unpacking an SDK).
  The entrypoint now wipes `_work` on each start, making every job the clean
  slate the ephemeral model already promises. Set `ACTIONFORGE_KEEP_WORK=1` to
  opt out (e.g. to keep a tool cache across jobs), accepting the disk-growth
  risk.

### Changed
- Bumped the bundled GitHub Actions runner to **2.336.0** (from 2.321.0), which
  supports `node24`-based actions (older runners reject them).

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
