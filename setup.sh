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

ACTIONFORGE_VERSION="1.2.0"
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

# ── Prompt for missing config ────────────────────────────────────────────────
prompt_config() {
  # Load saved config if it exists
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

  if [[ -z "${GH_ORG:-}" ]]; then
    read -rp "$(echo -e "${YELLOW}GitHub org or username: ${NC}")" GH_ORG
  fi

  if [[ -z "${GH_REPO:-}" ]]; then
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

  # Save config (except PAT) for future runs
  cat > "$CONFIG_FILE" <<EOF
GH_ORG="${GH_ORG}"
GH_REPO="${GH_REPO}"
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

  REG_TOKEN=$(echo "$token" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

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

  for i in $(seq 1 "$RUNNER_COUNT"); do
    local runner_dir="${runner_base}/runner-${i}"
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

    # Get a fresh registration token for each runner
    get_reg_token

    # Configure
    ./config.sh \
      --url "$CONFIG_URL" \
      --token "$REG_TOKEN" \
      --name "$(hostname)-runner-${i}" \
      --labels "$RUNNER_LABELS" \
      --work "_work" \
      --replace \
      --unattended \
      --ephemeral

    # Install as a system service (platform-specific)
    if [[ "$OS" == "osx" ]]; then
      ./svc.sh install
      ./svc.sh start
    else
      sudo ./svc.sh install || true
      sudo ./svc.sh start
    fi

    ok "runner-${i} is live and listening for jobs"
  done
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
    docker compose down 2>/dev/null && ok "Docker runners stopped" || true
  else
    local kit_dir
    kit_dir="$(resolve_script_dir)"
    if [[ -f "${kit_dir}/docker-compose.yml" ]]; then
      cd "$kit_dir"
      docker compose down 2>/dev/null && ok "Docker runners stopped" || true
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
    for dir in "${runner_base}"/runner-*; do
      [[ -d "$dir" ]] || continue
      cd "$dir"
      info "Removing $(basename "$dir")..."

      if [[ "$OS" == "osx" ]]; then
        ./svc.sh stop 2>/dev/null || true
        ./svc.sh uninstall 2>/dev/null || true
      else
        sudo ./svc.sh stop 2>/dev/null || true
        sudo ./svc.sh uninstall 2>/dev/null || true
      fi

      get_reg_token
      ./config.sh remove --token "$REG_TOKEN" 2>/dev/null || true
    done

    if [[ "$OS" == "osx" ]]; then
      rm -rf "$runner_base"
    else
      sudo rm -rf "$runner_base"
    fi
    ok "Bare-metal runners removed"
  fi

  rm -f "$CONFIG_FILE"
  rm -rf "$ACTIONFORGE_WORKDIR"
  ok "Teardown complete"
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
  banner
  detect_os

  # Parse mode from arguments
  MODE=""
  for arg in "$@"; do
    case "$arg" in
      --docker)   MODE="docker";;
      --bare)     MODE="bare";;
      --teardown) MODE="teardown";;
      --version|-v)
        echo "ActionForge ${ACTIONFORGE_VERSION}"
        exit 0;;
      --help|-h)
        echo "ActionForge — One-Click Self-Hosted CI Runners"
        echo ""
        echo "Usage: actionforge [--docker|--bare|--teardown|--help|--version]"
        echo ""
        echo "Options:"
        echo "  --docker      Use Docker-based isolated runner (recommended)"
        echo "  --bare        Install runner directly on this machine"
        echo "  --teardown    Remove all runners from this machine"
        echo "  --version     Print version and exit"
        echo "  --help        Print this help and exit"
        echo ""
        echo "If no option is given, actionforge starts in interactive mode."
        exit 0;;
    esac
  done

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
  read -rp "$(echo -e "${YELLOW}Proceed? [Y/n]: ${NC}")" confirm
  [[ "${confirm:-Y}" =~ ^[Yy]?$ ]] || exit 0

  case "$MODE" in
    docker) install_docker_mode;;
    bare)   install_bare;;
  esac

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
  if [[ "$MODE" == "docker" ]]; then
    echo "    docker compose ps          — check runner status"
    echo "    docker compose logs -f     — watch runner logs"
    echo "    docker compose down        — stop runners"
    echo "    actionforge --teardown      — full cleanup"
  else
    if [[ "$OS" == "osx" ]]; then
      echo "    ./svc.sh status            — check runner status"
      echo "    actionforge --teardown      — full cleanup"
    else
      echo "    sudo systemctl status 'actions.runner.*'  — check status"
      echo "    journalctl -u 'actions.runner.*' -f       — watch logs"
      echo "    actionforge --teardown                     — full cleanup"
    fi
  fi
  echo ""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
