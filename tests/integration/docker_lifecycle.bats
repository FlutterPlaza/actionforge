#!/usr/bin/env bats
# Integration tests for Docker runner lifecycle
# Requires: Docker running, GH_PAT environment variable for live tests

COMPOSE_PROJECT="actionforge-test"
PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  load "${PROJECT_ROOT}/tests/test_helper/bats-support/load"
  load "${PROJECT_ROOT}/tests/test_helper/bats-assert/load"
}

_docker_available() {
  command -v docker &>/dev/null && docker info &>/dev/null 2>&1
}

setup_file() {
  if ! _docker_available; then
    skip "Docker is not available"
  fi

  # Create isolated temp directory with all required files
  export TEST_DIR="$(mktemp -d)"
  cp "${BATS_TEST_DIRNAME}/../../Dockerfile" "$TEST_DIR/"
  cp "${BATS_TEST_DIRNAME}/../../entrypoint.sh" "$TEST_DIR/"

  # Copy docker-compose.yml but override restart policy for test predictability
  # (restart: unless-stopped would cause infinite restart loops in failure tests)
  sed 's/restart: unless-stopped/restart: "no"/' \
    "${BATS_TEST_DIRNAME}/../../docker-compose.yml" > "${TEST_DIR}/docker-compose.yml"

  # Write .env for docker compose
  cat > "${TEST_DIR}/.env" <<EOF
GH_ORG=${GH_ORG:-test-org}
GH_REPO=${GH_REPO:-}
GH_PAT=${GH_PAT:-}
RUNNER_LABELS=ubuntu-latest,self-hosted,linux,x64
EOF
  chmod 600 "${TEST_DIR}/.env"
}

teardown_file() {
  if [[ -n "${TEST_DIR:-}" && -d "${TEST_DIR:-}" ]]; then
    docker compose -p "$COMPOSE_PROJECT" -f "${TEST_DIR}/docker-compose.yml" down --remove-orphans 2>/dev/null || true
    rm -rf "$TEST_DIR"
  fi
}

teardown() {
  if [[ -n "${TEST_DIR:-}" && -d "${TEST_DIR:-}" ]]; then
    docker compose -p "$COMPOSE_PROJECT" -f "${TEST_DIR}/docker-compose.yml" down --remove-orphans 2>/dev/null || true
  fi
}

@test "Docker image builds successfully" {
  _docker_available || skip "Docker is not available"

  run docker compose -p "$COMPOSE_PROJECT" -f "${TEST_DIR}/docker-compose.yml" build
  assert_success
}

@test "Entrypoint is executable in image" {
  _docker_available || skip "Docker is not available"

  # Ensure image is built
  docker compose -p "$COMPOSE_PROJECT" -f "${TEST_DIR}/docker-compose.yml" build

  run docker run --rm --entrypoint="" "${COMPOSE_PROJECT}-runner" test -x /entrypoint.sh
  assert_success
}

@test "Runner container starts" {
  _docker_available || skip "Docker is not available"
  [[ -n "${GH_PAT:-}" ]] || skip "GH_PAT not set — skipping live container test"

  docker compose -p "$COMPOSE_PROJECT" -f "${TEST_DIR}/docker-compose.yml" --env-file "${TEST_DIR}/.env" up -d

  # Wait up to 30s for container to be running
  local waited=0
  while [[ $waited -lt 30 ]]; do
    if docker compose -p "$COMPOSE_PROJECT" -f "${TEST_DIR}/docker-compose.yml" ps --format json 2>/dev/null | grep -q '"running"'; then
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  run docker compose -p "$COMPOSE_PROJECT" -f "${TEST_DIR}/docker-compose.yml" ps --format json
  assert_success
  assert_output --partial "running"
}

@test "Runner registers successfully" {
  _docker_available || skip "Docker is not available"
  [[ -n "${GH_PAT:-}" ]] || skip "GH_PAT not set — skipping registration test"

  docker compose -p "$COMPOSE_PROJECT" -f "${TEST_DIR}/docker-compose.yml" --env-file "${TEST_DIR}/.env" up -d

  # Wait up to 60s for registration message in logs
  local waited=0
  local found=false
  while [[ $waited -lt 60 ]]; do
    if docker compose -p "$COMPOSE_PROJECT" -f "${TEST_DIR}/docker-compose.yml" logs 2>/dev/null | grep -q "Runner registered. Waiting for jobs..."; then
      found=true
      break
    fi
    sleep 3
    waited=$((waited + 3))
  done

  assert_equal "$found" "true"
}

@test "Teardown stops all containers" {
  _docker_available || skip "Docker is not available"
  [[ -n "${GH_PAT:-}" ]] || skip "GH_PAT not set — skipping teardown test"

  docker compose -p "$COMPOSE_PROJECT" -f "${TEST_DIR}/docker-compose.yml" --env-file "${TEST_DIR}/.env" up -d
  sleep 5

  run docker compose -p "$COMPOSE_PROJECT" -f "${TEST_DIR}/docker-compose.yml" down
  assert_success

  # Verify no containers remain for this project
  run docker compose -p "$COMPOSE_PROJECT" -f "${TEST_DIR}/docker-compose.yml" ps -q
  assert_output ""
}

@test "Missing PAT fails gracefully" {
  _docker_available || skip "Docker is not available"

  # Write .env with empty PAT and minimal retries so the test doesn't take forever
  cat > "${TEST_DIR}/.env" <<EOF
GH_ORG=${GH_ORG:-test-org}
GH_REPO=${GH_REPO:-}
GH_PAT=
RUNNER_LABELS=ubuntu-latest,self-hosted,linux,x64
MAX_RETRIES=1
FAIL_COOLDOWN=0
EOF

  docker compose -p "$COMPOSE_PROJECT" -f "${TEST_DIR}/docker-compose.yml" --env-file "${TEST_DIR}/.env" up -d

  # Wait for the error message to appear in logs (container may still be
  # sleeping in the cooldown period, so check logs rather than container state)
  local waited=0
  local found=false
  while [[ $waited -lt 60 ]]; do
    if docker compose -p "$COMPOSE_PROJECT" -f "${TEST_DIR}/docker-compose.yml" logs 2>/dev/null | grep -q "Failed to get registration token"; then
      found=true
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  assert_equal "$found" "true"
}
