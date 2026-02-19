#!/usr/bin/env bash
# ============================================================================
#  ActionForge — One-Click Self-Hosted CI Runners
#  A FlutterPlaza Open-Source Product | https://flutterplaza.com
# ============================================================================
#  Usage:
#    actionforge                   # Interactive mode (prompts for everything)
#    actionforge --docker          # Use Docker-based isolated runner
#    actionforge --bare            # Install runner directly on this machine
#    actionforge --teardown        # Remove all runners from this machine
#    actionforge --status          # Live runner dashboard
#    actionforge --version         # Print version and exit
#    actionforge --help            # Print usage and exit
#
#  Environment variables (optional — skips prompts):
#    GH_ORG          GitHub org or user           (e.g. "my-company")
#    GH_REPO         Specific repo (optional)     (e.g. "backend-api")
#    GH_PAT          Personal Access Token
#    RUNNER_COUNT    Number of parallel runners   (default: 2)
#    RUNNER_LABELS   Comma-separated labels       (default: auto-detected)
#
#  Supported platforms:
#    macOS (Intel & Apple Silicon)
#    Linux (Ubuntu, Debian, Fedora, CentOS, RHEL, Arch, Alpine, openSUSE)
#    Windows → use setup.ps1 instead
# ============================================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

ACTIONFORGE_VERSION="1.4.0"
RUNNER_VERSION="2.321.0"
CONFIG_FILE="$HOME/.actionforge.conf"
ACTIONFORGE_WORKDIR="$HOME/.actionforge"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo -e "${BLUE}ℹ ${NC} $*"; }
ok()    { echo -e "${GREEN}✔ ${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠ ${NC} $*"; }
fail()  { echo -e "${RED}✘ ${NC} $*"; exit 1; }

# ── Resolve script directory (follows symlinks — needed for Homebrew) ────────
resolve_script_dir() {
  local source="${BASH_SOURCE[0]}"
  while [[ -L "$source" ]]; do
    local dir
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  cd -P "$(dirname "$source")" && pwd
}

banner() {
  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║       ActionForge — by FlutterPlaza              ║${NC}"
  echo -e "${CYAN}║       One-Click Self-Hosted CI Runners           ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Detect OS & Architecture ───────────────────────────────────────────────
detect_os() {
  case "$(uname -s)" in
    Linux*)   OS="linux";;
    Darwin*)  OS="osx";;
    *)        fail "Unsupported OS: $(uname -s). Windows users should run setup.ps1 instead.";;
  esac

  case "$(uname -m)" in
    x86_64|amd64)  ARCH="x64";;
    arm64|aarch64) ARCH="arm64";;
    *)             fail "Unsupported architecture: $(uname -m)";;
  esac

  # Detect Linux distro
  DISTRO=""
  if [[ "$OS" == "linux" ]] && [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    DISTRO=$(. /etc/os-release && echo "${ID:-unknown}")
  fi

  RUNNER_PACKAGE="actions-runner-${OS}-${ARCH}-${RUNNER_VERSION}.tar.gz"
  info "Detected: ${OS}/${ARCH}${DISTRO:+ (${DISTRO})}"
}

# ── Package manager helper ─────────────────────────────────────────────────
pkg_install() {
  local pkgs=("$@")
  if [[ "$OS" == "osx" ]]; then
    brew install "${pkgs[@]}"
  elif [[ -n "$DISTRO" ]]; then
    case "$DISTRO" in
      ubuntu|debian|linuxmint|pop)
        sudo apt-get update -qq && sudo apt-get install -y -qq "${pkgs[@]}" ;;
      fedora)
        sudo dnf install -y "${pkgs[@]}" ;;
      centos|rhel|rocky|alma)
        sudo yum install -y "${pkgs[@]}" ;;
      arch|manjaro)
        sudo pacman -S --noconfirm "${pkgs[@]}" ;;
      alpine)
        sudo apk add "${pkgs[@]}" ;;
      opensuse*|suse|sles)
        sudo zypper install -y "${pkgs[@]}" ;;
      *)
        fail "Unsupported distro '${DISTRO}'. Please install manually: ${pkgs[*]}" ;;
    esac
  else
    fail "Could not detect package manager. Please install manually: ${pkgs[*]}"
  fi
}

# ── Install Docker ─────────────────────────────────────────────────────────
install_docker() {
  info "Docker not found — installing automatically..."

  if [[ "$OS" == "osx" ]]; then
    # Ensure Homebrew is available
    if ! command -v brew &>/dev/null; then
      info "Installing Homebrew..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      # Add brew to PATH for Apple Silicon
      if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      fi
    fi

    info "Installing Docker Desktop via Homebrew..."
    brew install --cask docker

    info "Starting Docker Desktop..."
    open -a Docker

    info "Waiting for Docker daemon to start (up to 60s)..."
    local waited=0
    while ! docker info &>/dev/null 2>&1; do
      sleep 2
      waited=$((waited + 2))
      if [[ $waited -ge 60 ]]; then
        fail "Docker daemon did not start within 60s. Please start Docker Desktop manually and re-run this script."
      fi
    done
    ok "Docker Desktop is running"

  elif [[ "$OS" == "linux" ]]; then
    case "$DISTRO" in
      ubuntu|debian|linuxmint|pop)
        sudo apt-get update -qq
        sudo apt-get install -y -qq docker.io docker-compose-plugin ;;
      fedora)
        sudo dnf install -y docker docker-compose-plugin ;;
      centos|rhel|rocky|alma)
        sudo yum install -y docker docker-compose-plugin ;;
      arch|manjaro)
        sudo pacman -S --noconfirm docker docker-compose ;;
      alpine)
        sudo apk add docker docker-compose ;;
      opensuse*|suse|sles)
        sudo zypper install -y docker docker-compose ;;
      *)
        fail "Cannot auto-install Docker on '${DISTRO}'. Install manually: https://docs.docker.com/get-docker/" ;;
    esac

    # Enable and start Docker service
    if command -v systemctl &>/dev/null; then
      sudo systemctl enable --now docker
    elif command -v rc-update &>/dev/null; then
      sudo rc-update add docker default
      sudo service docker start
    fi

    # Add current user to docker group
    if ! groups "$USER" | grep -q docker; then
      sudo usermod -aG docker "$USER"
      warn "Added $USER to the 'docker' group. You may need to log out and back in for this to take effect."
    fi

    ok "Docker installed and started"
  fi
}

# ── Check prerequisites ───────────────────────────────────────────────────
check_prereqs() {
  # Ensure Homebrew is available on macOS before installing anything
  if [[ "$OS" == "osx" ]] && ! command -v brew &>/dev/null; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -f /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
  fi

  local missing=()
  for cmd in curl git jq; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Installing missing tools: ${missing[*]}"
    pkg_install "${missing[@]}"
  fi

  # Install Docker if missing
  if ! command -v docker &>/dev/null; then
    install_docker
  fi

  # Verify docker compose works
  if ! docker compose version &>/dev/null 2>&1; then
    fail "Docker Compose is not available. Please install docker-compose-plugin and re-run."
  fi

  ok "All prerequisites satisfied (curl, git, jq, docker, docker compose)"
}

# ── Resolve runner labels ─────────────────────────────────────────────────
# Dynamic labels based on install mode
# Docker mode always uses Linux labels (containers are Linux regardless of host OS)
# Bare mode uses the host OS labels
resolve_labels() {
  if [[ -z "${RUNNER_LABELS:-}" ]]; then
    if [[ "$MODE" == "docker" ]]; then
      RUNNER_LABELS="ubuntu-latest,ubuntu-22.04,ubuntu-24.04,self-hosted,linux,x64"
    elif [[ "$OS" == "osx" ]]; then
      RUNNER_LABELS="macos-latest,macos-14,self-hosted,macos,${ARCH}"
    else
      RUNNER_LABELS="ubuntu-latest,ubuntu-22.04,ubuntu-24.04,self-hosted,linux,${ARCH}"
    fi
  fi
}

# ── Secure PAT storage ───────────────────────────────────────────────────────
# macOS:  Keychain (encrypted, no prompts for same-user access)
# Linux:  secret-tool / GNOME Keyring if available, otherwise config file
# Docker: always config file (PAT needs to be in .env for compose)

store_pat() {
  local pat="$1"
  if [[ "$OS" == "osx" ]]; then
    # Delete existing entry first (silent), then add
    security delete-generic-password -a actionforge -s actionforge-pat &>/dev/null || true
    if security add-generic-password -a actionforge -s actionforge-pat -w "$pat" &>/dev/null; then
      ok "PAT saved to macOS Keychain"
      return 0
    fi
  elif command -v secret-tool &>/dev/null; then
    if echo -n "$pat" | secret-tool store --label="ActionForge PAT" service actionforge key pat 2>/dev/null; then
      ok "PAT saved to system keyring"
      return 0
    fi
  fi
  # Fallback: save to config file
  return 1
}

retrieve_pat() {
  # Already set (CLI arg or env var) — skip lookup
  [[ -n "${GH_PAT:-}" ]] && return 0

  if [[ "${OS:-}" == "osx" ]] || [[ "$(uname -s)" == "Darwin" ]]; then
    GH_PAT=$(security find-generic-password -a actionforge -s actionforge-pat -w 2>/dev/null) || true
  elif command -v secret-tool &>/dev/null; then
    GH_PAT=$(secret-tool lookup service actionforge key pat 2>/dev/null) || true
  fi

  # Fallback: config file (for Docker mode or when keystore isn't available)
  if [[ -z "${GH_PAT:-}" ]] && [[ -f "$CONFIG_FILE" ]]; then
    GH_PAT=$(grep '^GH_PAT=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  fi
}

remove_pat() {
  if [[ "$OS" == "osx" ]] || [[ "$(uname -s)" == "Darwin" ]]; then
    security delete-generic-password -a actionforge -s actionforge-pat 2>/dev/null || true
  elif command -v secret-tool &>/dev/null; then
    secret-tool clear service actionforge key pat 2>/dev/null || true
  fi
}

# ── Prompt for missing config ────────────────────────────────────────────────
prompt_config() {
  # Preserve CLI arguments so they aren't overwritten by saved config
  local cli_org="${GH_ORG:-}"
  local cli_repo="${GH_REPO+__SET__${GH_REPO}}"
  local cli_pat="${GH_PAT:-}"
  local cli_count="${RUNNER_COUNT:-}"
  local cli_labels="${RUNNER_LABELS:-}"

  # Load saved config if it exists
  # shellcheck source=/dev/null
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

  # CLI arguments take precedence over saved config
  [[ -n "$cli_org" ]] && GH_ORG="$cli_org"
  [[ "$cli_repo" == __SET__* ]] && GH_REPO="${cli_repo#__SET__}"
  [[ -n "$cli_pat" ]] && GH_PAT="$cli_pat"
  [[ -n "$cli_count" ]] && RUNNER_COUNT="$cli_count"
  [[ -n "$cli_labels" ]] && RUNNER_LABELS="$cli_labels"

  # Try to retrieve PAT from secure storage if not already set
  retrieve_pat

  if [[ -z "${GH_ORG:-}" ]]; then
    read -rp "$(echo -e "${YELLOW}GitHub org or username: ${NC}")" GH_ORG
  fi

  if [[ -z "${GH_REPO+x}" ]]; then
    read -rp "$(echo -e "${YELLOW}Specific repo (leave blank for org-wide): ${NC}")" GH_REPO
    GH_REPO="${GH_REPO:-}"
  fi

  if [[ -z "${GH_PAT:-}" ]]; then
    echo -e "${YELLOW}You need a PAT with these scopes:${NC}"
    echo "  - repo (full control)"
    echo "  - admin:org → manage_runners:org  (if org-wide)"
    echo ""
    read -rsp "$(echo -e "${YELLOW}GitHub Personal Access Token: ${NC}")" GH_PAT
    echo ""
  fi

  RUNNER_COUNT="${RUNNER_COUNT:-2}"
  if [[ -z "${SKIP_PROMPTS:-}" ]]; then
    read -rp "$(echo -e "${YELLOW}Number of parallel runners [${RUNNER_COUNT}]: ${NC}")" input_count
    RUNNER_COUNT="${input_count:-$RUNNER_COUNT}"
  fi

  resolve_labels

  # Store PAT in keystore (extra security layer for interactive use)
  store_pat "$GH_PAT" || true

  # Always save PAT to config file too — LaunchAgents/systemd services
  # can't access the user keychain reliably, so they read from here
  cat > "$CONFIG_FILE" <<EOF
GH_ORG="${GH_ORG}"
GH_REPO="${GH_REPO}"
GH_PAT="${GH_PAT}"
RUNNER_COUNT=${RUNNER_COUNT}
RUNNER_LABELS="${RUNNER_LABELS}"
EOF
  chmod 600 "$CONFIG_FILE"
  ok "Config saved to ${CONFIG_FILE}"
}

# ── Resolve GitHub API URL ───────────────────────────────────────────────────
resolve_urls() {
  if [[ -n "$GH_REPO" ]]; then
    API_URL="https://api.github.com/repos/${GH_ORG}/${GH_REPO}/actions/runners/registration-token"
    CONFIG_URL="https://github.com/${GH_ORG}/${GH_REPO}"
    SCOPE="repo: ${GH_ORG}/${GH_REPO}"
  else
    API_URL="https://api.github.com/orgs/${GH_ORG}/actions/runners/registration-token"
    CONFIG_URL="https://github.com/${GH_ORG}"
    SCOPE="org: ${GH_ORG}"
  fi
  info "Scope: ${SCOPE}"
}

# ── Get registration token ──────────────────────────────────────────────────
get_reg_token() {
  local token
  token=$(curl -s -X POST \
    -H "Authorization: Bearer ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "$API_URL")

  REG_TOKEN=$(echo "$token" | jq -r '.token // empty')

  if [[ -z "$REG_TOKEN" || "$REG_TOKEN" == "null" ]]; then
    echo "$token"
    fail "Failed to get registration token. Check your PAT scopes."
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  BARE METAL INSTALL
# ══════════════════════════════════════════════════════════════════════════════
install_bare() {
  local runner_base

  if [[ "$OS" == "osx" ]]; then
    runner_base="$HOME/actions-runners"
    mkdir -p "$runner_base"
  else
    runner_base="/opt/actions-runners"
    sudo mkdir -p "$runner_base"
    sudo chown "$USER:$(id -gn)" "$runner_base"
  fi

  # Set up Flutter/Dart SDK BEFORE starting runners so the SDK is
  # available when the first job is picked up
  setup_flutter

  for i in $(seq 1 "$RUNNER_COUNT"); do
    local runner_dir="${runner_base}/runner-${i}"
    local runner_name
    runner_name="$(hostname)-runner-${i}"
    info "Setting up runner-${i} of ${RUNNER_COUNT}..."

    mkdir -p "$runner_dir"
    cd "$runner_dir"

    # Download if not already present
    if [[ ! -f run.sh ]]; then
      curl -sL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_PACKAGE}"
      tar xzf runner.tar.gz
      rm runner.tar.gz
    fi

    # Create respawn wrapper — re-registers and restarts after each ephemeral job
    _create_respawn_wrapper "$runner_dir" "$runner_name"

    # Initial registration
    get_reg_token

    ./config.sh \
      --url "$CONFIG_URL" \
      --token "$REG_TOKEN" \
      --name "$runner_name" \
      --labels "$RUNNER_LABELS" \
      --work "_work" \
      --replace \
      --unattended \
      --ephemeral

    # Install service that runs the respawn wrapper (not run.sh directly)
    _install_respawn_service "$runner_dir" "$runner_name" "$i"

    ok "runner-${i} is live and listening for jobs (auto-respawn enabled)"
  done
}

# Generate the respawn wrapper script for a bare-metal runner
_create_respawn_wrapper() {
  local runner_dir="$1"
  local runner_name="$2"

  cat > "${runner_dir}/respawn.sh" <<'RESPAWN_OUTER'
#!/usr/bin/env bash
# ActionForge respawn wrapper — re-registers ephemeral runner after each job
set -uo pipefail

RUNNER_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$RUNNER_DIR"

CONFIG_FILE="$HOME/.actionforge.conf"

# Load config
# shellcheck source=/dev/null
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Retrieve PAT from keystore or config
retrieve_pat() {
  if [[ -n "${GH_PAT:-}" ]]; then return 0; fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    GH_PAT=$(security find-generic-password -a actionforge -s actionforge-pat -w 2>/dev/null) || true
  elif command -v secret-tool &>/dev/null; then
    GH_PAT=$(secret-tool lookup service actionforge key pat 2>/dev/null) || true
  fi
  if [[ -z "${GH_PAT:-}" ]] && [[ -f "$CONFIG_FILE" ]]; then
    GH_PAT=$(grep '^GH_PAT=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || true)
  fi
}

retrieve_pat

if [[ -z "${GH_PAT:-}" ]]; then
  echo "ERROR: No PAT available. Cannot register runner."
  exit 1
fi

# Resolve API URLs
if [[ -n "${GH_REPO:-}" ]]; then
  TOKEN_URL="https://api.github.com/repos/${GH_ORG}/${GH_REPO}/actions/runners/registration-token"
  REMOVE_URL="https://api.github.com/repos/${GH_ORG}/${GH_REPO}/actions/runners/remove-token"
  RUNNER_CONFIG_URL="https://github.com/${GH_ORG}/${GH_REPO}"
else
  TOKEN_URL="https://api.github.com/orgs/${GH_ORG}/actions/runners/registration-token"
  REMOVE_URL="https://api.github.com/orgs/${GH_ORG}/actions/runners/remove-token"
  RUNNER_CONFIG_URL="https://github.com/${GH_ORG}"
fi

LABELS="${RUNNER_LABELS:-self-hosted}"
RESPAWN_OUTER

  # Inject the runner name (not single-quoted so it expands now)
  cat >> "${runner_dir}/respawn.sh" <<RESPAWN_NAME
RUNNER_NAME="${runner_name}"
RESPAWN_NAME

  cat >> "${runner_dir}/respawn.sh" <<'RESPAWN_INNER'
RUNNER_PID=""
COOLDOWN=10

cleanup() {
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') Caught signal — shutting down..."
  if [[ -n "$RUNNER_PID" ]] && kill -0 "$RUNNER_PID" 2>/dev/null; then
    kill -TERM "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
  fi
  # Deregister
  local remove_token
  remove_token=$(curl -s -X POST \
    -H "Authorization: Bearer ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "$REMOVE_URL" | jq -r '.token // empty')
  if [[ -n "$remove_token" ]]; then
    ./config.sh remove --token "$remove_token" 2>/dev/null || true
  fi
  exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

# ── Main respawn loop ──────────────────────────────────────────────────────
while true; do
  echo ""
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') Registering runner '${RUNNER_NAME}'..."

  # Remove stale config from previous run
  if [[ -f .runner ]]; then
    local_remove_token=$(curl -s -X POST \
      -H "Authorization: Bearer ${GH_PAT}" \
      -H "Accept: application/vnd.github+json" \
      "$REMOVE_URL" | jq -r '.token // empty') || true
    if [[ -n "${local_remove_token:-}" ]]; then
      ./config.sh remove --token "$local_remove_token" 2>/dev/null || true
    fi
  fi

  # Get fresh registration token
  REG_TOKEN=$(curl -s -X POST \
    -H "Authorization: Bearer ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "$TOKEN_URL" | jq -r '.token // empty')

  if [[ -z "$REG_TOKEN" || "$REG_TOKEN" == "null" ]]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') ERROR: Failed to get registration token. Retrying in ${COOLDOWN}s..."
    sleep "$COOLDOWN"
    COOLDOWN=$((COOLDOWN * 2))
    [[ $COOLDOWN -gt 300 ]] && COOLDOWN=300
    continue
  fi

  # Configure
  ./config.sh \
    --url "$RUNNER_CONFIG_URL" \
    --token "$REG_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$LABELS" \
    --work "_work" \
    --replace \
    --unattended \
    --ephemeral

  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') Runner registered. Waiting for jobs..."
  COOLDOWN=10

  # Run (blocks until job completes or runner exits)
  ./run.sh &
  RUNNER_PID=$!
  wait "$RUNNER_PID" || true
  RUNNER_PID=""

  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') Job completed. Respawning in 5s..."
  sleep 5
done
RESPAWN_INNER

  chmod +x "${runner_dir}/respawn.sh"
}

# Install a system service that runs the respawn wrapper
_install_respawn_service() {
  local runner_dir="$1"
  local runner_name="$2"
  local index="$3"
  local svc_label="actionforge.runner.${index}"

  if [[ "$OS" == "osx" ]]; then
    # macOS: create LaunchAgent plist
    local plist_path="$HOME/Library/LaunchAgents/${svc_label}.plist"
    local log_dir="$HOME/Library/Logs/${svc_label}"
    mkdir -p "$log_dir"

    cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${svc_label}</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>${runner_dir}/respawn.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${runner_dir}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${log_dir}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${log_dir}/stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>HOME</key>
      <string>${HOME}</string>
      <key>PATH</key>
      <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>SessionCreate</key>
    <true/>
  </dict>
</plist>
PLIST

    launchctl load "$plist_path"

  else
    # Linux: create systemd service
    local svc_file="/etc/systemd/system/${svc_label}.service"
    sudo tee "$svc_file" > /dev/null <<UNIT
[Unit]
Description=ActionForge Runner ${index}
After=network.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${runner_dir}
ExecStart=/bin/bash ${runner_dir}/respawn.sh
Restart=always
RestartSec=10
Environment=HOME=${HOME}

[Install]
WantedBy=multi-user.target
UNIT

    sudo systemctl daemon-reload
    sudo systemctl enable "${svc_label}"
    sudo systemctl start "${svc_label}"
  fi
}

# ── Detect Flutter version from workflow files ────────────────────────────────
# Fetches workflow files from the target repo via GitHub API and extracts the
# required Flutter/Dart version.  Sets WORKFLOW_FLUTTER_VERSION.
#
# Detection priority (first match wins):
#   1. .fvm/fvm_config.json  → flutterSdkVersion
#   2. Workflow YAML          → subosito/flutter-action  flutter-version:
#   3. Workflow YAML          → dart-lang/setup-dart     sdk:
#   4. pubspec.yaml           → environment.flutter lower bound
#   5. Fallback               → "stable"
detect_workflow_flutter() {
  WORKFLOW_FLUTTER_VERSION="stable"
  WORKFLOW_DART_ONLY=false

  # Need PAT + repo to query the API
  if [[ -z "${GH_PAT:-}" ]] || [[ -z "${GH_ORG:-}" ]] || [[ -z "${GH_REPO:-}" ]]; then
    info "No repo context for workflow detection — using stable"
    return 0
  fi

  local api_base="https://api.github.com/repos/${GH_ORG}/${GH_REPO}"
  local auth_header="Authorization: Bearer ${GH_PAT}"

  # Helper: fetch a file's content from the repo (base64-decoded)
  _gh_file_content() {
    local path="$1"
    local resp
    resp=$(curl -s --max-time 10 \
      -H "$auth_header" \
      -H "Accept: application/vnd.github+json" \
      "${api_base}/contents/${path}" 2>/dev/null) || return 1
    # Check for valid base64 content
    local content
    content=$(echo "$resp" | jq -r '.content // empty' 2>/dev/null) || return 1
    [[ -n "$content" ]] || return 1
    echo "$content" | base64 -d 2>/dev/null || return 1
  }

  # ── 1. .fvm/fvm_config.json ─────────────────────────────────────────────
  local fvm_content fvm_ver
  fvm_content=$(_gh_file_content ".fvm/fvm_config.json" 2>/dev/null) || true
  if [[ -n "$fvm_content" ]]; then
    fvm_ver=$(echo "$fvm_content" | jq -r '.flutterSdkVersion // empty' 2>/dev/null) || true
    if [[ -n "$fvm_ver" ]] && [[ "$fvm_ver" != "null" ]]; then
      WORKFLOW_FLUTTER_VERSION="$fvm_ver"
      ok "Detected Flutter ${fvm_ver} from .fvm/fvm_config.json"
      return 0
    fi
  fi

  # ── 2 & 3. Scan workflow YAML files ─────────────────────────────────────
  local workflows_resp workflow_files
  workflows_resp=$(curl -s --max-time 10 \
    -H "$auth_header" \
    -H "Accept: application/vnd.github+json" \
    "${api_base}/contents/.github/workflows" 2>/dev/null) || true

  if [[ -n "$workflows_resp" ]]; then
    workflow_files=$(echo "$workflows_resp" | jq -r '.[].name // empty' 2>/dev/null) || true

    for wf_file in $workflow_files; do
      # Only process YAML files
      case "$wf_file" in
        *.yml|*.yaml) ;;
        *) continue ;;
      esac

      local wf_content
      wf_content=$(_gh_file_content ".github/workflows/${wf_file}" 2>/dev/null) || continue
      [[ -n "$wf_content" ]] || continue

      # ── 2. subosito/flutter-action → flutter-version: ────────────────
      if echo "$wf_content" | grep -q 'subosito/flutter-action'; then
        local fv
        fv=$(echo "$wf_content" | grep -A 10 'subosito/flutter-action' \
          | grep -E '^\s+flutter-version:' \
          | head -1 \
          | sed "s/.*flutter-version:[[:space:]]*['\"]*//" \
          | sed "s/['\"].*//" \
          | tr -d '[:space:]') || true
        if [[ -n "$fv" ]]; then
          WORKFLOW_FLUTTER_VERSION="$fv"
          ok "Detected Flutter ${fv} from workflow ${wf_file} (flutter-action)"
          return 0
        fi
        # Try channel: as fallback
        local ch
        ch=$(echo "$wf_content" | grep -A 10 'subosito/flutter-action' \
          | grep -E '^\s+channel:' \
          | head -1 \
          | sed "s/.*channel:[[:space:]]*['\"]*//" \
          | sed "s/['\"].*//" \
          | tr -d '[:space:]') || true
        if [[ -n "$ch" ]]; then
          WORKFLOW_FLUTTER_VERSION="$ch"
          ok "Detected Flutter channel '${ch}' from workflow ${wf_file} (flutter-action)"
          return 0
        fi
      fi

      # ── 3. dart-lang/setup-dart → sdk: ───────────────────────────────
      if echo "$wf_content" | grep -q 'dart-lang/setup-dart'; then
        local ds
        ds=$(echo "$wf_content" | grep -A 10 'dart-lang/setup-dart' \
          | grep -E '^\s+sdk:' \
          | head -1 \
          | sed "s/.*sdk:[[:space:]]*['\"]*//" \
          | sed "s/['\"].*//" \
          | tr -d '[:space:]') || true
        if [[ -n "$ds" ]]; then
          WORKFLOW_FLUTTER_VERSION="$ds"
          WORKFLOW_DART_ONLY=true
          ok "Detected Dart SDK ${ds} from workflow ${wf_file} (setup-dart)"
          return 0
        fi
      fi
    done
  fi

  # ── 4. pubspec.yaml → environment.flutter / environment.sdk ─────────────
  local pubspec_content
  pubspec_content=$(_gh_file_content "pubspec.yaml" 2>/dev/null) || true
  if [[ -n "$pubspec_content" ]]; then
    # Look for flutter constraint: >=X.Y.Z <A.B.C
    local flutter_constraint
    flutter_constraint=$(echo "$pubspec_content" \
      | grep -A 1 'environment:' \
      | grep -E '^\s+flutter:' \
      | head -1 \
      | sed 's/.*flutter:[[:space:]]*["\x27]*//' \
      | sed 's/["\x27].*//' \
      | tr -d '[:space:]') || true
    if [[ -n "$flutter_constraint" ]]; then
      # Extract lower bound version from >=X.Y.Z
      local lower_bound
      lower_bound=$(echo "$flutter_constraint" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
      if [[ -n "$lower_bound" ]]; then
        WORKFLOW_FLUTTER_VERSION="$lower_bound"
        ok "Detected Flutter >=${lower_bound} from pubspec.yaml"
        return 0
      fi
    fi

    # Dart-only: look for sdk constraint
    local sdk_constraint
    sdk_constraint=$(echo "$pubspec_content" \
      | grep -A 2 'environment:' \
      | grep -E '^\s+sdk:' \
      | head -1 \
      | sed 's/.*sdk:[[:space:]]*["\x27]*//' \
      | sed 's/["\x27].*//' \
      | tr -d '[:space:]') || true
    if [[ -n "$sdk_constraint" ]]; then
      local dart_lower
      dart_lower=$(echo "$sdk_constraint" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
      if [[ -n "$dart_lower" ]]; then
        WORKFLOW_FLUTTER_VERSION="$dart_lower"
        WORKFLOW_DART_ONLY=true
        ok "Detected Dart SDK >=${dart_lower} from pubspec.yaml"
        return 0
      fi
    fi
  fi

  # ── 5. Fallback ─────────────────────────────────────────────────────────
  info "No Flutter/Dart version found in workflow files — using stable"
}

# ── Flutter / FVM Setup (bare mode) ──────────────────────────────────────────
setup_flutter() {
  info "Setting up Flutter / FVM..."

  # Step 1: Detect the required version from workflow files
  detect_workflow_flutter

  local target_version="$WORKFLOW_FLUTTER_VERSION"
  local dart_only="$WORKFLOW_DART_ONLY"
  local flutter_version=""
  local flutter_source=""

  # Step 2: For Dart-only repos, skip Flutter install — just ensure Dart SDK
  if [[ "$dart_only" == true ]]; then
    info "Dart-only repo detected (version: ${target_version})"
    if command -v dart &>/dev/null; then
      local dart_ver
      dart_ver=$(dart --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
      ok "Dart SDK ${dart_ver:-unknown} available"
    else
      warn "Dart SDK not found. Install Dart ${target_version} manually or via Flutter."
    fi
    # Still persist to config
    mkdir -p "$ACTIONFORGE_WORKDIR"
    if [[ -f "$CONFIG_FILE" ]] && ! grep -q '^DART_VERSION=' "$CONFIG_FILE"; then
      echo "DART_VERSION=\"${target_version}\"" >> "$CONFIG_FILE"
    fi
    return 0
  fi

  # Step 3: Install the specific version or "stable" via FVM
  if [[ "$target_version" != "stable" ]]; then
    # Specific version requested — use FVM to manage it
    info "Workflow requires Flutter ${target_version}"

    # Ensure FVM is available
    if ! command -v fvm &>/dev/null; then
      info "Installing FVM..."
      if [[ "$OS" == "osx" ]]; then
        brew tap leoafarias/fvm 2>/dev/null && brew install fvm
      else
        curl -fsSL https://fvm.app/install.sh | bash
      fi
      mkdir -p "$ACTIONFORGE_WORKDIR"
      touch "$ACTIONFORGE_WORKDIR/.fvm-installed-by-actionforge"
    fi

    # Check if this version is already installed via FVM
    if fvm list 2>/dev/null | grep -q "$target_version"; then
      ok "Flutter ${target_version} already installed via FVM"
    else
      info "Installing Flutter ${target_version} via FVM..."
      fvm install "$target_version"
    fi

    fvm global "$target_version"
    flutter_version="$target_version"
    flutter_source="fvm-specific"
    ok "Using Flutter ${target_version} (via FVM)"

  else
    # "stable" — keep legacy behavior: detect local or install
    if command -v fvm &>/dev/null; then
      flutter_version=$(fvm list 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
      if [[ -z "$flutter_version" ]] && [[ -L "$HOME/fvm/default" ]]; then
        flutter_version=$("$HOME/fvm/default/bin/flutter" --version --machine 2>/dev/null | jq -r '.flutterVersion // empty' || true)
      fi
      if [[ -n "$flutter_version" ]]; then
        flutter_source="fvm"
        ok "Using FVM Flutter ${flutter_version}"
      fi
    fi

    if [[ -z "$flutter_version" ]] && command -v flutter &>/dev/null; then
      flutter_version=$(flutter --version --machine 2>/dev/null | jq -r '.flutterVersion // empty' || true)
      if [[ -n "$flutter_version" ]]; then
        flutter_source="system"
        ok "Using system Flutter ${flutter_version}"
      fi
    fi

    if [[ -z "$flutter_version" ]]; then
      info "No Flutter/FVM found. Installing FVM + Flutter stable..."
      if [[ "$OS" == "osx" ]]; then
        brew tap leoafarias/fvm 2>/dev/null && brew install fvm
      else
        curl -fsSL https://fvm.app/install.sh | bash
      fi

      fvm install stable
      fvm global stable

      flutter_version=$(fvm list 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
      flutter_source="fvm"

      mkdir -p "$ACTIONFORGE_WORKDIR"
      touch "$ACTIONFORGE_WORKDIR/.fvm-installed-by-actionforge"
      ok "Installed Flutter ${flutter_version:-stable} via FVM"
    fi
  fi

  # Step 4: Generate flutter-env.sh pointing to the correct version
  mkdir -p "$ACTIONFORGE_WORKDIR"
  if [[ "$flutter_source" == "fvm-specific" ]]; then
    # Point to the specific FVM version directory
    cat > "$ACTIONFORGE_WORKDIR/flutter-env.sh" <<ENVEOF
export PATH="\$HOME/fvm/versions/${target_version}/bin:\$PATH"
ENVEOF
  elif [[ "$flutter_source" == "fvm" ]]; then
    cat > "$ACTIONFORGE_WORKDIR/flutter-env.sh" <<'ENVEOF'
export PATH="$HOME/fvm/default/bin:$PATH"
ENVEOF
  fi

  # Inject into shell rc files (idempotent)
  local rc_line='# ActionForge Flutter SDK'
  # shellcheck disable=SC2016
  local src_line='[ -f "$HOME/.actionforge/flutter-env.sh" ] && source "$HOME/.actionforge/flutter-env.sh"'
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$rc" ]] && ! grep -qF "ActionForge Flutter SDK" "$rc"; then
      printf '\n%s\n%s\n' "$rc_line" "$src_line" >> "$rc"
    fi
  done

  # Persist Flutter version to config
  if [[ -n "$flutter_version" ]]; then
    if [[ -f "$CONFIG_FILE" ]] && ! grep -q '^FLUTTER_VERSION=' "$CONFIG_FILE"; then
      echo "FLUTTER_VERSION=\"${flutter_version}\"" >> "$CONFIG_FILE"
    fi
  fi
}

# ── Flutter / FVM Teardown ───────────────────────────────────────────────────
teardown_flutter() {
  # Remove flutter-env.sh
  rm -f "$ACTIONFORGE_WORKDIR/flutter-env.sh"

  # Remove sourcing lines from shell rc files
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$rc" ]]; then
      sed -i.bak '/# ActionForge Flutter SDK/d' "$rc"
      sed -i.bak '/\.actionforge\/flutter-env\.sh/d' "$rc"
      rm -f "${rc}.bak"
    fi
  done

  # Remove FVM only if ActionForge installed it
  if [[ -f "$ACTIONFORGE_WORKDIR/.fvm-installed-by-actionforge" ]]; then
    rm -rf "$HOME/fvm"
    if command -v fvm &>/dev/null; then
      if [[ "$OS" == "osx" ]]; then
        brew uninstall fvm 2>/dev/null || true
      fi
    fi
    rm -f "$ACTIONFORGE_WORKDIR/.fvm-installed-by-actionforge"
    ok "Removed FVM + Flutter (installed by ActionForge)"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  DOCKER-BASED INSTALL (recommended)
# ══════════════════════════════════════════════════════════════════════════════
install_docker_mode() {
  if ! docker compose version &>/dev/null 2>&1; then
    fail "Docker Compose is not available."
  fi

  local kit_dir
  kit_dir="$(resolve_script_dir)"

  # Use ~/.actionforge/ as working directory so writes survive brew upgrade
  mkdir -p "$ACTIONFORGE_WORKDIR"

  # Copy Docker files to working directory
  for f in Dockerfile docker-compose.yml entrypoint.sh; do
    if [[ -f "${kit_dir}/${f}" ]]; then
      cp "${kit_dir}/${f}" "$ACTIONFORGE_WORKDIR/"
    else
      fail "Missing required file: ${f}"
    fi
  done

  # Write .env file for docker compose
  cat > "${ACTIONFORGE_WORKDIR}/.env" <<EOF
GH_ORG=${GH_ORG}
GH_REPO=${GH_REPO:-}
GH_PAT=${GH_PAT}
RUNNER_LABELS=${RUNNER_LABELS}
RUNNER_COUNT=${RUNNER_COUNT}
EOF
  chmod 600 "${ACTIONFORGE_WORKDIR}/.env"

  cd "$ACTIONFORGE_WORKDIR"

  info "Building runner image..."
  docker compose build

  info "Starting ${RUNNER_COUNT} runners..."
  docker compose up -d --scale runner="${RUNNER_COUNT}"

  ok "Runners are live! Check status with: docker compose ps"
}

# ══════════════════════════════════════════════════════════════════════════════
#  TEARDOWN
# ══════════════════════════════════════════════════════════════════════════════
teardown() {
  warn "Tearing down all runners on this machine..."

  # Docker runners (check working directory first, then script directory)
  if [[ -f "${ACTIONFORGE_WORKDIR}/docker-compose.yml" ]]; then
    cd "$ACTIONFORGE_WORKDIR"
    if docker compose down 2>/dev/null; then
      ok "Docker runners stopped"
    fi
  else
    local kit_dir
    kit_dir="$(resolve_script_dir)"
    if [[ -f "${kit_dir}/docker-compose.yml" ]]; then
      cd "$kit_dir"
      if docker compose down 2>/dev/null; then
        ok "Docker runners stopped"
      fi
    fi
  fi

  # Bare-metal runners
  local runner_base
  if [[ "$OS" == "osx" ]]; then
    runner_base="$HOME/actions-runners"
  else
    runner_base="/opt/actions-runners"
  fi

  if [[ -d "$runner_base" ]]; then
    # Stop respawn services (new-style actionforge.runner.*)
    for idx in $(seq 1 20); do
      local svc_label="actionforge.runner.${idx}"
      if [[ "$OS" == "osx" ]]; then
        local plist="$HOME/Library/LaunchAgents/${svc_label}.plist"
        if [[ -f "$plist" ]]; then
          launchctl unload "$plist" 2>/dev/null || true
          rm -f "$plist"
          rm -rf "$HOME/Library/Logs/${svc_label}"
        fi
      else
        if systemctl is-enabled "${svc_label}" &>/dev/null; then
          sudo systemctl stop "${svc_label}" 2>/dev/null || true
          sudo systemctl disable "${svc_label}" 2>/dev/null || true
          sudo rm -f "/etc/systemd/system/${svc_label}.service"
        fi
      fi
    done
    [[ "$OS" != "osx" ]] && sudo systemctl daemon-reload 2>/dev/null || true

    for dir in "${runner_base}"/runner-*; do
      [[ -d "$dir" ]] || continue
      cd "$dir"
      info "Removing $(basename "$dir")..."

      # Stop old-style services (actions.runner.*)
      if [[ "$OS" == "osx" ]]; then
        ./svc.sh stop 2>/dev/null || true
        ./svc.sh uninstall 2>/dev/null || true
      else
        sudo ./svc.sh stop 2>/dev/null || true
        sudo ./svc.sh uninstall 2>/dev/null || true
      fi

      # Deregister from GitHub
      if [[ -f .runner ]]; then
        get_reg_token 2>/dev/null || true
        if [[ -n "${REG_TOKEN:-}" ]]; then
          ./config.sh remove --token "$REG_TOKEN" 2>/dev/null || true
        fi
      fi
    done

    if [[ "$OS" == "osx" ]]; then
      rm -rf "$runner_base"
    else
      sudo rm -rf "$runner_base"
    fi
    ok "Bare-metal runners removed"
  fi

  # Clean up Flutter/FVM
  teardown_flutter

  # Remove config file (contains PAT) but keep PAT in Keychain/keyring
  # so the next run can retrieve it without prompting
  rm -f "$CONFIG_FILE"
  rm -rf "$ACTIONFORGE_WORKDIR"
  ok "Teardown complete"
  if [[ "$OS" == "osx" ]]; then
    info "PAT kept in macOS Keychain for next run (use 'security delete-generic-password -a actionforge -s actionforge-pat' to remove)"
  fi
}

# Stop and deregister a single bare-metal runner
stop_runner() {
  local runner_dir="$1"
  local name
  name="$(basename "$runner_dir")"

  if [[ ! -d "$runner_dir" ]]; then
    warn "Runner directory ${runner_dir} not found"
    return 1
  fi

  cd "$runner_dir"

  # Stop new-style respawn service
  local runner_idx="${name##runner-}"
  local svc_label="actionforge.runner.${runner_idx}"
  if [[ "$OS" == "osx" ]]; then
    local plist="$HOME/Library/LaunchAgents/${svc_label}.plist"
    if [[ -f "$plist" ]]; then
      launchctl unload "$plist" 2>/dev/null || true
      rm -f "$plist"
      rm -rf "$HOME/Library/Logs/${svc_label}"
    else
      # Fall back to old-style
      ./svc.sh stop 2>/dev/null || true
      ./svc.sh uninstall 2>/dev/null || true
    fi
  else
    if systemctl is-enabled "${svc_label}" &>/dev/null 2>&1; then
      sudo systemctl stop "${svc_label}" 2>/dev/null || true
      sudo systemctl disable "${svc_label}" 2>/dev/null || true
      sudo rm -f "/etc/systemd/system/${svc_label}.service"
      sudo systemctl daemon-reload 2>/dev/null || true
    else
      sudo ./svc.sh stop 2>/dev/null || true
      sudo ./svc.sh uninstall 2>/dev/null || true
    fi
  fi

  # Deregister from GitHub
  if [[ -f .runner ]]; then
    get_reg_token 2>/dev/null || true
    if [[ -n "${REG_TOKEN:-}" ]]; then
      ./config.sh remove --token "$REG_TOKEN" 2>/dev/null || true
    fi
  fi

  if [[ "$OS" == "osx" ]]; then
    rm -rf "$runner_dir"
  else
    sudo rm -rf "$runner_dir"
  fi

  ok "Stopped ${name}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  STATUS DASHBOARD
# ══════════════════════════════════════════════════════════════════════════════

# Detect which runner types are active
status_detect_runners() {
  HAS_DOCKER_RUNNERS=false
  HAS_BARE_RUNNERS=false

  # Docker: compose file exists + docker reachable + containers present
  if [[ -f "${ACTIONFORGE_WORKDIR}/docker-compose.yml" ]] \
     && command -v docker &>/dev/null \
     && docker info &>/dev/null 2>&1; then
    local count
    count=$(cd "$ACTIONFORGE_WORKDIR" && docker compose ps -q 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -gt 0 ]]; then
      HAS_DOCKER_RUNNERS=true
    fi
  fi

  # Bare: runner dirs exist with run.sh inside
  local runner_base
  if [[ "$(uname -s)" == "Darwin" ]]; then
    runner_base="$HOME/actions-runners"
  else
    runner_base="/opt/actions-runners"
  fi

  if [[ -d "$runner_base" ]]; then
    for dir in "${runner_base}"/runner-*; do
      if [[ -d "$dir" ]] && [[ -f "${dir}/run.sh" ]]; then
        HAS_BARE_RUNNERS=true
        break
      fi
    done
  fi
}

# Print Docker runner rows
status_docker_runners() {
  local compose_dir="$ACTIONFORGE_WORKDIR"
  [[ -f "${compose_dir}/docker-compose.yml" ]] || return 0

  local json
  json=$(cd "$compose_dir" && docker compose ps --format json 2>/dev/null) || return 0

  # Normalize: docker compose may emit NDJSON (one object per line) or a JSON array
  local rows
  rows=$(echo "$json" | jq -s '.' 2>/dev/null) || return 0

  local count
  count=$(echo "$rows" | jq 'length')

  echo ""
  echo -e "  ${CYAN}--- Docker Runners ---${NC}"
  printf "  %-36s %-14s %s\n" "CONTAINER" "STATE" "STATUS"
  for idx in $(seq 0 $((count - 1))); do
    local name state status color
    name=$(echo "$rows" | jq -r ".[$idx].Name // .[$idx].Names // \"-\"")
    state=$(echo "$rows" | jq -r ".[$idx].State // \"-\"")
    status=$(echo "$rows" | jq -r ".[$idx].Status // \"-\"")
    case "$state" in
      running) color="$GREEN";;
      exited|dead) color="$RED";;
      *) color="$YELLOW";;
    esac
    # shellcheck disable=SC2059
    printf "  %-36s ${color}%-14s${NC} %s\n" "$name" "$state" "$status"
  done
}

# Print bare-metal runner rows
status_bare_runners() {
  local runner_base
  if [[ "$(uname -s)" == "Darwin" ]]; then
    runner_base="$HOME/actions-runners"
  else
    runner_base="/opt/actions-runners"
  fi
  [[ -d "$runner_base" ]] || return 0

  # Fetch GitHub runner status (once per render, best-effort)
  local gh_runners_json="" gh_jobs_json=""
  if [[ -n "${GH_PAT:-}" ]] && [[ -n "${GH_ORG:-}" ]]; then
    local api_base
    if [[ -n "${GH_REPO:-}" ]]; then
      api_base="https://api.github.com/repos/${GH_ORG}/${GH_REPO}/actions"
    else
      api_base="https://api.github.com/orgs/${GH_ORG}/actions"
    fi
    gh_runners_json=$(curl -s --max-time 5 \
      -H "Authorization: Bearer ${GH_PAT}" \
      -H "Accept: application/vnd.github+json" \
      "${api_base}/runners" 2>/dev/null) || true

    # Fetch in-progress workflow runs + jobs to show active job info
    local has_busy
    has_busy=$(echo "$gh_runners_json" | jq -r '[.runners[]? | select(.busy == true)] | length' 2>/dev/null || echo "0")
    if [[ "$has_busy" -gt 0 ]] && [[ -n "${GH_REPO:-}" ]]; then
      local runs_json run_ids
      runs_json=$(curl -s --max-time 5 \
        -H "Authorization: Bearer ${GH_PAT}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GH_ORG}/${GH_REPO}/actions/runs?status=in_progress&per_page=10" 2>/dev/null) || true
      run_ids=$(echo "$runs_json" | jq -r '.workflow_runs[]?.id // empty' 2>/dev/null || true)
      gh_jobs_json="[]"
      for rid in $run_ids; do
        local jobs_page
        jobs_page=$(curl -s --max-time 5 \
          -H "Authorization: Bearer ${GH_PAT}" \
          -H "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/${GH_ORG}/${GH_REPO}/actions/runs/${rid}/jobs?filter=latest&per_page=50" 2>/dev/null) || true
        gh_jobs_json=$(echo "$gh_jobs_json" "$jobs_page" | jq -s '.[0] + ([.[1].jobs[]? | select(.status == "in_progress")] // [])' 2>/dev/null) || true
      done
    fi
  fi

  echo ""
  echo -e "  ${CYAN}--- Bare Metal Runners ---${NC}"
  printf "  %-20s %-10s %-10s %-10s %-14s %s\n" "RUNNER" "SERVICE" "GITHUB" "PID" "FLUTTER" "JOB"

  for dir in "${runner_base}"/runner-*; do
    [[ -d "$dir" ]] || continue
    [[ -f "${dir}/run.sh" ]] || continue

    local name state pid_val flutter_info svc_color gh_status gh_color job_info
    name=$(basename "$dir")
    state="unknown"
    pid_val="-"
    gh_status="-"
    job_info="-"

    # Determine local service state
    # Extract runner index from name (e.g., "runner-3" → "3")
    local runner_idx="${name##runner-}"

    if [[ "$(uname -s)" == "Darwin" ]]; then
      # Check new-style respawn service first (actionforge.runner.N)
      local af_label="actionforge.runner.${runner_idx}"
      local af_entry
      af_entry=$(launchctl list 2>/dev/null | grep "$af_label" || true)
      if [[ -n "$af_entry" ]]; then
        pid_val=$(echo "$af_entry" | awk '{print $1}')
        [[ "$pid_val" == "-" || -z "$pid_val" ]] && pid_val="-"
        if [[ "$pid_val" != "-" ]]; then
          state="running"
        else
          state="stopped"
        fi
      else
        # Fall back to old-style service (actions.runner.*)
        local svc_out
        svc_out=$(cd "$dir" && ./svc.sh status 2>/dev/null) || true
        if echo "$svc_out" | grep -qi "running\|started"; then
          state="running"
          local old_label
          old_label=$(echo "$svc_out" | grep -oE 'actions\.runner\.[^ ]+' | head -1 || true)
          if [[ -n "$old_label" ]]; then
            pid_val=$(launchctl list 2>/dev/null | grep "$old_label" | awk '{print $1}' || true)
            [[ "$pid_val" == "-" || -z "$pid_val" ]] && pid_val="-"
          fi
        elif echo "$svc_out" | grep -qi "stopped\|inactive"; then
          state="stopped"
        fi
      fi
    elif command -v systemctl &>/dev/null; then
      # Check new-style first
      local af_svc="actionforge.runner.${runner_idx}"
      if systemctl is-enabled "${af_svc}" &>/dev/null 2>&1; then
        if systemctl is-active "${af_svc}" &>/dev/null; then
          state="running"
          pid_val=$(systemctl show "${af_svc}" --property=MainPID --value 2>/dev/null || true)
          [[ "$pid_val" == "0" || -z "$pid_val" ]] && pid_val="-"
        else
          state="stopped"
        fi
      else
        # Fall back to old-style
        local svc_name
        svc_name=$(systemctl list-units --type=service --no-legend 2>/dev/null \
          | grep -oE "actions\.runner\.[^ ]*${name}[^ ]*\.service" | head -1 || true)
        if [[ -n "$svc_name" ]]; then
          if systemctl is-active "$svc_name" &>/dev/null; then
            state="running"
          else
            state="stopped"
          fi
        fi
      fi
    fi

    # Fallback: check .pid file
    if [[ "$state" == "unknown" ]] && [[ -f "${dir}/.pid" ]]; then
      local file_pid
      file_pid=$(cat "${dir}/.pid" 2>/dev/null)
      if [[ -n "$file_pid" ]] && kill -0 "$file_pid" 2>/dev/null; then
        state="running"
        pid_val="$file_pid"
      else
        state="stopped"
      fi
    elif [[ "$state" == "running" ]] && [[ -f "${dir}/.pid" ]]; then
      pid_val=$(cat "${dir}/.pid" 2>/dev/null || echo "-")
    fi

    # GitHub connection status (match by runner name from .runner file or hostname pattern)
    local runner_gh_name=""
    if [[ -n "$gh_runners_json" ]]; then
      runner_gh_name=$(jq -r '.runnerName // empty' "${dir}/.runner" 2>/dev/null || true)
      if [[ -z "$runner_gh_name" ]]; then
        runner_gh_name="$(hostname)-${name}"
      fi
      local gh_entry
      gh_entry=$(echo "$gh_runners_json" | jq -r --arg n "$runner_gh_name" \
        '.runners[]? | select(.name == $n) | "\(.status):\(.busy)"' 2>/dev/null || true)
      if [[ -n "$gh_entry" ]]; then
        local gh_s gh_busy
        gh_s="${gh_entry%%:*}"
        gh_busy="${gh_entry##*:}"
        if [[ "$gh_s" == "online" ]] && [[ "$gh_busy" == "true" ]]; then
          gh_status="busy"
        elif [[ "$gh_s" == "online" ]]; then
          gh_status="idle"
        else
          gh_status="offline"
        fi
      fi
    fi

    # If runner is busy, find the active job/workflow name
    if [[ "$gh_status" == "busy" ]] && [[ -n "$gh_jobs_json" ]] && [[ "$gh_jobs_json" != "[]" ]]; then
      local matched_job
      matched_job=$(echo "$gh_jobs_json" | jq -r --arg n "$runner_gh_name" \
        '[.[]? | select(.runner_name == $n)][0] | "\(.workflow_name // "")|\(.name // "")"' 2>/dev/null || true)
      if [[ -n "$matched_job" ]] && [[ "$matched_job" != "|" ]] && [[ "$matched_job" != "null|null" ]]; then
        local wf_name job_name
        wf_name="${matched_job%%|*}"
        job_name="${matched_job##*|}"
        if [[ -n "$wf_name" ]] && [[ -n "$job_name" ]]; then
          job_info="${wf_name} / ${job_name}"
        elif [[ -n "$wf_name" ]]; then
          job_info="${wf_name}"
        elif [[ -n "$job_name" ]]; then
          job_info="${job_name}"
        fi
        # Truncate long job info
        if [[ ${#job_info} -gt 40 ]]; then
          job_info="${job_info:0:37}..."
        fi
      fi
    fi

    # Flutter/FVM/Dart info
    flutter_info="-"
    local fver
    fver=$(grep '^FLUTTER_VERSION=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || true)
    if [[ -n "$fver" ]]; then
      if [[ -f "$ACTIONFORGE_WORKDIR/.fvm-installed-by-actionforge" ]] || command -v fvm &>/dev/null; then
        flutter_info="${fver} (fvm)"
      else
        flutter_info="${fver}"
      fi
    else
      # Check for Dart-only version
      local dver
      dver=$(grep '^DART_VERSION=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || true)
      if [[ -n "$dver" ]]; then
        flutter_info="dart ${dver}"
      fi
    fi

    case "$state" in
      running) svc_color="$GREEN";;
      stopped) svc_color="$RED";;
      *) svc_color="$YELLOW";;
    esac

    case "$gh_status" in
      idle)    gh_color="$GREEN";;
      busy)    gh_color="$CYAN";;
      offline) gh_color="$RED";;
      *) gh_color="$YELLOW";;
    esac

    # shellcheck disable=SC2059
    printf "  %-20s ${svc_color}%-10s${NC} ${gh_color}%-10s${NC} %-10s %-14s %s\n" \
      "$name" "$state" "$gh_status" "$pid_val" "$flutter_info" "$job_info"

    # Show last 4 lines of runner log
    local log_file=""
    if [[ "$(uname -s)" == "Darwin" ]]; then
      # Check new-style respawn log first
      local af_log="$HOME/Library/Logs/actionforge.runner.${runner_idx}/stdout.log"
      if [[ -f "$af_log" ]]; then
        log_file="$af_log"
      else
        # Fall back to old-style LaunchAgent log
        local runner_gh_label
        runner_gh_label=$(ls -d "$HOME/Library/Logs/actions.runner."*".$(hostname)-${name}" 2>/dev/null | head -1 || true)
        if [[ -n "$runner_gh_label" ]]; then
          log_file="${runner_gh_label}/stdout.log"
        fi
      fi
    else
      # Check new-style journalctl first
      local af_svc="actionforge.runner.${runner_idx}"
      if systemctl is-enabled "${af_svc}" &>/dev/null 2>&1; then
        log_file=""  # Will use journalctl below
      else
        # Fall back to _diag logs
        log_file=$(ls -t "${dir}/_diag/Worker_"*.log 2>/dev/null | head -1 || true)
        [[ -z "$log_file" ]] && log_file=$(ls -t "${dir}/_diag/Runner_"*.log 2>/dev/null | head -1 || true)
      fi
    fi

    if [[ -n "${log_file:-}" ]] && [[ -f "$log_file" ]]; then
      local log_lines
      log_lines=$(tail -4 "$log_file" 2>/dev/null) || true
      if [[ -n "$log_lines" ]]; then
        while IFS= read -r line; do
          # Truncate long lines and dim them
          [[ ${#line} -gt 100 ]] && line="${line:0:97}..."
          echo -e "    ${YELLOW}│${NC} ${line}"
        done <<< "$log_lines"
      fi
    fi
  done
}

# Render one frame of the dashboard
status_render() {
  local scope labels timestamp

  # Load config for scope/labels
  # shellcheck source=/dev/null
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

  # Retrieve PAT from secure storage if not in config
  retrieve_pat

  if [[ -n "${GH_REPO:-}" ]]; then
    scope="${GH_ORG:-unknown}/${GH_REPO}"
  elif [[ -n "${GH_ORG:-}" ]]; then
    scope="org: ${GH_ORG}"
  else
    scope="(not configured)"
  fi
  labels="${RUNNER_LABELS:-"(none)"}"
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║          ActionForge — Runner Dashboard                          ║${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Scope:   ${scope}"
  echo -e "  Labels:  ${labels}"
  echo -e "  Updated: ${timestamp}    (Ctrl+C to exit)"

  status_detect_runners

  if [[ "$HAS_DOCKER_RUNNERS" == true ]]; then
    status_docker_runners
  fi

  if [[ "$HAS_BARE_RUNNERS" == true ]]; then
    status_bare_runners
  fi

  if [[ "$HAS_DOCKER_RUNNERS" == false ]] && [[ "$HAS_BARE_RUNNERS" == false ]]; then
    echo ""
    echo -e "  ${YELLOW}No runners found.${NC}"
    echo "  Run 'actionforge --docker' or 'actionforge --bare' to set up runners."
  fi

  echo ""
}

# Live dashboard with interactive controls (or single render for non-TTY)
show_status() {
  # Load config for PAT, labels, URLs
  # shellcheck source=/dev/null
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
  retrieve_pat
  resolve_urls 2>/dev/null || true

  local runner_base
  if [[ "$(uname -s)" == "Darwin" ]]; then
    runner_base="$HOME/actions-runners"
  else
    runner_base="/opt/actions-runners"
  fi

  # Check if any runners exist
  local has_runners=false
  status_detect_runners
  if [[ "$HAS_DOCKER_RUNNERS" == true ]] || [[ "$HAS_BARE_RUNNERS" == true ]]; then
    has_runners=true
  fi

  if [[ "$has_runners" == false ]]; then
    echo ""
    echo -e "  ${YELLOW}No runners found.${NC}"
    echo "  Run 'actionforge --bare' or 'actionforge --docker' to set up runners."
    echo ""
    return 0
  fi

  # Non-TTY: print once and exit
  if [[ ! -t 1 ]]; then
    status_render
    bare_monitor_menu "$runner_base"
    return 0
  fi

  # Hide cursor, restore on exit
  _STATUS_CLEANUP_DONE=false
  # shellcheck disable=SC2317,SC2329
  _status_cleanup() {
    if [[ "${_STATUS_CLEANUP_DONE:-false}" == false ]]; then
      _STATUS_CLEANUP_DONE=true
      printf '\033[?25h'  # show cursor
      echo ""
    fi
  }
  trap _status_cleanup EXIT INT TERM

  printf '\033[?25l'  # hide cursor
  printf '\033[2J\033[H'  # clear screen once on first render

  while true; do
    printf '\033[H'      # move cursor to top-left (no clear)
    status_render
    bare_monitor_menu "$runner_base"
    printf '\033[J'      # clear any leftover lines below

    local key=""
    read -rsn1 -t 3 key || true

    case "$key" in
      [1-9])
        local target_dir="${runner_base}/runner-${key}"
        if [[ -d "$target_dir" ]]; then
          printf '\033[?25h'
          stop_runner "$target_dir"
          printf '\033[?25l'
          sleep 1
        fi
        ;;
      +|=)
        printf '\033[?25h'
        add_runner "$runner_base"
        printf '\033[?25l'
        sleep 1
        ;;
      a|A)
        printf '\033[?25h'
        warn "Stopping all runners..."
        for dir in "${runner_base}"/runner-*; do
          [[ -d "$dir" ]] || continue
          stop_runner "$dir"
        done
        ok "All runners stopped."
        _STATUS_CLEANUP_DONE=true
        return 0
        ;;
      q|Q)
        printf '\033[?25h'
        echo ""
        echo "  Runners continue as background services."
        echo ""
        _STATUS_CLEANUP_DONE=true
        return 0
        ;;
      *)
        # Unknown key or timeout — just refresh
        ;;
    esac
  done
}

# Interactive post-install monitor for bare-metal mode
bare_monitor() {
  local runner_base
  if [[ "$OS" == "osx" ]]; then
    runner_base="$HOME/actions-runners"
  else
    runner_base="/opt/actions-runners"
  fi

  # One-time "Setup Complete" banner
  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║              Setup Complete!                     ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "  ${RUNNER_COUNT} runners are now listening for jobs."
  echo ""
  echo "  Entering live monitor (press q to quit)..."
  sleep 2

  # Non-TTY: print status once and exit
  if [[ ! -t 1 ]]; then
    status_render
    bare_monitor_menu "$runner_base"
    return 0
  fi

  # Hide cursor, restore on exit
  _MONITOR_CLEANUP_DONE=false
  # shellcheck disable=SC2317,SC2329
  _monitor_cleanup() {
    if [[ "${_MONITOR_CLEANUP_DONE:-false}" == false ]]; then
      _MONITOR_CLEANUP_DONE=true
      printf '\033[?25h'  # show cursor
      echo ""
    fi
  }
  trap _monitor_cleanup EXIT INT TERM

  printf '\033[?25l'  # hide cursor
  printf '\033[2J\033[H'  # clear screen once on first render

  while true; do
    printf '\033[H'      # move cursor to top-left (no clear)
    status_render
    bare_monitor_menu "$runner_base"
    printf '\033[J'      # clear any leftover lines below

    local key=""
    read -rsn1 -t 3 key || true

    case "$key" in
      [1-9])
        local target_dir="${runner_base}/runner-${key}"
        if [[ -d "$target_dir" ]]; then
          printf '\033[?25h'  # show cursor for output
          stop_runner "$target_dir"
          printf '\033[?25l'  # hide again
          sleep 1
        fi
        ;;
      +|=)
        printf '\033[?25h'  # show cursor for output
        add_runner "$runner_base"
        printf '\033[?25l'  # hide again
        sleep 1
        ;;
      a|A)
        printf '\033[?25h'
        warn "Stopping all runners..."
        for dir in "${runner_base}"/runner-*; do
          [[ -d "$dir" ]] || continue
          stop_runner "$dir"
        done
        ok "All runners stopped."
        _MONITOR_CLEANUP_DONE=true
        return 0
        ;;
      q|Q)
        printf '\033[?25h'
        echo ""
        echo "  Runners continue as background services."
        echo "  Use 'actionforge' to return to this dashboard."
        echo "  Use 'actionforge --teardown' to remove all runners."
        echo ""
        _MONITOR_CLEANUP_DONE=true
        return 0
        ;;
      *)
        # Unknown key or timeout — just refresh
        ;;
    esac
  done
}

# Add a single new bare-metal runner (used from dashboard)
add_runner() {
  local runner_base="$1"

  # Find the next available runner index
  local next_idx=1
  while [[ -d "${runner_base}/runner-${next_idx}" ]]; do
    next_idx=$((next_idx + 1))
  done

  local runner_dir="${runner_base}/runner-${next_idx}"
  local runner_name
  runner_name="$(hostname)-runner-${next_idx}"

  info "Adding runner-${next_idx}..."

  mkdir -p "$runner_dir"
  cd "$runner_dir"

  # Download runner binary
  if [[ ! -f run.sh ]]; then
    curl -sL -o runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_PACKAGE}"
    tar xzf runner.tar.gz
    rm runner.tar.gz
  fi

  # Create respawn wrapper
  _create_respawn_wrapper "$runner_dir" "$runner_name"

  # Register with GitHub
  get_reg_token

  ./config.sh \
    --url "$CONFIG_URL" \
    --token "$REG_TOKEN" \
    --name "$runner_name" \
    --labels "$RUNNER_LABELS" \
    --work "_work" \
    --replace \
    --unattended \
    --ephemeral

  # Start the respawn service
  _install_respawn_service "$runner_dir" "$runner_name" "$next_idx"

  # Update runner count in config
  local new_count
  new_count=$(ls -d "${runner_base}"/runner-* 2>/dev/null | wc -l | tr -d ' ')
  if [[ -f "$CONFIG_FILE" ]]; then
    sed -i.bak "s/^RUNNER_COUNT=.*/RUNNER_COUNT=${new_count}/" "$CONFIG_FILE"
    rm -f "${CONFIG_FILE}.bak"
  fi

  ok "runner-${next_idx} is live (auto-respawn enabled)"
}

# Print the interactive menu bar for bare_monitor
bare_monitor_menu() {
  local runner_base="$1"
  local count=0

  for dir in "${runner_base}"/runner-*; do
    [[ -d "$dir" ]] || continue
    count=$((count + 1))
  done

  echo -e "  ${CYAN}── Controls ──────────────────────────────────────────────${NC}"
  if [[ "$count" -gt 0 ]]; then
    echo -e "  [1-${count}] remove runner   [+] add runner   [a] remove all   [q] background dashboard"
  else
    echo -e "  [+] add runner   [q] background dashboard"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
  banner
  detect_os

  # Parse arguments
  MODE=""
  AUTO_YES=false
  for arg in "$@"; do
    case "$arg" in
      --docker)   MODE="docker";;
      --bare)     MODE="bare";;
      --teardown) MODE="teardown";;
      --org=*)    GH_ORG="${arg#*=}";;
      --repo=*)   GH_REPO="${arg#*=}";;
      --pat=*)    GH_PAT="${arg#*=}";;
      --count=*)  RUNNER_COUNT="${arg#*=}"; SKIP_PROMPTS=1;;
      --labels=*) RUNNER_LABELS="${arg#*=}";;
      --yes|-y)   AUTO_YES=true; SKIP_PROMPTS=1;;
      --status|-s)
        show_status
        exit 0;;
      --version|-v)
        echo "ActionForge ${ACTIONFORGE_VERSION}"
        exit 0;;
      --help|-h)
        echo "ActionForge — One-Click Self-Hosted CI Runners"
        echo ""
        echo "Usage: actionforge [OPTIONS]"
        echo ""
        echo "Modes:"
        echo "  --docker              Use Docker-based isolated runner (recommended)"
        echo "  --bare                Install runner directly on this machine"
        echo "  --teardown            Remove all runners from this machine"
        echo "  --status, -s          Live runner dashboard (refreshes every 3s)"
        echo ""
        echo "Configuration (skip interactive prompts):"
        echo "  --org=NAME            GitHub org or username"
        echo "  --repo=NAME           Repository name (omit for org-wide)"
        echo "  --pat=TOKEN           GitHub Personal Access Token"
        echo "  --count=N             Number of parallel runners (default: 2)"
        echo "  --labels=LIST         Comma-separated runner labels"
        echo "  --yes, -y             Skip confirmation prompt"
        echo ""
        echo "Examples:"
        echo "  actionforge --bare --org=myorg --repo=myrepo --pat=ghp_xxx --yes"
        echo "  actionforge --docker --org=myorg --count=4 --yes"
        echo ""
        echo "Info:"
        echo "  --version, -v         Print version and exit"
        echo "  --help, -h            Print this help and exit"
        echo ""
        echo "If no option is given, actionforge starts in interactive mode."
        exit 0;;
    esac
  done

  # If no mode specified, check for active runners → go to dashboard
  if [[ -z "$MODE" ]]; then
    status_detect_runners
    if [[ "$HAS_DOCKER_RUNNERS" == true ]] || [[ "$HAS_BARE_RUNNERS" == true ]]; then
      show_status
      exit 0
    fi
  fi

  # Interactive mode selection if not specified
  if [[ -z "$MODE" ]]; then
    echo "How would you like to run the CI runners?"
    echo ""
    echo "  1) Docker (recommended) — each job runs in an isolated container"
    echo "  2) Bare metal            — runner installs directly on this machine"
    echo "  3) Teardown              — remove all runners from this machine"
    echo ""
    read -rp "$(echo -e "${YELLOW}Choose [1/2/3]: ${NC}")" choice
    case "$choice" in
      1) MODE="docker";;
      2) MODE="bare";;
      3) MODE="teardown";;
      *) fail "Invalid choice";;
    esac
  fi

  if [[ "$MODE" == "teardown" ]]; then
    # Only prompt for config if bare-metal runners exist (needs PAT to deregister)
    local runner_base
    if [[ "$OS" == "osx" ]]; then
      runner_base="$HOME/actions-runners"
    else
      runner_base="/opt/actions-runners"
    fi
    if [[ -d "$runner_base" ]]; then
      prompt_config
      resolve_urls
    fi
    teardown
    exit 0
  fi

  check_prereqs
  prompt_config
  resolve_urls

  echo ""
  info "Mode:    ${MODE}"
  info "Scope:   ${SCOPE}"
  info "Runners: ${RUNNER_COUNT}"
  info "Labels:  ${RUNNER_LABELS}"
  echo ""
  if [[ "$AUTO_YES" == true ]]; then
    info "Proceeding (--yes)"
  else
    read -rp "$(echo -e "${YELLOW}Proceed? [Y/n]: ${NC}")" confirm
    [[ "${confirm:-Y}" =~ ^[Yy]?$ ]] || exit 0
  fi

  case "$MODE" in
    docker) install_docker_mode;;
    bare)   install_bare;;
  esac

  if [[ "$MODE" == "bare" ]]; then
    bare_monitor
  else
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Setup Complete!                     ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  ${RUNNER_COUNT} runners are now listening for jobs."
    echo ""
    echo "  Your existing workflows need ZERO changes."
    if [[ "$OS" == "osx" ]]; then
      echo "  Any workflow with 'runs-on: macos-latest' will"
      echo "  automatically route to these local runners."
    else
      echo "  Any workflow with 'runs-on: ubuntu-latest' will"
      echo "  automatically route to these local runners."
    fi
    echo ""
    echo "  Useful commands:"
    echo "    actionforge --status        — live runner dashboard"
    echo "    docker compose ps          — check runner status"
    echo "    docker compose logs -f     — watch runner logs"
    echo "    docker compose down        — stop runners"
    echo "    actionforge --teardown      — full cleanup"
    echo ""
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
