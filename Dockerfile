# ============================================================================
#  ActionForge — Runner Container Image
#  A FlutterPlaza Open-Source Product | https://flutterplaza.com
# ============================================================================
FROM ubuntu:22.04

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# ── Install common CI tools ──────────────────────────────────────────────────
# Add what your team's pipelines actually need here
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    jq \
    git \
    unzip \
    zip \
    wget \
    build-essential \
    software-properties-common \
    # Node.js
    nodejs \
    npm \
    # Python
    python3 \
    python3-pip \
    python3-venv \
    # Docker CLI (for workflows that build images)
    docker.io \
    && rm -rf /var/lib/apt/lists/*

# ── Install GitHub Actions runner ────────────────────────────────────────────
ARG RUNNER_VERSION=2.321.0

RUN useradd -m runner && \
    mkdir -p /home/runner/actions-runner && \
    cd /home/runner/actions-runner && \
    ARCH="$(dpkg --print-architecture)" && \
    if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then RUNNER_ARCH="arm64"; else RUNNER_ARCH="x64"; fi && \
    curl -sL -o runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" && \
    tar xzf runner.tar.gz && \
    rm runner.tar.gz && \
    ./bin/installdependencies.sh && \
    chown -R runner:runner /home/runner

# ── Entrypoint ───────────────────────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER runner
WORKDIR /home/runner/actions-runner

ENTRYPOINT ["/entrypoint.sh"]
