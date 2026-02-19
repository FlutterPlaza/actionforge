# ActionForge — One-Click Self-Hosted CI Runners

> **A [FlutterPlaza](https://flutterplaza.com) Open-Source Product**

> Turn any developer machine into a GitHub Actions runner in one command.
> **No changes to existing workflows required.**

---

## The Problem

Every PR triggers CI on GitHub's shared runners → jobs queue up → developers wait.

## The Solution

Each developer runs CI **locally on their own machine**. GitHub still manages secrets, triggers, and status checks — but the compute happens here instead of in GitHub's cloud.

---

## Quick Start (Developer Instructions)

### Prerequisites

| Requirement | Why |
|---|---|
| **Docker** | Runs each CI job in an isolated container — **auto-installed if missing** |
| **A GitHub PAT** | So the runner can register itself (see below) |

**Platform support:** macOS (Intel & Apple Silicon), Linux (Ubuntu, Debian, Fedora, CentOS/RHEL, Arch, Alpine, openSUSE), Windows 10+

### Step 1 — Create a Personal Access Token

1. Go to https://github.com/settings/tokens?type=beta (Fine-grained tokens)
2. Click **"Generate new token"**
3. Set these permissions:
   - **Repository access**: All repositories (or select specific repos)
   - **Permissions → Organization → Self-hosted runners**: Read & Write
   - **Permissions → Repository → Administration**: Read & Write
4. Copy the token — you'll need it in the next step

### Step 2 — Run the Setup

**macOS / Linux (Homebrew):**

```bash
brew tap flutterplaza/tap
brew install actionforge
actionforge
```

Or as a single command: `brew install flutterplaza/tap/actionforge`

**One-liner (fully non-interactive):**

```bash
actionforge --bare --org=MyOrg --repo=my-repo --pat=ghp_xxx --count=2 --yes
```

**macOS / Linux (manual):**

```bash
git clone https://github.com/FlutterPlaza/actionforge.git
cd actionforge
chmod +x setup.sh
./setup.sh
```

**Windows (PowerShell as Admin):**

```powershell
git clone https://github.com/FlutterPlaza/actionforge.git
cd actionforge
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\setup.ps1
```

That's it. The script will:
- Auto-install Docker and other prerequisites if missing
- Prompt you for your GitHub org name and PAT
- Ask how many parallel runners you want (default: 2)
- Let you choose Docker vs bare-metal mode
- In bare-metal mode, enter a **live monitor** with controls to stop/manage runners

### Step 3 — There Is No Step 3

Your machine is now picking up CI jobs. Push a PR and watch it run locally.

---

## How It Works

The secret is **label matching**. We register each runner with the same labels your workflows already use:

```
Linux:   ubuntu-latest, ubuntu-22.04, ubuntu-24.04, self-hosted, linux, x64
macOS:   macos-latest, macos-14, self-hosted, macos, arm64
Windows: windows-latest, windows-2022, self-hosted, windows, x64
```

When a workflow says `runs-on: ubuntu-latest`, GitHub checks: "are there self-hosted runners with this label?" If yes → routes the job there. If all local runners are busy → falls back to GitHub-hosted runners automatically.

**This means zero changes to any existing workflow files.**

---

## What Changes for the Team

### For Developers (people opening PRs)

**Nothing changes.** You push code, open PRs, and see green/red checks exactly as before — just faster.

### For the DevOps/Platform Team (one-time setup)

| Step | What to Do | Who | When |
|---|---|---|---|
| 1 | Create this repo in your org | Platform team | Once |
| 2 | Customize `Dockerfile` with your CI dependencies | Platform team | Once |
| 3 | Share the repo URL with the team | Platform team | Once |
| 4 | (Optional) Adjust runner group permissions in GitHub org settings | Platform team | Once |

### GitHub Workflow Changes Needed

**None.** But if you want to *guarantee* jobs run locally (and not fall back to GitHub-hosted), change:

```yaml
# Before (works automatically via label matching)
runs-on: ubuntu-latest

# After (explicit — only runs on self-hosted, fails if none available)
runs-on: [self-hosted, linux, x64]
```

Most teams should **not** make this change — the automatic fallback is a safety net.

---

## Customizing for Your Stack

Edit the `Dockerfile` to add the tools your CI pipelines need:

```dockerfile
# Java projects
RUN apt-get install -y openjdk-17-jdk maven

# Go projects
RUN curl -sL https://go.dev/dl/go1.22.0.linux-amd64.tar.gz | tar -C /usr/local -xzf -
ENV PATH=$PATH:/usr/local/go/bin

# Rust projects
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# .NET projects
RUN apt-get install -y dotnet-sdk-8.0

# Your custom tools
RUN npm install -g your-internal-cli
```

After editing, runners will rebuild automatically on next `actionforge` run.

---

## Project Structure

```
actionforge/
├── setup.sh              ← Setup script for macOS and Linux
├── setup.ps1             ← Setup script for Windows (PowerShell)
├── Dockerfile            ← Runner container image (customize for your stack)
├── entrypoint.sh         ← Container startup (auto-register + run)
├── docker-compose.yml    ← Orchestrates multiple runners
├── Formula/
│   └── actionforge.rb    ← Homebrew formula (reference copy)
├── tests/
│   └── unit/             ← BATS unit tests
├── .github/
│   └── workflows/
│       └── release.yml   ← Automated release + SHA256 computation
├── LICENSE               ← BSD 3-Clause License
└── README.md             ← You are here
```

---

## CLI Reference

```
Usage: actionforge [OPTIONS]

Modes:
  --docker              Use Docker-based isolated runner (recommended)
  --bare                Install runner directly on this machine
  --teardown            Remove all runners from this machine
  --status, -s          Live runner dashboard (refreshes every 3s)

Configuration (skip interactive prompts):
  --org=NAME            GitHub org or username
  --repo=NAME           Repository name (omit for org-wide)
  --pat=TOKEN           GitHub Personal Access Token
  --count=N             Number of parallel runners (default: 2)
  --labels=LIST         Comma-separated runner labels
  --yes, -y             Skip confirmation prompt

Info:
  --version, -v         Print version and exit
  --help, -h            Print this help and exit
```

### Examples

```bash
# Interactive mode (prompts for everything)
actionforge

# One-liner: bare-metal, repo-scoped
actionforge --bare --org=MyOrg --repo=my-repo --pat=ghp_xxx --count=2 --yes

# One-liner: Docker, org-wide
actionforge --docker --org=MyOrg --pat=ghp_xxx --count=4 --yes

# Live dashboard
actionforge --status

# Full cleanup (deregisters from GitHub)
actionforge --teardown
```

## Common Operations

### Docker Mode

```bash
# Check runner status
docker compose ps

# Watch runner logs in real time
docker compose logs -f

# Scale up (e.g., big release day)
docker compose up -d --scale runner=6

# Scale down
docker compose up -d --scale runner=1

# Stop all runners
docker compose down
```

### Bare-Metal Mode

After `actionforge --bare` finishes installing, a **live monitor** starts automatically:

```
╔═══════════════════════════════════════════════════════════════════╗
║          ActionForge — Runner Dashboard                          ║
╚═══════════════════════════════════════════════════════════════════╝

  Scope:   MyOrg/my-repo
  Labels:  macos-latest,macos-14,self-hosted,macos,arm64
  Updated: 2026-02-18 17:09:37    (Ctrl+C to exit)

  --- Bare Metal Runners ---
  RUNNER                               STATE          PID        FLUTTER
  runner-1                             active         15119      3.27.0 (fvm)

  ── Controls ──────────────────────────────────────────────
  [1-1] stop runner   [a] stop all   [b] background   [q] quit
```

| Key | Action |
|---|---|
| `1`–`9` | Stop and deregister a specific runner |
| `a` | Stop all runners and exit |
| `b` | Background — exit monitor, runners keep running as services |
| `q` | Quit monitor, runners keep running |

You can also check on runners later with `actionforge --status`.

### Cleanup

```bash
# Full cleanup (deregisters from GitHub)
actionforge --teardown          # macOS/Linux
.\setup.ps1 -Mode teardown     # Windows
```

---

## Security Notes

| Concern | How It's Handled |
|---|---|
| **Secrets** | GitHub injects them at runtime — they are never stored on your machine |
| **Job isolation** | Each job runs in a fresh ephemeral container |
| **Token scope** | PAT is stored in `.env` with `600` permissions, only used for registration |
| **Fork PRs** | Configure in GitHub: Settings → Actions → "Require approval for fork PRs" |
| **Docker socket** | Mounted for CI workflows that build images — remove from `docker-compose.yml` if not needed |

---

## FAQ

**Q: Will my machine slow down?**
Resource limits are set in `docker-compose.yml` (default: 2 CPUs, 4GB RAM per runner). Adjust to your machine.

**Q: What happens if I close my laptop?**
Jobs in progress will fail and GitHub will show a red check. Pending jobs fall back to GitHub-hosted runners (or wait for another self-hosted runner).

**Q: Can I run this on a shared server instead of my laptop?**
Absolutely — that's actually the ideal setup. Run it on a beefy server and set `RUNNER_COUNT=8` or more.

**Q: Do I need to keep the terminal open?**
No. In Docker mode, runners survive terminal closes and reboots (via `restart: unless-stopped`). In bare-metal mode, runners are installed as system services (launchd on macOS, systemd on Linux) — press `b` or `q` in the monitor to exit while runners keep running.

**Q: Does this work on Windows?**
Yes! Run `.\setup.ps1` in an elevated PowerShell window. Docker Desktop on Windows runs Linux containers via WSL2, so the same `docker-compose.yml` works. For native Windows runners, use bare-metal mode.

---

## Architecture

```
Developer pushes PR
        │
        ▼
GitHub receives push, triggers workflow
        │
        ▼
GitHub checks: any self-hosted runner
with label "ubuntu-latest"?
        │
   ┌────┴────┐
   │ YES     │ NO
   ▼         ▼
Routes to    Falls back to
your local   GitHub-hosted
runner       runner
   │
   ▼
Job runs on your machine
Secrets injected by GitHub
   │
   ▼
Results sent back to GitHub
PR shows ✅ or ❌
```

---

## Homebrew Tap Setup (Maintainers)

ActionForge is distributed via a **Homebrew tap** — a custom formula repository hosted on GitHub. Once set up, users can install with:

```bash
brew tap flutterplaza/tap   # one-time — adds the tap
brew install actionforge     # installs (works after tapping)
```

Or the single-command shorthand: `brew install flutterplaza/tap/actionforge`

### How to set up the tap

**1. Create the tap repository**

Create a public repo named **[FlutterPlaza/homebrew-tap](https://github.com/FlutterPlaza/homebrew-tap)** on GitHub with this structure:

```
homebrew-tap/
└── Formula/
    └── actionforge.rb
```

Copy the formula from this repo's `Formula/actionforge.rb` as a starting point.

> The repo **must** be named `homebrew-tap` — Homebrew maps `brew tap flutterplaza/tap` to `github.com/FlutterPlaza/homebrew-tap`.

**2. Tag a release in this repo**

```bash
git tag v1.0.0
git push origin v1.0.0
```

The release workflow (`.github/workflows/release.yml`) will:
- Create a GitHub Release with auto-generated notes
- Compute the SHA256 of the source tarball and print it in the job logs

**3. Update the formula with the real SHA256**

In the tap repo, edit `Formula/actionforge.rb` and replace:
- `url` — the tarball URL for the new tag
- `sha256` — the hash printed by the release workflow

**4. Test it**

```bash
brew tap flutterplaza/tap
brew install actionforge
actionforge --version
```

---

## Contributing

We welcome contributions! Please open an issue or submit a pull request on [GitHub](https://github.com/FlutterPlaza/actionforge).

## License

BSD 3-Clause License — see [LICENSE](LICENSE) for details.

---

<p align="center">
  <strong>ActionForge</strong> is built and maintained by <a href="https://flutterplaza.com">FlutterPlaza</a><br>
  Open-source tools for the developer community
</p>
