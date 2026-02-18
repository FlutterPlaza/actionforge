#!/usr/bin/env bats
# Tests for CLI flags (--version, --help, -v, -h)

setup() {
  load '../test_helper/common_setup'
}

@test "--version prints version and exits 0" {
  run main --version
  assert_success
  assert_output --partial "ActionForge"
  assert_output --partial "$ACTIONFORGE_VERSION"
}

@test "--help prints usage and exits 0" {
  run main --help
  assert_success
  assert_output --partial "Usage: actionforge"
}

@test "-v is alias for --version" {
  run main -v
  assert_success
  assert_output --partial "ActionForge"
  assert_output --partial "$ACTIONFORGE_VERSION"
}

@test "-h is alias for --help" {
  run main -h
  assert_success
  assert_output --partial "Usage: actionforge"
}
