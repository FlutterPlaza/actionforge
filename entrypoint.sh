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
get_token() {
  local url="$1"
  curl -s -X POST \
    -H "Authorization: Bearer ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "$url" | jq -r '.token'
}

# ── Graceful shutdown — deregister runner ────────────────────────────────────
cleanup() {
  echo "Caught signal — deregistering runner..."
  local remove_token
  remove_token=$(get_token "$REMOVE_URL")
  ./config.sh remove --token "$remove_token" 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

# ── Register ─────────────────────────────────────────────────────────────────
echo "Registering runner '${RUNNER_NAME}' with ${CONFIG_URL}..."
REG_TOKEN=$(get_token "$TOKEN_URL")

if [[ -z "$REG_TOKEN" || "$REG_TOKEN" == "null" ]]; then
  echo "ERROR: Failed to get registration token."
  echo "Check that GH_PAT has the correct scopes:"
  echo "  • repo (for repo-level runners)"
  echo "  • admin:org → manage_runners:org (for org-level runners)"
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
wait $!
