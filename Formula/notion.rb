# Homebrew Formula for the Notion CLI
# This script defines how Homebrew should download, install, and verify the package.
class Notion < Formula
  desc "Notion markdown sync CLI"
  homepage "https://github.com/thedwncmpy/notion-cli"
  url "https://github.com/thedwncmpy/notion-cli/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_TARBALL_SHA256"
  license "MIT"

  # Core dependencies required for the CLI to function
  depends_on "jq"
  depends_on "python@3.12"

  def install
    # 1. Install internal libraries to libexec (private to this formula)
    # This prevents the library files from cluttering the user's global PATH.
    libexec.install "lib"

    # 2. Install the main executable to the standard bin directory
    bin.install "bin/notion"

    # 3. Fix the internal path resolution.
    # The original script assumes a relative path to the 'lib' folder.
    # Since we moved 'lib' to libexec, we must update the script to point to the new absolute path.
    inreplace bin/"notion", 'source "$SCRIPT_DIR/../lib/notion_cli.zsh"',
                             "source \"#{libexec}/lib/notion_cli.zsh\""
  end

  # A simple check to ensure the binary is installed correctly and runs
  test do
    assert_match "Usage: notion <command>", shell_output("#{bin}/notion help")
  end
end
