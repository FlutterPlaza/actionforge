#!/usr/bin/env bats
# Tests for resolve_labels()

setup() {
  load '../test_helper/common_setup'
  # Clear RUNNER_LABELS before each test
  unset RUNNER_LABELS
}

@test "Docker mode sets Linux labels" {
  MODE="docker"
  OS="osx"
  ARCH="arm64"

  resolve_labels

  assert_equal "$RUNNER_LABELS" "ubuntu-latest,ubuntu-22.04,ubuntu-24.04,self-hosted,linux,x64"
}

@test "Bare mode macOS sets macOS labels" {
  MODE="bare"
  OS="osx"
  ARCH="arm64"

  resolve_labels

  assert_equal "$RUNNER_LABELS" "macos-latest,macos-14,self-hosted,macos,arm64"
}

@test "Bare mode Linux sets Linux labels" {
  MODE="bare"
  OS="linux"
  ARCH="x64"

  resolve_labels

  assert_equal "$RUNNER_LABELS" "ubuntu-latest,ubuntu-22.04,ubuntu-24.04,self-hosted,linux,x64"
}

@test "Pre-set labels are preserved" {
  MODE="docker"
  OS="osx"
  ARCH="arm64"
  RUNNER_LABELS="custom-label-1,custom-label-2"

  resolve_labels

  assert_equal "$RUNNER_LABELS" "custom-label-1,custom-label-2"
}
