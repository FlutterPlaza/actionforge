#!/usr/bin/env bats
# Tests for autoscale.sh — af_clamp (pure, I/O-free)

setup() {
  load '../test_helper/common_setup'
  source "${PROJECT_ROOT}/autoscale.sh"
  set +eu
}

@test "clamp: below min → min" {
  AF_MIN=1; AF_MAX=8
  assert_equal "$(af_clamp 0)" "1"
}

@test "clamp: above max → max" {
  AF_MIN=1; AF_MAX=8
  assert_equal "$(af_clamp 12)" "8"
}

@test "clamp: within range → unchanged" {
  AF_MIN=1; AF_MAX=8
  assert_equal "$(af_clamp 4)" "4"
}

@test "clamp: at the min boundary" {
  AF_MIN=2; AF_MAX=6
  assert_equal "$(af_clamp 2)" "2"
}

@test "clamp: at the max boundary" {
  AF_MIN=2; AF_MAX=6
  assert_equal "$(af_clamp 6)" "6"
}

@test "clamp: min=0 allows scaling to zero" {
  AF_MIN=0; AF_MAX=8
  assert_equal "$(af_clamp 0)" "0"
}

@test "clamp: max=8 is the documented ceiling" {
  AF_MIN=1; AF_MAX=8
  assert_equal "$(af_clamp 100)" "8"
}
