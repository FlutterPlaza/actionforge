#!/usr/bin/env bash
# Common test setup — loaded by every BATS test file

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

load "${PROJECT_ROOT}/tests/test_helper/bats-support/load"
load "${PROJECT_ROOT}/tests/test_helper/bats-assert/load"

# Source setup.sh (safe because of the source guard — main() won't run)
source "${PROJECT_ROOT}/setup.sh"

# Undo set -euo pipefail from setup.sh:
#   -e would kill tests on any non-zero exit outside `run` blocks
#   -u would fail on unset variables common in test setup
set +eu
