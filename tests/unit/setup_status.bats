#!/usr/bin/env bats
# Tests for --status dashboard and related functions

setup() {
  load '../test_helper/common_setup'
}

@test "--status calls show_status" {
  # Override show_status to verify it gets called
  show_status() { echo "SHOW_STATUS_CALLED"; }
  export -f show_status
  run main --status
  assert_success
  assert_output --partial "SHOW_STATUS_CALLED"
}

@test "status_detect_runners finds nothing on clean machine" {
  # On a test machine with no runners, both flags should be false
  ACTIONFORGE_WORKDIR="/tmp/actionforge-test-nonexistent-$$"
  run status_detect_runners
  assert_success
  assert_equal "$HAS_DOCKER_RUNNERS" "false"
  assert_equal "$HAS_BARE_RUNNERS" "false"
}

@test "status_render shows 'No runners found' when empty" {
  ACTIONFORGE_WORKDIR="/tmp/actionforge-test-nonexistent-$$"
  CONFIG_FILE="/tmp/actionforge-test-nonexistent-$$.conf"
  run status_render
  assert_success
  assert_output --partial "No runners found"
}

@test "status_render includes dashboard header" {
  ACTIONFORGE_WORKDIR="/tmp/actionforge-test-nonexistent-$$"
  CONFIG_FILE="/tmp/actionforge-test-nonexistent-$$.conf"
  run status_render
  assert_success
  assert_output --partial "Runner Dashboard"
}

@test "--help includes --status" {
  run main --help
  assert_success
  assert_output --partial "--status"
}

@test "bare_monitor_menu shows quit when no runners" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  run bare_monitor_menu "$tmpdir"
  assert_success
  assert_output --partial "[q] quit"
  assert_output --partial "[b] background"
  refute_output --partial "stop runner"
  rm -rf "$tmpdir"
}

@test "bare_monitor_menu shows runner count controls" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "${tmpdir}/runner-1" "${tmpdir}/runner-2" "${tmpdir}/runner-3"
  run bare_monitor_menu "$tmpdir"
  assert_success
  assert_output --partial "[1-3] stop runner"
  assert_output --partial "[a] stop all"
  assert_output --partial "[b] background"
  assert_output --partial "[q] quit"
  rm -rf "$tmpdir"
}

@test "bare_monitor_menu shows Controls header" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  run bare_monitor_menu "$tmpdir"
  assert_success
  assert_output --partial "Controls"
  rm -rf "$tmpdir"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Workflow Flutter version detection tests
# ══════════════════════════════════════════════════════════════════════════════

@test "detect_workflow_flutter falls back to stable without GH_PAT" {
  GH_PAT=""
  GH_ORG="test-org"
  GH_REPO="test-repo"
  run detect_workflow_flutter
  assert_success
  assert_equal "$WORKFLOW_FLUTTER_VERSION" "stable"
}

@test "detect_workflow_flutter falls back to stable without GH_REPO" {
  GH_PAT="ghp_test"
  GH_ORG="test-org"
  GH_REPO=""
  run detect_workflow_flutter
  assert_success
  assert_equal "$WORKFLOW_FLUTTER_VERSION" "stable"
}

@test "detect_workflow_flutter falls back to stable without GH_ORG" {
  GH_PAT="ghp_test"
  GH_ORG=""
  GH_REPO="test-repo"
  run detect_workflow_flutter
  assert_success
  assert_equal "$WORKFLOW_FLUTTER_VERSION" "stable"
}

@test "detect_workflow_flutter _gh_file_content helper decodes base64" {
  # Stub curl to return a mock GitHub API response
  curl() {
    cat <<'JSON'
{"content": "eyJmbHV0dGVyU2RrVmVyc2lvbiI6ICIzLjI3LjAifQo="}
JSON
  }
  export -f curl
  GH_PAT="ghp_test"
  GH_ORG="test-org"
  GH_REPO="test-repo"
  run detect_workflow_flutter
  assert_success
  assert_output --partial "3.27.0"
  assert_output --partial "fvm_config.json"
}

@test "detect_workflow_flutter parses fvm_config.json" {
  # Base64 of: {"flutterSdkVersion": "3.24.5"}
  local fvm_b64
  fvm_b64=$(echo -n '{"flutterSdkVersion": "3.24.5"}' | base64)
  curl() {
    local url="${*: -1}"
    if [[ "$url" == *".fvm/fvm_config.json"* ]]; then
      echo "{\"content\": \"${FVM_B64}\"}"
    else
      echo "{}"
    fi
  }
  export -f curl
  FVM_B64="$fvm_b64"
  export FVM_B64
  GH_PAT="ghp_test"
  GH_ORG="test-org"
  GH_REPO="test-repo"
  run detect_workflow_flutter
  assert_success
  assert_output --partial "3.24.5"
}

@test "detect_workflow_flutter parses subosito/flutter-action version" {
  # Workflow YAML with flutter-action
  local wf_yaml
  wf_yaml=$(cat <<'YAML'
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.22.0'
          channel: 'stable'
      - run: flutter test
YAML
)
  local wf_b64
  wf_b64=$(echo -n "$wf_yaml" | base64)

  curl() {
    local url="${*: -1}"
    if [[ "$url" == *".fvm/fvm_config.json"* ]]; then
      echo '{"message": "Not Found"}'
    elif [[ "$url" == *".github/workflows"* ]] && [[ "$url" != *".yml"* ]]; then
      echo '[{"name": "ci.yml"}]'
    elif [[ "$url" == *"ci.yml"* ]]; then
      echo "{\"content\": \"${WF_B64}\"}"
    else
      echo "{}"
    fi
  }
  export -f curl
  WF_B64="$wf_b64"
  export WF_B64
  GH_PAT="ghp_test"
  GH_ORG="test-org"
  GH_REPO="test-repo"
  run detect_workflow_flutter
  assert_success
  assert_output --partial "3.22.0"
  assert_output --partial "flutter-action"
}

@test "detect_workflow_flutter parses dart-lang/setup-dart" {
  local wf_yaml
  wf_yaml=$(cat <<'YAML'
name: Dart CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: '3.6.0'
      - run: dart test
YAML
)
  local wf_b64
  wf_b64=$(echo -n "$wf_yaml" | base64)

  curl() {
    local url="${*: -1}"
    if [[ "$url" == *".fvm/fvm_config.json"* ]]; then
      echo '{"message": "Not Found"}'
    elif [[ "$url" == *".github/workflows"* ]] && [[ "$url" != *".yml"* ]]; then
      echo '[{"name": "dart.yml"}]'
    elif [[ "$url" == *"dart.yml"* ]]; then
      echo "{\"content\": \"${WF_B64}\"}"
    else
      echo "{}"
    fi
  }
  export -f curl
  WF_B64="$wf_b64"
  export WF_B64
  GH_PAT="ghp_test"
  GH_ORG="test-org"
  GH_REPO="test-repo"
  run detect_workflow_flutter
  assert_success
  assert_output --partial "3.6.0"
  assert_output --partial "setup-dart"
}

@test "detect_workflow_flutter parses pubspec.yaml flutter constraint" {
  local pubspec_yaml
  pubspec_yaml=$(cat <<'YAML'
name: my_app
environment:
  flutter: ">=3.19.0 <4.0.0"
  sdk: ">=3.3.0 <4.0.0"
YAML
)
  local pub_b64
  pub_b64=$(echo -n "$pubspec_yaml" | base64)

  curl() {
    local url="${*: -1}"
    if [[ "$url" == *".fvm/fvm_config.json"* ]]; then
      echo '{"message": "Not Found"}'
    elif [[ "$url" == *".github/workflows"* ]]; then
      echo '[]'
    elif [[ "$url" == *"pubspec.yaml"* ]]; then
      echo "{\"content\": \"${PUB_B64}\"}"
    else
      echo "{}"
    fi
  }
  export -f curl
  PUB_B64="$pub_b64"
  export PUB_B64
  GH_PAT="ghp_test"
  GH_ORG="test-org"
  GH_REPO="test-repo"
  run detect_workflow_flutter
  assert_success
  assert_output --partial "3.19.0"
  assert_output --partial "pubspec.yaml"
}

@test "detect_workflow_flutter pubspec dart-only sdk constraint" {
  local pubspec_yaml
  pubspec_yaml=$(cat <<'YAML'
name: dart_package
environment:
  sdk: ">=3.3.0 <4.0.0"
YAML
)
  local pub_b64
  pub_b64=$(echo -n "$pubspec_yaml" | base64)

  curl() {
    local url="${*: -1}"
    if [[ "$url" == *".fvm/fvm_config.json"* ]]; then
      echo '{"message": "Not Found"}'
    elif [[ "$url" == *".github/workflows"* ]]; then
      echo '[]'
    elif [[ "$url" == *"pubspec.yaml"* ]]; then
      echo "{\"content\": \"${PUB_B64}\"}"
    else
      echo "{}"
    fi
  }
  export -f curl
  PUB_B64="$pub_b64"
  export PUB_B64
  GH_PAT="ghp_test"
  GH_ORG="test-org"
  GH_REPO="test-repo"
  run detect_workflow_flutter
  assert_success
  assert_output --partial "3.3.0"
}

@test "detect_workflow_flutter skips GitHub expressions in flutter-version" {
  # Workflow YAML where flutter-version is a GitHub expression (unresolvable)
  local wf_yaml
  wf_yaml=$(cat <<'YAML'
name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: ${{needs.get-flutter-version.outputs.flutter_version}}
      - run: flutter test
YAML
)
  local wf_b64
  wf_b64=$(echo -n "$wf_yaml" | base64)

  curl() {
    local url="${*: -1}"
    if [[ "$url" == *".fvm/fvm_config.json"* ]]; then
      echo '{"message": "Not Found"}'
    elif [[ "$url" == *".github/workflows"* ]] && [[ "$url" != *".yml"* ]]; then
      echo '[{"name": "ci.yml"}]'
    elif [[ "$url" == *"ci.yml"* ]]; then
      echo "{\"content\": \"${WF_B64}\"}"
    elif [[ "$url" == *"pubspec.yaml"* ]]; then
      echo '{"message": "Not Found"}'
    else
      echo "{}"
    fi
  }
  export -f curl
  WF_B64="$wf_b64"
  export WF_B64
  GH_PAT="ghp_test"
  GH_ORG="test-org"
  GH_REPO="test-repo"
  run detect_workflow_flutter
  assert_success
  # Should NOT use the expression literal — should fall back to stable
  assert_output --partial "stable"
  refute_output --partial "needs.get-flutter-version"
}

@test "detect_workflow_flutter falls back to stable when API returns nothing useful" {
  curl() {
    echo '{"message": "Not Found"}'
  }
  export -f curl
  GH_PAT="ghp_test"
  GH_ORG="test-org"
  GH_REPO="test-repo"
  run detect_workflow_flutter
  assert_success
  assert_output --partial "stable"
}

@test "detect_workflow_flutter priority: fvm_config.json wins over workflow files" {
  # Both fvm_config.json and workflow file exist — fvm_config.json should win
  local fvm_b64
  fvm_b64=$(echo -n '{"flutterSdkVersion": "3.24.0"}' | base64)
  local wf_yaml
  wf_yaml=$(cat <<'YAML'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.22.0'
YAML
)
  local wf_b64
  wf_b64=$(echo -n "$wf_yaml" | base64)

  curl() {
    local url="${*: -1}"
    if [[ "$url" == *".fvm/fvm_config.json"* ]]; then
      echo "{\"content\": \"${FVM_B64}\"}"
    elif [[ "$url" == *".github/workflows"* ]] && [[ "$url" != *".yml"* ]]; then
      echo '[{"name": "ci.yml"}]'
    elif [[ "$url" == *"ci.yml"* ]]; then
      echo "{\"content\": \"${WF_B64}\"}"
    else
      echo "{}"
    fi
  }
  export -f curl
  FVM_B64="$fvm_b64"
  WF_B64="$wf_b64"
  export FVM_B64 WF_B64
  GH_PAT="ghp_test"
  GH_ORG="test-org"
  GH_REPO="test-repo"
  run detect_workflow_flutter
  assert_success
  # Should detect 3.24.0 from fvm_config.json, NOT 3.22.0 from workflow
  assert_output --partial "3.24.0"
  assert_output --partial "fvm_config.json"
  refute_output --partial "3.22.0"
}
