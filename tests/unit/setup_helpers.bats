#!/usr/bin/env bats
# Tests for info(), ok(), warn(), fail(), banner()

setup() {
  load '../test_helper/common_setup'
}

@test "info() prints message" {
  run info "hello world"
  assert_success
  assert_output --partial "hello world"
}

@test "ok() prints message" {
  run ok "all good"
  assert_success
  assert_output --partial "all good"
}

@test "warn() prints message" {
  run warn "watch out"
  assert_success
  assert_output --partial "watch out"
}

@test "fail() exits 1 with message" {
  run fail "something broke"
  assert_failure 1
  assert_output --partial "something broke"
}

@test "banner() prints ActionForge header" {
  run banner
  assert_success
  assert_output --partial "ActionForge"
  assert_output --partial "FlutterPlaza"
}
