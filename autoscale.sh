#!/usr/bin/env bash
# ============================================================================
#  ActionForge — Queue-based Autoscaler
#  A FlutterPlaza Open-Source Product | https://flutterplaza.com
# ----------------------------------------------------------------------------
#  Scales the Docker runner pool up and down to match GitHub Actions demand,
#  between AF_MIN and AF_MAX runners. GitHub does not push queue events to a
#  local machine, so this is a POLL loop: every AF_INTERVAL seconds it counts
#  the self-hosted jobs in flight (running + queued) across the org's PRIVATE
#  repos and runs `docker compose --scale runner=<n>` when the count changes.
#
#  Runners are ephemeral (one job each, then the container restarts), so
#  scaling down simply reduces the replica count — in-progress jobs finish
#  first via the compose stop_grace_period.
#
#  Usage (standalone):
#    GH_ORG=myorg GH_PAT=ghp_xxx AF_PROJECT=actionforge-myorg \
#      ./autoscale.sh
#  Env:
#    GH_ORG      GitHub org (required)
#    GH_PAT      token with admin:org / manage_runners:org (required)
#    AF_PROJECT  docker compose project name (-p); empty = default project
#    AF_MAX      max runners        (default 8)
#    AF_MIN      min runners        (default 1)
#    AF_INTERVAL poll seconds       (default 20)
#    AF_ONCE     set to 1 to run a single reconcile and exit (for testing)
# ============================================================================
set -euo pipefail

AF_MAX="${AF_MAX:-8}"
AF_MIN="${AF_MIN:-1}"
AF_INTERVAL="${AF_INTERVAL:-20}"
AF_PROJECT="${AF_PROJECT:-}"
# Scale UP immediately; scale DOWN only after this many consecutive ticks of
# lower demand. Prevents the pool from oscillating (5→3→2→5…) and churning
# runners — a scale-down removes containers by index and can tear down one that
# just picked up a job, so we shrink lazily and only when demand is truly idle.
AF_SCALE_DOWN_DELAY="${AF_SCALE_DOWN_DELAY:-3}"

# ── GitHub API helper ────────────────────────────────────────────────────────
af_api() {
  curl -s --max-time 15 \
    -H "Authorization: Bearer ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" "$@"
}

# ── clamp N into [AF_MIN, AF_MAX] ────────────────────────────────────────────
# Pure function (no I/O) so it is unit-testable.
af_clamp() {
  local v="$1"
  if (( v < AF_MIN )); then v="$AF_MIN"; fi
  if (( v > AF_MAX )); then v="$AF_MAX"; fi
  echo "$v"
}

# ── Demand = busy self-hosted runners + queued runs on private repos ─────────
# Busy runners = jobs running on our pool right now (accurate). Queued runs on
# PRIVATE repos = jobs waiting for a runner (public repos run on GitHub-hosted,
# so they are excluded to avoid spinning up idle self-hosted runners). This
# slightly over-counts private Windows legs (windows-latest), which is rare and
# bounded by AF_MAX; idle runners scale back down on the next tick.
af_demand() {
  local busy queued=0 repos r q
  busy=$(af_api "https://api.github.com/orgs/${GH_ORG}/actions/runners?per_page=100" \
    | jq '[.runners[]? | select(.busy==true)] | length' 2>/dev/null || echo 0)
  repos=$(af_api "https://api.github.com/orgs/${GH_ORG}/repos?per_page=100&type=private" \
    | jq -r '.[]?.name' 2>/dev/null || echo "")
  for r in $repos; do
    q=$(af_api "https://api.github.com/repos/${GH_ORG}/${r}/actions/runs?status=queued&per_page=1" \
      | jq '.total_count // 0' 2>/dev/null || echo 0)
    queued=$(( queued + q ))
  done
  echo $(( busy + queued ))
}

# ── docker compose helpers ───────────────────────────────────────────────────
af_current_scale() {
  # shellcheck disable=SC2086
  docker compose ${AF_PROJECT:+-p "$AF_PROJECT"} ps -q runner 2>/dev/null | wc -l | tr -d ' '
}

af_scale_to() {
  # shellcheck disable=SC2086
  docker compose ${AF_PROJECT:+-p "$AF_PROJECT"} up -d --scale runner="$1" >/dev/null 2>&1
}

# ── Desired count = clamp(demand). Empty on API failure. ─────────────────────
af_desired() {
  local demand
  demand="$(af_demand)"
  [[ -z "$demand" ]] && return 0
  af_clamp "$demand"
}

# ── One immediate reconcile (no hysteresis) — used by AF_ONCE / tests ─────────
af_reconcile() {
  local desired current
  desired="$(af_desired)" || return 0
  [[ -z "$desired" ]] && return 0
  current="$(af_current_scale)"
  if [[ "$desired" != "$current" ]]; then
    echo "[autoscale] demand → scale ${current} → ${desired}"
    af_scale_to "$desired"
  fi
}

# ── Main loop (skipped when sourced for tests, or AF_ONCE=1) ──────────────────
# Scale UP on the first tick that needs it; scale DOWN only after
# AF_SCALE_DOWN_DELAY consecutive ticks below the current count, so a transient
# demand dip does not tear down a runner that is mid-job.
af_main() {
  : "${GH_ORG:?GH_ORG required}"
  : "${GH_PAT:?GH_PAT required}"
  echo "[autoscale] org=${GH_ORG} project=${AF_PROJECT:-<default>} min=${AF_MIN} max=${AF_MAX} interval=${AF_INTERVAL}s down_delay=${AF_SCALE_DOWN_DELAY}"
  if [[ "${AF_ONCE:-0}" == "1" ]]; then
    af_reconcile
    return 0
  fi
  local low_ticks=0
  while true; do
    local desired current
    desired="$(af_desired)" || desired=""
    if [[ -n "$desired" ]]; then
      current="$(af_current_scale)"
      if (( desired > current )); then
        echo "[autoscale] scale UP ${current} → ${desired}"
        af_scale_to "$desired"
        low_ticks=0
      elif (( desired < current )); then
        low_ticks=$(( low_ticks + 1 ))
        if (( low_ticks >= AF_SCALE_DOWN_DELAY )); then
          echo "[autoscale] sustained low demand (${low_ticks} ticks) → scale DOWN ${current} → ${desired}"
          af_scale_to "$desired"
          low_ticks=0
        fi
      else
        low_ticks=0
      fi
    fi
    sleep "$AF_INTERVAL"
  done
}

# Only run when executed directly (not when sourced by the test harness).
# ${BASH_SOURCE[0]:-} guards against `set -u` when sourced into a shell that
# does not populate BASH_SOURCE (e.g. zsh).
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  af_main "$@"
fi
