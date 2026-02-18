#!/usr/bin/env bats
# Tests for detect_os()

setup() {
  load '../test_helper/common_setup'
}

@test "macOS Apple Silicon detection" {
  uname() {
    case "$1" in
      -s) echo "Darwin";;
      -m) echo "arm64";;
    esac
  }
  export -f uname

  run detect_os
  assert_success
  assert_output --partial "osx/arm64"
}

@test "macOS Intel detection" {
  uname() {
    case "$1" in
      -s) echo "Darwin";;
      -m) echo "x86_64";;
    esac
  }
  export -f uname

  run detect_os
  assert_success
  assert_output --partial "osx/x64"
}

@test "Linux x64 detection" {
  uname() {
    case "$1" in
      -s) echo "Linux";;
      -m) echo "x86_64";;
    esac
  }
  export -f uname

  run detect_os
  assert_success
  assert_output --partial "linux/x64"
}

@test "Linux arm64 detection" {
  uname() {
    case "$1" in
      -s) echo "Linux";;
      -m) echo "aarch64";;
    esac
  }
  export -f uname

  run detect_os
  assert_success
  assert_output --partial "linux/arm64"
}

@test "unsupported OS fails" {
  uname() {
    case "$1" in
      -s) echo "MINGW64_NT";;
      -m) echo "x86_64";;
    esac
  }
  export -f uname

  run detect_os
  assert_failure 1
  assert_output --partial "Unsupported OS"
}

@test "unsupported architecture fails" {
  uname() {
    case "$1" in
      -s) echo "Linux";;
      -m) echo "riscv64";;
    esac
  }
  export -f uname

  run detect_os
  assert_failure 1
  assert_output --partial "Unsupported architecture"
}

@test "RUNNER_PACKAGE is correct for Linux x64" {
  uname() {
    case "$1" in
      -s) echo "Linux";;
      -m) echo "x86_64";;
    esac
  }
  export -f uname

  detect_os
  assert_equal "$RUNNER_PACKAGE" "actions-runner-linux-x64-2.321.0.tar.gz"
}
