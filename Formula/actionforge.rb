# ============================================================================
#  ActionForge — Homebrew Formula
#  Reference copy — the canonical version lives in FlutterPlaza/homebrew-tap
#
#  To publish:
#    1. Create repo: github.com/FlutterPlaza/homebrew-tap
#    2. Copy this file to: homebrew-tap/Formula/actionforge.rb
#    3. Tag a release: git tag v1.0.0 && git push origin v1.0.0
#    4. Replace the sha256 below with the value from the release workflow logs
#
#  Users install with:
#    brew tap flutterplaza/tap
#    brew install actionforge
# ============================================================================

class Actionforge < Formula
  desc "One-click self-hosted GitHub Actions CI runners"
  homepage "https://github.com/FlutterPlaza/actionforge"

  # After tagging a release, update the tag in the URL and the sha256.
  # The release workflow (.github/workflows/release.yml) prints the SHA256.
  url "https://github.com/FlutterPlaza/actionforge/archive/refs/tags/v1.4.3.tar.gz"
  sha256 "56eb3251de09a5eac05839b61d6e8304e9a0abc5181cdeaf0c34190bd5138269"
  license "BSD-3-Clause"

  depends_on "jq"

  def install
    # Install all runtime files into libexec/ (Homebrew's private directory).
    # This keeps them out of the user's PATH and avoids polluting bin/.
    libexec.install "setup.sh", "Dockerfile", "docker-compose.yml", "entrypoint.sh"
    chmod 0755, libexec/"setup.sh"
    chmod 0755, libexec/"entrypoint.sh"

    # Create a thin wrapper in bin/ that delegates to the real script.
    # setup.sh uses resolve_script_dir() to follow this symlink back to
    # libexec/ and find Dockerfile, docker-compose.yml, etc.
    (bin/"actionforge").write <<~SH
      #!/usr/bin/env bash
      exec "#{libexec}/setup.sh" "$@"
    SH
  end

  def caveats
    <<~EOS
      ActionForge requires Docker to run in Docker mode (recommended).
      Install Docker Desktop if you haven't already:

        brew install --cask docker

      To get started:

        actionforge

      Docker files are copied to ~/.actionforge/ at runtime so they
      survive Homebrew upgrades. To remove everything:

        actionforge --teardown
    EOS
  end

  test do
    assert_match "ActionForge", shell_output("#{bin}/actionforge --version")
  end
end
