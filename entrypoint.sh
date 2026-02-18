#!/usr/bin/env bash
# ============================================================================
#  ActionForge — Container Entrypoint
#  A FlutterPlaza Open-Source Product | https://flutterplaza.com
#  - Auto-registers with GitHub on startup
#  - Runs in ephemeral mode (clean slate per job)
#  - Deregisters on graceful shutdown
# ============================================================================
set -euo pipefail

# ── Resolve API endpoint ─────────────────────────────────────────────────────
if [[ -n "${GH_REPO:-}" ]]; then
  TOKEN_URL="https://api.github.com/repos/${GH_ORG}/${GH_REPO}/actions/runners/registration-token"
  REMOVE_URL="https://api.github.com/repos/${GH_ORG}/${GH_REPO}/actions/runners/remove-token"
  CONFIG_URL="https://github.com/${GH_ORG}/${GH_REPO}"
else
  TOKEN_URL="https://api.github.com/orgs/${GH_ORG}/actions/runners/registration-token"
  REMOVE_URL="https://api.github.com/orgs/${GH_ORG}/actions/runners/remove-token"
  CONFIG_URL="https://github.com/${GH_ORG}"
fi

LABELS="${RUNNER_LABELS:-ubuntu-latest,ubuntu-22.04,ubuntu-24.04,self-hosted,linux,x64}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"

# ── Get registration token ──────────────────────────────────────────────────
# Stores the full API response in GET_TOKEN_RESPONSE for error reporting.
GET_TOKEN_RESPONSE=""

get_token() {
  local url="$1"
  GET_TOKEN_RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "$url")
  echo "$GET_TOKEN_RESPONSE" | jq -r '.token'
}

# ── Graceful shutdown — wait for job, then deregister ────────────────────────
RUNNER_PID=""

cleanup() {
  echo "Caught signal — waiting for current job to finish..."
  if [[ -n "$RUNNER_PID" ]] && kill -0 "$RUNNER_PID" 2>/dev/null; then
    # Forward SIGTERM to the runner process — it will finish the current
    # job step before exiting. Do NOT skip this: killing run.sh immediately
    # would abort a user's CI job mid-run.
    kill -TERM "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
  fi
  echo "Runner process exited — deregistering..."
  local remove_token
  remove_token=$(get_token "$REMOVE_URL")
  ./config.sh remove --token "$remove_token" 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

# ── Remove stale config from previous run (container restart) ────────────────
if [[ -f .runner ]]; then
  echo "Removing stale runner configuration..."
  REMOVE_TOKEN=$(get_token "$REMOVE_URL")
  ./config.sh remove --token "$REMOVE_TOKEN" 2>/dev/null || true
fi

# ── Register (with retry + exponential backoff) ──────────────────────────────
MAX_RETRIES="${MAX_RETRIES:-5}"
RETRY_DELAY=10
FAIL_COOLDOWN="${FAIL_COOLDOWN:-300}"  # 5 min sleep before exit to prevent restart storm

REG_TOKEN=""
attempt=1
delay=$RETRY_DELAY

while [[ $attempt -le $MAX_RETRIES ]]; do
  echo "Registering runner '${RUNNER_NAME}' with ${CONFIG_URL} (attempt ${attempt}/${MAX_RETRIES})..."
  REG_TOKEN=$(get_token "$TOKEN_URL")

  if [[ -n "$REG_TOKEN" && "$REG_TOKEN" != "null" ]]; then
    break
  fi

  echo "Token request failed."
  if [[ $attempt -lt $MAX_RETRIES ]]; then
    echo "Retrying in ${delay}s..."
    sleep "$delay"
    delay=$((delay * 2))
  fi
  attempt=$((attempt + 1))
done

if [[ -z "$REG_TOKEN" || "$REG_TOKEN" == "null" ]]; then
  echo ""
  echo "ERROR: Failed to get registration token after ${MAX_RETRIES} attempts."
  echo ""
  echo "API response: ${GET_TOKEN_RESPONSE}"
  echo ""
  echo "Check that GH_PAT has the correct scopes:"
  echo "  • repo (for repo-level runners)"
  echo "  • admin:org → manage_runners:org (for org-level runners)"
  echo ""
  echo "Sleeping ${FAIL_COOLDOWN}s before exit to prevent restart storm..."
  sleep "$FAIL_COOLDOWN"
  exit 1
fi

./config.sh \
  --url "$CONFIG_URL" \
  --token "$REG_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$LABELS" \
  --work "_work" \
  --replace \
  --unattended \
  --ephemeral

echo "Runner registered. Waiting for jobs..."

# ── Run (ephemeral = exits after one job, Docker restarts it fresh) ──────────
./run.sh &
RUNNER_PID=$!
wait "$RUNNER_PID"
